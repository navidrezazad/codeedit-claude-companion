//
//  RemoteTerminalClient.swift
//  CodeEditRemoteiOS
//
//  Created by Claude on 6/12/26.
//

import Foundation
import Network
import UIKit

// swiftlint:disable file_length

private enum DefaultsKey {
    static let passcode = "CodeEditRemote.passcode"
    static let legacyDirectHost = "CodeEditRemote.directHost"
    static let legacyDirectPort = "CodeEditRemote.directPort"
    static let localHost = "CodeEditRemote.localHost"
    static let localPort = "CodeEditRemote.localPort"
    static let globalHost = "CodeEditRemote.globalHost"
    static let globalPort = "CodeEditRemote.globalPort"
    static let lastMarkdownDocument = "CodeEditRemote.lastMarkdownDocument"
    static let lastMarkdownStreamState = "CodeEditRemote.lastMarkdownStreamState"
    static let lastSelectedSessionID = "CodeEditRemote.lastSelectedSessionID"
}

private struct PersistedMarkdownStreamState: Codable {
    let streamID: UUID
    let sessionID: UUID
    let path: String
    let name: String
    let markdown: String
    let isTruncated: Bool

    init(
        streamID: UUID,
        sessionID: UUID,
        path: String,
        name: String,
        markdown: String,
        isTruncated: Bool
    ) {
        self.streamID = streamID
        self.sessionID = sessionID
        self.path = path
        self.name = name
        self.markdown = markdown
        self.isTruncated = isTruncated
    }

    init(document: TerminalRemoteProtocol.MarkdownStreamDocument, markdown: String? = nil) {
        self.init(
            streamID: document.streamID,
            sessionID: document.sessionID,
            path: document.path,
            name: document.name,
            markdown: markdown ?? document.markdown,
            isTruncated: document.status?.isTruncated == true
        )
    }

    var document: TerminalRemoteProtocol.MarkdownStreamDocument {
        TerminalRemoteProtocol.MarkdownStreamDocument(
            streamID: streamID,
            sessionID: sessionID,
            path: path,
            name: name,
            markdown: markdown,
            isActive: false,
            updateKind: .snapshot,
            status: .init(
                phase: .stopped,
                title: "Markdown stream paused",
                detail: "Reconnect to the Mac to resume this terminal stream.",
                isTruncated: isTruncated
            )
        )
    }
}

// swiftlint:disable:next type_body_length
final class RemoteTerminalClient: ObservableObject {
    private final class ConnectionContext {
        let id = UUID()
        let connection: NWConnection
        var receiveBuffer = Data()

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    struct DiscoveredHost: Identifiable, Equatable {
        let id: String
        let name: String
        let endpoint: NWEndpoint

        static func == (lhs: DiscoveredHost, rhs: DiscoveredHost) -> Bool {
            lhs.id == rhs.id
        }
    }

    @Published var hosts: [DiscoveredHost] = []
    @Published var sessions: [TerminalRemoteProtocol.Session] = []
    @Published var selectedSessionID: UUID?
    @Published var pendingInput = ""
    @Published var currentDirectoryPath: String?
    @Published var files: [TerminalRemoteProtocol.FileItem] = []
    /// Most recently opened Markdown file, restored on launch and re-persisted whenever it changes so the
    /// Markdown tab keeps its content across reconnects and app restarts.
    @Published var markdownDocument = RemoteTerminalClient.loadPersistedMarkdownDocument() {
        didSet {
            persistMarkdownDocument(markdownDocument)
        }
    }
    @Published var passcode = UserDefaults.standard.string(forKey: DefaultsKey.passcode) ?? "" {
        didSet {
            UserDefaults.standard.set(passcode, forKey: DefaultsKey.passcode)
        }
    }
    @Published var localHost = UserDefaults.standard.string(forKey: DefaultsKey.localHost)
        ?? UserDefaults.standard.string(forKey: DefaultsKey.legacyDirectHost)
        ?? "" {
        didSet {
            UserDefaults.standard.set(localHost, forKey: DefaultsKey.localHost)
        }
    }
    @Published var localPort = UserDefaults.standard.string(forKey: DefaultsKey.localPort)
        ?? UserDefaults.standard.string(forKey: DefaultsKey.legacyDirectPort)
        ?? "" {
        didSet {
            UserDefaults.standard.set(localPort, forKey: DefaultsKey.localPort)
        }
    }
    @Published var globalHost = UserDefaults.standard.string(forKey: DefaultsKey.globalHost) ?? "" {
        didSet {
            UserDefaults.standard.set(globalHost, forKey: DefaultsKey.globalHost)
        }
    }
    @Published var globalPort = UserDefaults.standard.string(forKey: DefaultsKey.globalPort)
        ?? UserDefaults.standard.string(forKey: DefaultsKey.localPort)
        ?? UserDefaults.standard.string(forKey: DefaultsKey.legacyDirectPort)
        ?? "" {
        didSet {
            UserDefaults.standard.set(globalPort, forKey: DefaultsKey.globalPort)
        }
    }
    @Published var statusMessage = "Searching"
    @Published var isConnected = false
    @Published var isAuthenticated = false
    @Published var terminalMirrorSnapshot = TerminalMirrorSnapshot.empty
    @Published var markdownStreamDocument = RemoteTerminalClient.persistedMarkdownStreamDocumentAtLaunch
    @Published var markdownStreamStatus = RemoteTerminalClient.persistedMarkdownStreamDocumentAtLaunch == nil
        ? "No Markdown stream"
        : "Markdown stream paused"
    @Published var markdownStreamStatusDetail: String? = RemoteTerminalClient.persistedMarkdownStreamDocumentAtLaunch == nil
        ? nil
        : "Reconnect to the Mac to resume this terminal stream."
    @Published var markdownStreamIsTruncated = RemoteTerminalClient.persistedMarkdownStreamDocumentAtLaunch?.status?.isTruncated == true
    @Published var markdownStreamIsActive = false

    private static let persistedMarkdownStreamDocumentAtLaunch = loadPersistedMarkdownStreamDocument()

    private let queue = DispatchQueue(label: "app.codeedit.remote-terminal-client")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let maxServerMessageBytes = 16 * 1024 * 1024
    private var terminalMirrorBuffer = TerminalMirrorBuffer()
    private var browser: NWBrowser?
    private var connectionContext: ConnectionContext?
    private var pendingProjectedOutput: TerminalRemoteProtocol.ProjectedOutput?
    private var projectedOutputFlushWorkItem: DispatchWorkItem?
    private var shouldRememberEndpointFromHello = false
    private var activeMarkdownStreamID: UUID?
    private var lastMarkdownStreamRevision: Int?
    private var requestedStoppedMarkdownStreamIDs = Set<UUID>()
    private var pendingMarkdownStreamHandshakeIDs = Set<UUID>()
    private var connectionInFlight = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    var selectedSession: TerminalRemoteProtocol.Session? { sessions.first { $0.id == selectedSessionID } }

    func startBrowsing() {
        guard browser == nil else {
            return
        }

        let browser = NWBrowser(
            for: .bonjour(type: TerminalRemoteProtocol.serviceType, domain: nil),
            using: .tcp
        )

        browser.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.statusMessage = "Searching"
                case .failed(let error):
                    self?.statusMessage = error.localizedDescription
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let hosts = results
                .map(Self.discoveredHost)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

            DispatchQueue.main.async {
                self?.hosts = hosts
            }
        }

        browser.start(queue: queue)
        self.browser = browser
    }

    func connect(to host: DiscoveredHost) {
        connect(to: host.endpoint, displayName: host.name, rememberEndpointFromHello: true)
    }

    func connectLocalDirect() {
        connectDirect(host: localHost, portText: localPort, label: "local", rememberEndpointFromHello: true)
    }

    func connectGlobalDirect() {
        connectDirect(host: globalHost, portText: globalPort, label: "global", rememberEndpointFromHello: true)
    }

    private func connectDirect(
        host rawHost: String,
        portText rawPortText: String,
        label: String,
        rememberEndpointFromHello: Bool
    ) {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let portText = rawPortText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !host.isEmpty,
              let portValue = UInt16(portText),
              let port = NWEndpoint.Port(rawValue: portValue) else {
            statusMessage = "Enter a valid \(label) host and port"
            return
        }

        connect(
            to: .hostPort(host: NWEndpoint.Host(host), port: port),
            displayName: "\(host):\(portValue)",
            rememberEndpointFromHello: rememberEndpointFromHello
        )
    }

    private func connect(to endpoint: NWEndpoint, displayName: String, rememberEndpointFromHello: Bool) {
        disconnect()
        shouldRememberEndpointFromHello = rememberEndpointFromHello
        connectionInFlight = true
        statusMessage = "Connecting to \(displayName)"

        let connection = NWConnection(to: endpoint, using: Self.keepAliveParameters())
        let context = ConnectionContext(connection: connection)
        connectionContext = context

        connection.stateUpdateHandler = { [weak self, weak context] state in
            guard let self, let context else {
                return
            }

            DispatchQueue.main.async {
                guard self.connectionContext?.id == context.id else {
                    return
                }

                switch state {
                case .ready:
                    self.connectionInFlight = false
                    self.isConnected = true
                    self.statusMessage = "Connected"
                    self.receiveNext(context)
                    if !self.passcode.isEmpty {
                        self.authenticate()
                    }
                case .failed(let error):
                    self.connectionContext = nil
                    self.connectionInFlight = false
                    self.statusMessage = error.localizedDescription
                    self.isConnected = false
                    self.isAuthenticated = false
                case .cancelled:
                    self.connectionContext = nil
                    self.connectionInFlight = false
                    self.isConnected = false
                    self.isAuthenticated = false
                default:
                    break
                }
            }
        }

        connection.start(queue: queue)
    }

    /// Reconnects to the most recently used saved endpoint (local first, then global) when the app
    /// launches or returns to the foreground. A single attempt; no-op if already connected or busy.
    func attemptAutoReconnect() {
        guard !isConnected, !connectionInFlight, !passcode.isEmpty else {
            return
        }

        let host = localHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = localPort.trimmingCharacters(in: .whitespacesAndNewlines)
        if !host.isEmpty, !port.isEmpty {
            connectLocalDirect()
            return
        }

        let globalHostValue = globalHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let globalPortValue = globalPort.trimmingCharacters(in: .whitespacesAndNewlines)
        if !globalHostValue.isEmpty, !globalPortValue.isEmpty {
            connectGlobalDirect()
        }
    }

    /// Applies pairing details (from a scanned QR code or deep link) and immediately connects.
    func applyPairing(host: String, port: String, passcode pairingPasscode: String?) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, !trimmedPort.isEmpty else {
            statusMessage = "Pairing code missing host or port"
            return
        }

        localHost = trimmedHost
        localPort = trimmedPort
        if let pairingPasscode, !pairingPasscode.isEmpty {
            passcode = pairingPasscode
        }
        connectLocalDirect()
    }

    /// Parses a `codeeditv2://pair?host=…&port=…&code=…` URL and connects. Returns `false` if the
    /// URL is not a recognized pairing link.
    @discardableResult
    func handlePairingURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "codeeditv2",
              url.host?.lowercased() == "pair",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }

        let items = components.queryItems ?? []
        func value(for name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        guard let host = value(for: "host"), let port = value(for: "port") else {
            return false
        }

        applyPairing(host: host, port: port, passcode: value(for: "code"))
        return true
    }

    func disconnect() {
        connectionContext?.connection.cancel()
        connectionContext = nil
        connectionInFlight = false
        sessions.removeAll()
        selectedSessionID = nil
        resetTerminalPresentation()
        currentDirectoryPath = nil
        files.removeAll()
        // Intentionally keep `markdownDocument` so the last-opened Markdown is retained across
        // reconnects and app restarts. It is persisted separately via persistMarkdownDocument(_:).
        isConnected = false
        isAuthenticated = false
        shouldRememberEndpointFromHello = false
    }

    /// Requests a short background execution window (~30s, the iOS limit for ordinary apps) so the live
    /// connection survives quick app switches instead of dropping the moment the app is backgrounded.
    /// Pair with `endBackgroundKeepAlive()` when returning to the foreground.
    func beginBackgroundKeepAlive() {
        endBackgroundKeepAlive()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "RemoteTerminalKeepAlive") { [weak self] in
            self?.endBackgroundKeepAlive()
        }
    }

    func endBackgroundKeepAlive() {
        guard backgroundTask != .invalid else {
            return
        }

        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// TCP parameters with keepalive enabled so the OS keeps the socket healthy across idle periods and
    /// app switches, and detects dropped connections quickly.
    private static func keepAliveParameters() -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 10
        tcpOptions.keepaliveInterval = 5
        tcpOptions.keepaliveCount = 3
        tcpOptions.noDelay = true
        return NWParameters(tls: nil, tcp: tcpOptions)
    }

    func authenticate() {
        guard !passcode.isEmpty else {
            statusMessage = "Enter passcode"
            return
        }

        send(.init(type: .authenticate, token: passcode))
    }

    func refreshSessions() {
        send(.init(type: .list))
    }

    func browseFiles(path: String? = nil) {
        send(.init(type: .browseFiles, path: path))
    }

    func browseParentDirectory() {
        guard let currentDirectoryPath else {
            browseFiles()
            return
        }

        let parent = URL(fileURLWithPath: currentDirectoryPath).deletingLastPathComponent().path
        browseFiles(path: parent)
    }

    func attach(to session: TerminalRemoteProtocol.Session) {
        if let previousSessionID = selectedSessionID, previousSessionID != session.id {
            send(.init(type: .detach, sessionID: previousSessionID))
        }
        selectedSessionID = session.id
        rememberSelectedSession(session.id)
        resetTerminalPresentation()
        send(.init(type: .attach, sessionID: session.id, includeRecent: true))
        ensureAutomaticMarkdownStream()
    }

    func open(_ file: TerminalRemoteProtocol.FileItem) {
        if file.isDirectory {
            browseFiles(path: file.path)
        } else if file.isMarkdown {
            loadMarkdown(path: file.path)
        }
    }

    func loadMarkdown(path: String) {
        send(.init(type: .readMarkdown, path: path))
    }

    func sendPendingInput() {
        let input = pendingInput
        guard !input.isEmpty, selectedSessionID != nil else {
            return
        }

        pendingInput.removeAll()
        sendInput(Data((input + "\r").utf8))
    }

    func sendInput(_ data: Data) {
        guard let selectedSessionID else { return }

        ensureAutomaticMarkdownStream()
        send(.init(type: .input, sessionID: selectedSessionID, data: data))
    }

    func resizeTerminal(columns: Int, rows: Int) {
        guard
            let selectedSessionID,
            columns > 0,
            rows > 0
        else {
            return
        }

        send(.init(type: .resize, sessionID: selectedSessionID, columns: columns, rows: rows))
    }

    private func send(_ message: TerminalRemoteProtocol.ClientMessage) {
        guard let context = connectionContext else {
            return
        }

        do {
            var data = try encoder.encode(message)
            data.append(0x0a)
            context.connection.send(content: data, completion: .contentProcessed { [weak self, weak context] error in
                if let error {
                    DispatchQueue.main.async {
                        guard let context, self?.connectionContext?.id == context.id else {
                            return
                        }
                        self?.statusMessage = error.localizedDescription
                    }
                }
            })
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func receiveNext(_ context: ConnectionContext) {
        context.connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self, weak context] data, _, isComplete, error in
            guard let self, let context else {
                return
            }

            if let data, !data.isEmpty {
                context.receiveBuffer.append(data)
                guard self.processReceiveBuffer(context) else {
                    return
                }
            }

            if isComplete || error != nil {
                DispatchQueue.main.async {
                    guard self.connectionContext?.id == context.id else {
                        return
                    }
                    self.connectionContext = nil
                    self.isConnected = false
                    self.isAuthenticated = false
                }
                return
            }

            self.receiveNext(context)
        }
    }

    private func processReceiveBuffer(_ context: ConnectionContext) -> Bool {
        while let newlineIndex = context.receiveBuffer.firstIndex(of: 0x0a) {
            let frame = context.receiveBuffer[..<newlineIndex]
            context.receiveBuffer.removeSubrange(...newlineIndex)

            guard !frame.isEmpty else {
                continue
            }

            guard frame.count <= maxServerMessageBytes else {
                failOversizedServerMessage(context)
                return false
            }

            do {
                let message = try decoder.decode(TerminalRemoteProtocol.ServerMessage.self, from: Data(frame))
                DispatchQueue.main.async {
                    guard self.connectionContext?.id == context.id else {
                        return
                    }
                    self.handle(message)
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.connectionContext?.id == context.id else {
                        return
                    }
                    self.statusMessage = "Invalid server message"
                }
            }
        }

        guard context.receiveBuffer.count <= maxServerMessageBytes else {
            failOversizedServerMessage(context)
            return false
        }

        return true
    }

    private func failOversizedServerMessage(_ context: ConnectionContext) {
        DispatchQueue.main.async { [weak self] in
            guard self?.connectionContext?.id == context.id else {
                return
            }
            self?.disconnect()
            self?.statusMessage = "Mac sent a terminal update that is too large"
        }
    }

    private func handle(_ message: TerminalRemoteProtocol.ServerMessage) {
        switch message.type {
        case .hello:
            if let version = message.version, version > TerminalRemoteProtocol.version {
                statusMessage = "Mac requires a newer CodeEdit Remote version"
                disconnect()
                return
            }
            rememberDirectEndpoint(from: message)
            statusMessage = message.message ?? "Connected"
        case .authenticated:
            isAuthenticated = message.authenticated == true
            statusMessage = isAuthenticated ? "Authenticated" : "Connected"
            if isAuthenticated {
                browseFiles()
            }
        case .sessions:
            let updatedSessions = message.sessions ?? []
            let previousSelection = selectedSessionID
            sessions = updatedSessions

            if let previousSelection,
               !updatedSessions.contains(where: { $0.id == previousSelection }) {
                selectedSessionID = nil
                resetTerminalPresentation()
            }

            if selectedSessionID == nil {
                if let persistedSessionID = Self.loadPersistedSelectedSessionID(),
                   let persistedSession = sessions.first(where: { $0.id == persistedSessionID }) {
                    attach(to: persistedSession)
                } else if let first = sessions.first {
                    attach(to: first)
                }
            }
        case .input:
            guard message.sessionID == selectedSessionID else {
                return
            }
            flushProjectedOutputIfNeeded()
        case .output:
            guard message.sessionID == selectedSessionID else {
                return
            }
            if let projectedOutput = message.projectedOutput {
                recordTerminalOutput(projectedOutput)
            }
        case .fileList:
            currentDirectoryPath = message.path
            files = message.files ?? []
        case .markdown:
            markdownDocument = message.markdown
        case .markdownStream:
            handleMarkdownStream(message.markdownStream)
        case .error:
            statusMessage = message.message ?? "Error"
            markMarkdownStreamErrorIfNeeded(statusMessage)
        }
    }
}

private extension RemoteTerminalClient {
    static let maxPersistedMarkdownByteCount = 4 * 1024 * 1024
    static let maxPersistedMarkdownStreamByteCount = 4 * 1024 * 1024

    /// Loads the last-opened Markdown document persisted by `persistMarkdownDocument(_:)`, if any.
    static func loadPersistedMarkdownDocument() -> TerminalRemoteProtocol.MarkdownDocument? {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.lastMarkdownDocument) else {
            return nil
        }

        return try? JSONDecoder().decode(TerminalRemoteProtocol.MarkdownDocument.self, from: data)
    }

    /// Persists the current Markdown document so the Markdown tab can be restored on the next launch.
    /// Clears the stored copy when there is no document, and skips unusually large files to keep the
    /// UserDefaults store small.
    func persistMarkdownDocument(_ document: TerminalRemoteProtocol.MarkdownDocument?) {
        guard let document else {
            UserDefaults.standard.removeObject(forKey: DefaultsKey.lastMarkdownDocument)
            return
        }

        guard let data = try? JSONEncoder().encode(document),
              data.count <= Self.maxPersistedMarkdownByteCount else {
            UserDefaults.standard.removeObject(forKey: DefaultsKey.lastMarkdownDocument)
            return
        }

        UserDefaults.standard.set(data, forKey: DefaultsKey.lastMarkdownDocument)
    }

    static func loadPersistedSelectedSessionID() -> UUID? {
        guard let value = UserDefaults.standard.string(forKey: DefaultsKey.lastSelectedSessionID) else {
            return nil
        }

        return UUID(uuidString: value)
    }

    func rememberSelectedSession(_ sessionID: UUID) {
        UserDefaults.standard.set(sessionID.uuidString, forKey: DefaultsKey.lastSelectedSessionID)
    }

    static func loadPersistedMarkdownStreamState() -> PersistedMarkdownStreamState? {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.lastMarkdownStreamState) else {
            return nil
        }

        return try? JSONDecoder().decode(PersistedMarkdownStreamState.self, from: data)
    }

    static func loadPersistedMarkdownStreamDocument() -> TerminalRemoteProtocol.MarkdownStreamDocument? {
        loadPersistedMarkdownStreamState()?.document
    }

    func persistedMarkdownStreamState(for sessionID: UUID) -> PersistedMarkdownStreamState? {
        guard let state = Self.loadPersistedMarkdownStreamState(),
              state.sessionID == sessionID else {
            return nil
        }

        return state
    }

    func persistMarkdownStreamState(_ document: TerminalRemoteProtocol.MarkdownStreamDocument) {
        guard document.isActive else {
            clearPersistedMarkdownStreamState()
            return
        }

        let fullState = PersistedMarkdownStreamState(document: document)
        if let data = try? JSONEncoder().encode(fullState),
           data.count <= Self.maxPersistedMarkdownStreamByteCount {
            UserDefaults.standard.set(data, forKey: DefaultsKey.lastMarkdownStreamState)
            return
        }

        let metadataOnlyState = PersistedMarkdownStreamState(document: document, markdown: "")
        if let data = try? JSONEncoder().encode(metadataOnlyState) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.lastMarkdownStreamState)
        }
    }

    func clearPersistedMarkdownStreamState() {
        UserDefaults.standard.removeObject(forKey: DefaultsKey.lastMarkdownStreamState)
    }
}

extension RemoteTerminalClient {
    private static let automaticMarkdownStreamPrompt = """
    Maintain a concise, structured Markdown stream from this terminal session. After each terminal prompt
    or command finishes, convert the useful new information into rendered Markdown. Keep a one-to-one
    correspondence for formulas, equations, tables, code, definitions, numeric results, and decisions.
    """

    @discardableResult
    func ensureAutomaticMarkdownStream() -> Bool {
        guard let selectedSessionID else {
            return false
        }

        if markdownStreamIsActive,
           markdownStreamDocument?.sessionID == selectedSessionID {
            if let activeMarkdownStreamID,
               pendingMarkdownStreamHandshakeIDs.contains(activeMarkdownStreamID) {
                let resumePath = persistedMarkdownStreamState(for: selectedSessionID)?.path
                sendMarkdownStreamStart(
                    streamID: activeMarkdownStreamID,
                    sessionID: selectedSessionID,
                    resumePath: resumePath
                )
                return true
            }

            if markdownStreamDocument?.path.isEmpty == false {
                return true
            }

            if let activeMarkdownStreamID {
                let resumePath = persistedMarkdownStreamState(for: selectedSessionID)?.path
                sendMarkdownStreamStart(
                    streamID: activeMarkdownStreamID,
                    sessionID: selectedSessionID,
                    resumePath: resumePath
                )
            }
            return true
        }

        let persistedState = persistedMarkdownStreamState(for: selectedSessionID)
        let streamID = persistedState?.streamID ?? UUID()
        let resumePath = persistedState?.path
        activeMarkdownStreamID = streamID
        lastMarkdownStreamRevision = nil
        pendingMarkdownStreamHandshakeIDs.insert(streamID)
        markdownStreamIsActive = true
        markdownStreamStatus = persistedState == nil
            ? "Starting automatic Markdown stream"
            : "Resuming Markdown stream"
        markdownStreamStatusDetail = persistedState == nil
            ? nil
            : "Reopening the previous stream file for this terminal session."
        markdownStreamIsTruncated = persistedState?.isTruncated == true

        let document = TerminalRemoteProtocol.MarkdownStreamDocument(
            streamID: streamID,
            sessionID: selectedSessionID,
            path: persistedState?.path ?? "",
            name: persistedState?.name ?? "Markdown Stream",
            markdown: persistedState?.markdown ?? "",
            isActive: true,
            status: .init(
                phase: .starting,
                title: markdownStreamStatus,
                detail: markdownStreamStatusDetail,
                isTruncated: markdownStreamIsTruncated
            )
        )
        markdownStreamDocument = document
        persistMarkdownStreamState(document)
        scheduleMarkdownStreamHandshakeTimeout(streamID: streamID, resumePath: resumePath)
        sendMarkdownStreamStart(streamID: streamID, sessionID: selectedSessionID, resumePath: resumePath)
        return true
    }

    func stopMarkdownStream() {
        guard let activeMarkdownStreamID else {
            return
        }

        requestedStoppedMarkdownStreamIDs.insert(activeMarkdownStreamID)
        clearPersistedMarkdownStreamState()
        markdownStreamStatus = "Stopping Markdown stream"
        send(.init(type: .stopMarkdownStream, streamID: activeMarkdownStreamID))
    }

    func triggerMarkdownStreamUpdate() {
        guard let activeMarkdownStreamID else {
            ensureAutomaticMarkdownStream()
            return
        }

        markdownStreamStatus = "Triggering Markdown update"
        send(.init(type: .triggerMarkdownStreamUpdate, streamID: activeMarkdownStreamID))
    }

    func rewriteMarkdownStream(prompt rawPrompt: String) {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            markdownStreamStatus = "Enter a rewrite prompt"
            return
        }

        guard let activeMarkdownStreamID else {
            if ensureAutomaticMarkdownStream() {
                markdownStreamStatus = "Start received; try rewrite again after the stream file appears"
            }
            return
        }

        markdownStreamStatus = "Rewriting Markdown with Claude"
        send(.init(
            type: .rewriteMarkdownStream,
            prompt: prompt,
            streamID: activeMarkdownStreamID
        ))
    }

    private func sendMarkdownStreamStart(streamID: UUID, sessionID: UUID, resumePath: String? = nil) {
        send(.init(
            type: .startMarkdownStream,
            sessionID: sessionID,
            path: resumePath?.isEmpty == false ? resumePath : nil,
            prompt: Self.automaticMarkdownStreamPrompt,
            streamID: streamID
        ))
    }

    private func scheduleMarkdownStreamHandshakeTimeout(
        streamID: UUID,
        resumePath: String?,
        shouldRetry: Bool = true
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard
                let self,
                self.activeMarkdownStreamID == streamID,
                self.pendingMarkdownStreamHandshakeIDs.contains(streamID)
            else {
                return
            }

            if shouldRetry, let selectedSessionID = self.selectedSessionID {
                self.markdownStreamStatus = "Retrying Mac stream"
                self.markdownStreamDocument = TerminalRemoteProtocol.MarkdownStreamDocument(
                    streamID: streamID,
                    sessionID: selectedSessionID,
                    path: self.markdownStreamDocument?.path ?? "",
                    name: self.markdownStreamDocument?.name ?? "Markdown Stream",
                    markdown: self.markdownStreamDocument?.markdown ?? "",
                    isActive: true
                )
                self.sendMarkdownStreamStart(streamID: streamID, sessionID: selectedSessionID, resumePath: resumePath)
                self.scheduleMarkdownStreamHandshakeTimeout(
                    streamID: streamID,
                    resumePath: resumePath,
                    shouldRetry: false
                )
                return
            }

            self.markdownStreamStatus = "Waiting for Mac stream"
            self.markdownStreamStatusDetail = "The Mac did not acknowledge the Markdown stream start request."
            self.markdownStreamIsTruncated = false
            self.markdownStreamDocument = TerminalRemoteProtocol.MarkdownStreamDocument(
                streamID: streamID,
                sessionID: self.selectedSessionID ?? UUID(),
                path: self.markdownStreamDocument?.path ?? "",
                name: self.markdownStreamDocument?.name ?? "Markdown Stream",
                markdown: self.markdownStreamDocument?.markdown ?? "",
                isActive: false
            )
            self.markdownStreamIsActive = false
            self.activeMarkdownStreamID = nil
            self.pendingMarkdownStreamHandshakeIDs.remove(streamID)
        }
    }

    private func markMarkdownStreamErrorIfNeeded(_ message: String) {
        guard markdownStreamIsActive, let document = markdownStreamDocument else {
            return
        }

        markdownStreamStatus = message
        markdownStreamStatusDetail = nil
        markdownStreamIsTruncated = false
        markdownStreamDocument = TerminalRemoteProtocol.MarkdownStreamDocument(
            streamID: document.streamID,
            sessionID: document.sessionID,
            path: document.path,
            name: document.name,
            markdown: "",
            isActive: false
        )
        markdownStreamIsActive = false
        activeMarkdownStreamID = nil
        pendingMarkdownStreamHandshakeIDs.remove(document.streamID)
    }
}

private extension RemoteTerminalClient {
    private func resetTerminalPresentation() {
        projectedOutputFlushWorkItem?.cancel()
        projectedOutputFlushWorkItem = nil
        pendingProjectedOutput = nil
        terminalMirrorSnapshot = terminalMirrorBuffer.reset()
        activeMarkdownStreamID = nil
        markdownStreamDocument = nil
        markdownStreamStatus = "No Markdown stream"
        markdownStreamStatusDetail = nil
        markdownStreamIsTruncated = false
        markdownStreamIsActive = false
        lastMarkdownStreamRevision = nil
        pendingMarkdownStreamHandshakeIDs.removeAll()
    }

    private func recordTerminalOutput(_ projectedOutput: TerminalRemoteProtocol.ProjectedOutput) {
        mergePendingProjectedOutput(projectedOutput)
        scheduleProjectedOutputFlush()
    }

    private func mergePendingProjectedOutput(_ output: TerminalRemoteProtocol.ProjectedOutput) {
        guard let pendingProjectedOutput else {
            self.pendingProjectedOutput = output
            return
        }

        if pendingProjectedOutput.generation == nil,
           output.generation == nil,
           output.sequence < pendingProjectedOutput.sequence {
            // Protocol v1 represented resize/reflow with a sequence reset. Preserve that reset
            // through the batching layer so TerminalMirrorBuffer can clear the old geometry.
            self.pendingProjectedOutput = output
            return
        }

        let pendingGeneration = pendingProjectedOutput.generation ?? 0
        let outputGeneration = output.generation ?? pendingGeneration
        guard outputGeneration >= pendingGeneration else {
            return
        }

        if outputGeneration > pendingGeneration || output.isSnapshot == true {
            self.pendingProjectedOutput = output
            return
        }

        let pendingMode = pendingProjectedOutput.screenMode
        let outputMode = output.screenMode
        guard output.sequence >= pendingProjectedOutput.sequence else {
            return
        }
        guard pendingMode == outputMode else {
            self.pendingProjectedOutput = output
            return
        }

        var rowsByIndex = Dictionary(
            pendingProjectedOutput.rows.map { ($0.row, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        for row in output.rows {
            rowsByIndex[row.row] = row
        }

        let rows = rowsByIndex.keys.sorted().compactMap { rowsByIndex[$0] }

        self.pendingProjectedOutput = TerminalRemoteProtocol.ProjectedOutput(
            sequence: output.sequence,
            generation: output.generation ?? pendingProjectedOutput.generation,
            isSnapshot: pendingProjectedOutput.isSnapshot == true,
            screenMode: output.screenMode ?? pendingProjectedOutput.screenMode,
            columns: output.columns ?? pendingProjectedOutput.columns,
            terminalRows: output.terminalRows ?? pendingProjectedOutput.terminalRows,
            cursor: output.cursor ?? pendingProjectedOutput.cursor,
            rows: rows
        )
    }

    private func scheduleProjectedOutputFlush() {
        guard projectedOutputFlushWorkItem == nil else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.flushProjectedOutputIfNeeded()
        }
        projectedOutputFlushWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50), execute: workItem)
    }

    private func flushProjectedOutputIfNeeded() {
        projectedOutputFlushWorkItem?.cancel()
        projectedOutputFlushWorkItem = nil

        guard let output = pendingProjectedOutput else {
            return
        }

        pendingProjectedOutput = nil
        terminalMirrorSnapshot = terminalMirrorBuffer.apply(output)
    }

    private func handleMarkdownStream(_ document: TerminalRemoteProtocol.MarkdownStreamDocument?) {
        guard let document else {
            return
        }

        if activeMarkdownStreamID == nil {
            activeMarkdownStreamID = document.streamID
            lastMarkdownStreamRevision = nil
        }

        guard document.streamID == activeMarkdownStreamID else {
            return
        }

        if let revision = document.revision {
            if let lastMarkdownStreamRevision, revision < lastMarkdownStreamRevision {
                return
            }
            lastMarkdownStreamRevision = revision
        }

        pendingMarkdownStreamHandshakeIDs.remove(document.streamID)
        markdownStreamDocument = document
        markdownStreamIsActive = document.isActive
        if let status = document.status {
            markdownStreamStatus = status.title
            markdownStreamStatusDetail = status.detail
            markdownStreamIsTruncated = status.isTruncated == true
        } else {
            markdownStreamStatus = document.isActive ? "Streaming Markdown" : "Markdown stream stopped"
            markdownStreamStatusDetail = nil
            markdownStreamIsTruncated = false
        }

        if !document.isActive {
            requestedStoppedMarkdownStreamIDs.remove(document.streamID)
            clearPersistedMarkdownStreamState()
            activeMarkdownStreamID = nil
        } else {
            requestedStoppedMarkdownStreamIDs.remove(document.streamID)
            persistMarkdownStreamState(document)
        }
    }

    private func rememberDirectEndpoint(from message: TerminalRemoteProtocol.ServerMessage) {
        guard shouldRememberEndpointFromHello else {
            return
        }

        if let port = message.port {
            localPort = String(port)
            if globalPort.isEmpty {
                globalPort = String(port)
            }
        }

        let addresses = message.addresses ?? []
        if let localAddress = Self.preferredLocalAddress(from: addresses) {
            localHost = localAddress
        }

        if let publicAddress = Self.normalizedGlobalAddress(message.publicAddress),
           shouldReplaceGlobalHostWithPublicAddress {
            globalHost = publicAddress
            return
        }

        if globalHost.isEmpty, let globalAddress = Self.preferredGlobalAddress(from: addresses) {
            globalHost = globalAddress
        }
    }

    private var shouldReplaceGlobalHostWithPublicAddress: Bool {
        let host = globalHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            return true
        }

        guard Self.isIPv4Address(host) else {
            return false
        }

        return !Self.isTailscaleAddress(host)
    }

    private static func preferredLocalAddress(from addresses: [String]) -> String? {
        addresses.first(where: isPrivateLANAddress)
            ?? addresses.first(where: { !isTailscaleAddress($0) })
    }

    private static func preferredGlobalAddress(from addresses: [String]) -> String? {
        addresses.first(where: isTailscaleAddress)
    }

    private static func normalizedGlobalAddress(_ address: String?) -> String? {
        guard let address = address?.trimmingCharacters(in: .whitespacesAndNewlines),
              isPublicInternetAddress(address) else {
            return nil
        }

        return address
    }

    private static func isPublicInternetAddress(_ address: String) -> Bool {
        guard let octets = ipv4Octets(for: address) else {
            return false
        }

        if octets[0] == 0 || octets[0] == 127 || octets[0] >= 224 {
            return false
        }

        if octets[0] == 169 && octets[1] == 254 {
            return false
        }

        return !isPrivateLANAddress(address) && !isTailscaleAddress(address)
    }

    private static func isIPv4Address(_ address: String) -> Bool {
        ipv4Octets(for: address) != nil
    }

    private static func isTailscaleAddress(_ address: String) -> Bool {
        guard let octets = ipv4Octets(for: address) else {
            return false
        }

        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    private static func isPrivateLANAddress(_ address: String) -> Bool {
        guard let octets = ipv4Octets(for: address) else {
            return false
        }

        if octets[0] == 10 || (octets[0] == 192 && octets[1] == 168) {
            return true
        }

        return octets[0] == 172 && (16...31).contains(octets[1])
    }

    private static func ipv4Octets(for address: String) -> [Int]? {
        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return nil
        }

        return octets
    }

    private static func discoveredHost(_ result: NWBrowser.Result) -> DiscoveredHost {
        switch result.endpoint {
        case .service(name: let name, type: _, domain: _, interface: _):
            return DiscoveredHost(id: result.endpoint.debugDescription, name: name, endpoint: result.endpoint)
        default:
            return DiscoveredHost(
                id: result.endpoint.debugDescription,
                name: result.endpoint.debugDescription,
                endpoint: result.endpoint
            )
        }
    }
}
