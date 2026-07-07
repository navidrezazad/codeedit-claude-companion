//
//  RemoteTerminalClient.swift
//  CodeEditRemoteiOS
//
//  Created by Claude on 6/12/26.
//

import Foundation
import Network
import UIKit

private enum CommandTranscriptSize {
    static let columns = 140
    static let rows = 50
}

private enum DefaultsKey {
    static let passcode = "CodeEditRemote.passcode"
    static let legacyDirectHost = "CodeEditRemote.directHost"
    static let legacyDirectPort = "CodeEditRemote.directPort"
    static let localHost = "CodeEditRemote.localHost"
    static let localPort = "CodeEditRemote.localPort"
    static let globalHost = "CodeEditRemote.globalHost"
    static let globalPort = "CodeEditRemote.globalPort"
    static let lastMarkdownDocument = "CodeEditRemote.lastMarkdownDocument"
}

// swiftlint:disable:next type_body_length
final class RemoteTerminalClient: ObservableObject {
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
    /// Per-session Markdown stream state, so each session keeps its own stream/view independently.
    struct MarkdownStreamState {
        var document: TerminalRemoteProtocol.MarkdownStreamDocument?
        var status: String = "No Markdown stream"
        var isActive: Bool = false
        var activeStreamID: UUID?
    }

    @Published private var markdownStates: [UUID: MarkdownStreamState] = [:]

    /// The selected session's Markdown stream document/status/active flag (read by the stream view).
    /// These are computed over the per-session map so switching sessions shows the right stream.
    var markdownStreamDocument: TerminalRemoteProtocol.MarkdownStreamDocument? {
        selectedSessionID.flatMap { markdownStates[$0]?.document }
    }
    var markdownStreamStatus: String {
        (selectedSessionID.flatMap { markdownStates[$0]?.status }) ?? "No Markdown stream"
    }
    var markdownStreamIsActive: Bool {
        (selectedSessionID.flatMap { markdownStates[$0]?.isActive }) ?? false
    }

    private let queue = DispatchQueue(label: "app.codeedit.remote-terminal-client")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var terminalMirrorBuffer = TerminalMirrorBuffer()
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var pendingProjectedOutput: TerminalRemoteProtocol.ProjectedOutput?
    private var projectedOutputFlushWorkItem: DispatchWorkItem?
    private var shouldRememberEndpointFromHello = false
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
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else {
                return
            }

            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self.connectionInFlight = false
                    self.isConnected = true
                    self.statusMessage = "Connected"
                    self.receiveNext()
                    if !self.passcode.isEmpty {
                        self.authenticate()
                    }
                case .failed(let error):
                    self.connectionInFlight = false
                    self.statusMessage = error.localizedDescription
                    self.isConnected = false
                    self.isAuthenticated = false
                case .cancelled:
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
        connection?.cancel()
        connection = nil
        connectionInFlight = false
        receiveBuffer.removeAll()
        sessions.removeAll()
        selectedSessionID = nil
        resetTerminalPresentation()
        markdownStates.removeAll()
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

    /// Asks the Mac to create a new tmux session with the given name, then refresh the list.
    func createTmuxSession(name rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return
        }
        send(.init(type: .createTmuxSession, sessionName: name))
    }

    /// Asks the Mac to kill the named tmux session, then refresh the list.
    func killTmuxSession(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        send(.init(type: .killTmuxSession, sessionName: trimmed))
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
        selectedSessionID = session.id
        resetTerminalPresentation()
        send(.init(type: .attach, sessionID: session.id, includeRecent: true))
        resizeTerminal(columns: CommandTranscriptSize.columns, rows: CommandTranscriptSize.rows)
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
        guard let connection else {
            return
        }

        do {
            var data = try encoder.encode(message)
            data.append(0x0a)
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error {
                    DispatchQueue.main.async {
                        self?.statusMessage = error.localizedDescription
                    }
                }
            })
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func receiveNext() {
        connection?.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }

            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.processReceiveBuffer()
            }

            if isComplete || error != nil {
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.isAuthenticated = false
                }
                return
            }

            self.receiveNext()
        }
    }

    private func processReceiveBuffer() {
        while let newlineIndex = receiveBuffer.firstIndex(of: 0x0a) {
            let frame = receiveBuffer[..<newlineIndex]
            receiveBuffer.removeSubrange(...newlineIndex)

            guard !frame.isEmpty else {
                continue
            }

            do {
                let message = try decoder.decode(TerminalRemoteProtocol.ServerMessage.self, from: Data(frame))
                DispatchQueue.main.async {
                    self.handle(message)
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "Invalid server message"
                }
            }
        }
    }

    private func handle(_ message: TerminalRemoteProtocol.ServerMessage) {
        switch message.type {
        case .hello:
            rememberDirectEndpoint(from: message)
            statusMessage = message.message ?? "Connected"
        case .authenticated:
            isAuthenticated = message.authenticated == true
            statusMessage = isAuthenticated ? "Authenticated" : "Connected"
            if isAuthenticated {
                browseFiles()
            }
        case .sessions:
            sessions = message.sessions ?? []
            if selectedSessionID == nil, let first = sessions.first {
                attach(to: first)
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
            return
        }

        UserDefaults.standard.set(data, forKey: DefaultsKey.lastMarkdownDocument)
    }
}

extension RemoteTerminalClient {
    private static let automaticMarkdownStreamPrompt = """
    Maintain a concise, structured Markdown stream from this terminal session. After each terminal prompt
    or command finishes, convert the useful new information into rendered Markdown. Keep a one-to-one
    correspondence for formulas, equations, tables, code, definitions, numeric results, and decisions.
    """

    /// Mutates the Markdown stream state for a single session, creating a default entry if needed.
    func updateMarkdownState(for sessionID: UUID, _ mutate: (inout MarkdownStreamState) -> Void) {
        var state = markdownStates[sessionID] ?? MarkdownStreamState()
        mutate(&state)
        markdownStates[sessionID] = state
    }

    @discardableResult
    func ensureAutomaticMarkdownStream() -> Bool {
        guard let selectedSessionID else {
            return false
        }

        let state = markdownStates[selectedSessionID]
        if state?.isActive == true {
            if state?.document?.path.isEmpty == false {
                return true
            }
            if let streamID = state?.activeStreamID {
                sendMarkdownStreamStart(streamID: streamID, sessionID: selectedSessionID)
            }
            return true
        }

        let streamID = UUID()
        updateMarkdownState(for: selectedSessionID) {
            $0.activeStreamID = streamID
            $0.isActive = true
            $0.status = "Starting automatic Markdown stream"
            $0.document = TerminalRemoteProtocol.MarkdownStreamDocument(
                streamID: streamID,
                sessionID: selectedSessionID,
                path: "",
                name: "Markdown Stream",
                markdown: "",
                isActive: true
            )
        }
        scheduleMarkdownStreamHandshakeTimeout(streamID: streamID, sessionID: selectedSessionID)
        sendMarkdownStreamStart(streamID: streamID, sessionID: selectedSessionID)
        return true
    }

    func stopMarkdownStream() {
        guard let selectedSessionID, let streamID = markdownStates[selectedSessionID]?.activeStreamID else {
            return
        }

        updateMarkdownState(for: selectedSessionID) { $0.status = "Stopping Markdown stream" }
        send(.init(type: .stopMarkdownStream, streamID: streamID))
    }

    func triggerMarkdownStreamUpdate() {
        guard let selectedSessionID, let streamID = markdownStates[selectedSessionID]?.activeStreamID else {
            ensureAutomaticMarkdownStream()
            return
        }

        updateMarkdownState(for: selectedSessionID) { $0.status = "Triggering Markdown update" }
        send(.init(type: .triggerMarkdownStreamUpdate, streamID: streamID))
    }

    func rewriteMarkdownStream(prompt rawPrompt: String) {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let selectedSessionID else {
            return
        }
        guard !prompt.isEmpty else {
            updateMarkdownState(for: selectedSessionID) { $0.status = "Enter a rewrite prompt" }
            return
        }

        guard let streamID = markdownStates[selectedSessionID]?.activeStreamID else {
            if ensureAutomaticMarkdownStream() {
                updateMarkdownState(for: selectedSessionID) {
                    $0.status = "Start received; try rewrite again after the stream file appears"
                }
            }
            return
        }

        updateMarkdownState(for: selectedSessionID) { $0.status = "Rewriting Markdown with Claude" }
        send(.init(
            type: .rewriteMarkdownStream,
            prompt: prompt,
            streamID: streamID
        ))
    }

    private func sendMarkdownStreamStart(streamID: UUID, sessionID: UUID) {
        send(.init(
            type: .startMarkdownStream,
            sessionID: sessionID,
            prompt: Self.automaticMarkdownStreamPrompt,
            streamID: streamID
        ))
    }

    private func scheduleMarkdownStreamHandshakeTimeout(streamID: UUID, sessionID: UUID, shouldRetry: Bool = true) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else {
                return
            }
            let state = self.markdownStates[sessionID]
            guard state?.activeStreamID == streamID, state?.document?.path.isEmpty != false else {
                return
            }

            if shouldRetry {
                self.updateMarkdownState(for: sessionID) {
                    $0.status = "Retrying Mac stream"
                    $0.document = TerminalRemoteProtocol.MarkdownStreamDocument(
                        streamID: streamID,
                        sessionID: sessionID,
                        path: "",
                        name: "Markdown Stream",
                        markdown: "",
                        isActive: true
                    )
                }
                self.sendMarkdownStreamStart(streamID: streamID, sessionID: sessionID)
                self.scheduleMarkdownStreamHandshakeTimeout(
                    streamID: streamID,
                    sessionID: sessionID,
                    shouldRetry: false
                )
                return
            }

            self.updateMarkdownState(for: sessionID) {
                $0.status = "Waiting for Mac stream"
                $0.document = TerminalRemoteProtocol.MarkdownStreamDocument(
                    streamID: streamID,
                    sessionID: sessionID,
                    path: "",
                    name: "Markdown Stream",
                    markdown: "",
                    isActive: false
                )
                $0.isActive = false
                $0.activeStreamID = nil
            }
        }
    }

    private func markMarkdownStreamErrorIfNeeded(_ message: String) {
        guard let selectedSessionID,
              let state = markdownStates[selectedSessionID],
              state.isActive,
              let document = state.document else {
            return
        }

        updateMarkdownState(for: selectedSessionID) {
            $0.status = message
            $0.document = TerminalRemoteProtocol.MarkdownStreamDocument(
                streamID: document.streamID,
                sessionID: document.sessionID,
                path: document.path,
                name: document.name,
                markdown: "",
                isActive: false
            )
            $0.isActive = false
            $0.activeStreamID = nil
        }
    }
}

private extension RemoteTerminalClient {
    private func resetTerminalPresentation() {
        projectedOutputFlushWorkItem?.cancel()
        projectedOutputFlushWorkItem = nil
        pendingProjectedOutput = nil
        terminalMirrorSnapshot = terminalMirrorBuffer.reset()
        // Markdown streams are kept per-session in `markdownStates` so switching sessions preserves each
        // session's own view; they are intentionally not reset here.
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

        let pendingMode = pendingProjectedOutput.screenMode
        let outputMode = output.screenMode
        guard pendingMode == outputMode, output.sequence >= pendingProjectedOutput.sequence else {
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
            screenMode: output.screenMode ?? pendingProjectedOutput.screenMode,
            columns: output.columns ?? pendingProjectedOutput.columns,
            terminalRows: output.terminalRows ?? pendingProjectedOutput.terminalRows,
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

        let sessionID = document.sessionID
        var state = markdownStates[sessionID] ?? MarkdownStreamState()
        if state.activeStreamID == nil {
            state.activeStreamID = document.streamID
        }
        guard document.streamID == state.activeStreamID else {
            return
        }

        state.document = document
        state.isActive = document.isActive
        state.status = document.isActive ? "Streaming Markdown" : "Markdown stream stopped"
        if !document.isActive {
            state.activeStreamID = nil
        }
        markdownStates[sessionID] = state
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
