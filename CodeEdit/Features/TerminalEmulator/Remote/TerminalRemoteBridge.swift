//
//  TerminalRemoteBridge.swift
//  CodeEdit
//
//  Created by Claude on 6/12/26.
//

// swiftlint:disable file_length type_body_length line_length

import Foundation
import Network
import OSLog
import Security
import Darwin

final class TerminalRemoteBridge {
    static let shared = TerminalRemoteBridge()
    static let passcodeDefaultsKey = "CodeEditV2RemotePasscode"
    private static let preferredPort: NWEndpoint.Port = 52000
    private static let publicIPAddressURLStrings = [
        "https://api.ipify.org",
        "https://checkip.amazonaws.com"
    ]

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.codeedit.CodeEditV2",
        category: "TerminalRemoteBridge"
    )
    private let queue = DispatchQueue(label: "app.codeedit.terminal-remote-bridge")
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let endpointFileURL = URL(fileURLWithPath: "/tmp/codeeditv2-remote-endpoint.txt")
    private let maxMarkdownBytes = 5 * 1024 * 1024
    private let maxMarkdownStreamBytes = 8 * 1024 * 1024
    private let maxEmbeddedImageBytes = 10 * 1024 * 1024
    private var listener: NWListener?
    private(set) var listeningPort: UInt16 = 0
    private var clients: [UUID: Client] = [:]
    private var publicIPAddress: String?
    private var publicIPAddressFetchInFlight = false
    private var publicIPAddressCompletionHandlers: [(String?) -> Void] = []

    private init() {
        _ = Self.currentPasscode()
    }

    static func currentPasscode() -> String {
        let defaults = UserDefaults.standard
        if let passcode = defaults.string(forKey: passcodeDefaultsKey), !passcode.isEmpty {
            return passcode
        }

        let passcode = makeNumericPasscode()
        defaults.set(passcode, forKey: passcodeDefaultsKey)
        return passcode
    }

    static func updatePasscode(_ passcode: String) {
        let trimmedPasscode = passcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPasscode.isEmpty else {
            return
        }

        UserDefaults.standard.set(trimmedPasscode, forKey: passcodeDefaultsKey)
    }

    static func generateAndStorePasscode() -> String {
        let passcode = makeNumericPasscode()
        updatePasscode(passcode)
        return passcode
    }

    func start() {
        queue.async {
            guard self.listener == nil else {
                return
            }

            do {
                let listener: NWListener
                do {
                    listener = try NWListener(using: .tcp, on: Self.preferredPort)
                } catch {
                    listener = try NWListener(using: .tcp)
                }
                listener.service = NWListener.Service(
                    name: Host.current().localizedName ?? "CodeEditV2",
                    type: TerminalRemoteProtocol.serviceType
                )
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    self?.handleListenerState(state)
                }
                listener.start(queue: self.queue)
                self.listener = listener
            } catch {
                self.logger.error("Failed to start terminal remote bridge: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        queue.async {
            self.clients.values.forEach { $0.cancel() }
            self.clients.removeAll()
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private func accept(_ connection: NWConnection) {
        let client = Client(connection: connection, bridge: self)
        clients[client.id] = client
        client.start()
    }

    private func removeClient(_ id: UUID) {
        clients[id]?.cancel()
        clients[id] = nil
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            let port = listener?.port?.rawValue ?? 0
            listeningPort = port
            writeEndpointFile()
            refreshPublicIPAddressIfNeeded { [weak self] _ in
                self?.writeEndpointFile()
            }
            logger.info(
                "Terminal remote bridge listening on port \(port, privacy: .public)."
            )
        case .failed(let error):
            logger.error("Terminal remote bridge failed: \(error.localizedDescription)")
            stop()
        case .cancelled:
            logger.info("Terminal remote bridge stopped")
        default:
            break
        }
    }

    private func handle(_ message: TerminalRemoteProtocol.ClientMessage, from client: Client) {
        switch message.type {
        case .authenticate:
            authenticate(message, from: client)
        case .list:
            listSessions(for: client)
        case .attach:
            attach(message, from: client)
        case .detach:
            detach(message, from: client)
        case .input:
            sendInput(message, from: client)
        case .resize:
            resizeTerminal(message, from: client)
        case .browseFiles:
            browseFiles(message, from: client)
        case .readMarkdown:
            readMarkdown(message, from: client)
        case .startMarkdownStream:
            startMarkdownStream(message, from: client)
        case .stopMarkdownStream:
            stopMarkdownStream(message, from: client)
        case .triggerMarkdownStreamUpdate:
            triggerMarkdownStreamUpdate(message, from: client)
        case .rewriteMarkdownStream:
            rewriteMarkdownStream(message, from: client)
        }
    }

    private func authenticate(_ message: TerminalRemoteProtocol.ClientMessage, from client: Client) {
        guard message.token == Self.currentPasscode() else {
            client.sendError("Invalid passcode.")
            return
        }

        client.isAuthenticated = true
        client.send(.init(type: .authenticated, authenticated: true))
        client.sendSessions()
    }

    private func listSessions(for client: Client) {
        guard client.requireAuthentication() else {
            return
        }

        client.sendSessions()
    }

    private func attach(_ message: TerminalRemoteProtocol.ClientMessage, from client: Client) {
        guard client.requireAuthentication(), let sessionID = message.sessionID else {
            return
        }

        client.attach(to: sessionID, includeRecent: message.includeRecent ?? true)
    }

    private func detach(_ message: TerminalRemoteProtocol.ClientMessage, from client: Client) {
        guard client.requireAuthentication(), let sessionID = message.sessionID else {
            return
        }

        client.detach(from: sessionID)
    }

    private func sendInput(_ message: TerminalRemoteProtocol.ClientMessage, from client: Client) {
        guard client.requireAuthentication(), let sessionID = message.sessionID, let data = message.data else {
            return
        }

        let bytes = ArraySlice(data)
        DispatchQueue.main.async {
            TerminalSessionManager.shared.sendInput(bytes, to: sessionID)
        }
    }

    private func resizeTerminal(_ message: TerminalRemoteProtocol.ClientMessage, from client: Client) {
        guard
            client.requireAuthentication(),
            let sessionID = message.sessionID,
            let columns = message.columns,
            let rows = message.rows
        else {
            return
        }

        DispatchQueue.main.async {
            TerminalSessionManager.shared.resizeSession(sessionID, columns: columns, rows: rows)
        }
    }

    private func browseFiles(_ message: TerminalRemoteProtocol.ClientMessage, from client: Client) {
        guard client.requireAuthentication() else {
            return
        }

        client.sendFileList(path: message.path)
    }

    private func readMarkdown(_ message: TerminalRemoteProtocol.ClientMessage, from client: Client) {
        guard client.requireAuthentication() else {
            return
        }

        client.sendMarkdown(path: message.path)
    }

    private func startMarkdownStream(_ message: TerminalRemoteProtocol.ClientMessage, from client: Client) {
        guard
            client.requireAuthentication(),
            let sessionID = message.sessionID,
            let prompt = message.prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
            !prompt.isEmpty
        else {
            return
        }

        client.startMarkdownStream(
            sessionID: sessionID,
            prompt: prompt,
            streamID: message.streamID ?? UUID(),
            resumePath: message.path
        )
    }

    private func stopMarkdownStream(_ message: TerminalRemoteProtocol.ClientMessage, from client: Client) {
        guard client.requireAuthentication() else {
            return
        }

        client.stopMarkdownStream(streamID: message.streamID)
    }

    private func triggerMarkdownStreamUpdate(
        _ message: TerminalRemoteProtocol.ClientMessage,
        from client: Client
    ) {
        guard client.requireAuthentication() else {
            return
        }

        client.triggerMarkdownStreamUpdate(streamID: message.streamID)
    }

    private func rewriteMarkdownStream(
        _ message: TerminalRemoteProtocol.ClientMessage,
        from client: Client
    ) {
        guard
            client.requireAuthentication(),
            let prompt = message.prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
            !prompt.isEmpty
        else {
            return
        }

        client.rewriteMarkdownStream(streamID: message.streamID, prompt: prompt)
    }

    private func helloMessage() -> TerminalRemoteProtocol.ServerMessage {
        .init(
            type: .hello,
            version: TerminalRemoteProtocol.version,
            authenticated: false,
            message: "Authenticate with the Mac passcode before listing or attaching to terminals.",
            port: listener?.port?.rawValue,
            addresses: Self.localIPAddresses(),
            publicAddress: publicIPAddress,
            defaultPath: defaultBrowseRootURL().path
        )
    }

    private func writeEndpointFile() {
        let endpointMessage = makeEndpointMessage()
        print(endpointMessage)
        try? endpointMessage.appending("\n").write(to: endpointFileURL, atomically: true, encoding: .utf8)
    }

    private func makeEndpointMessage() -> String {
        let port = listener?.port?.rawValue ?? 0
        let addresses = Self.localIPAddresses().joined(separator: ", ")
        let publicAddressText = publicIPAddress.map { ", public address \($0)" } ?? ""

        return "CodeEditV2 remote bridge: port \(port), addresses \(addresses)\(publicAddressText)"
    }

    /// Connection details the iPhone needs to pair, encoded into a scannable `codeeditv2://pair` link.
    struct RemotePairingInfo {
        let host: String
        let port: UInt16
        let passcode: String

        var pairingURLString: String {
            var components = URLComponents()
            components.scheme = "codeeditv2"
            components.host = "pair"
            components.queryItems = [
                URLQueryItem(name: "host", value: host),
                URLQueryItem(name: "port", value: String(port)),
                URLQueryItem(name: "code", value: passcode)
            ]
            return components.url?.absoluteString ?? ""
        }
    }

    /// Best-effort pairing details for the QR shown in Settings. Returns `nil` until the bridge is
    /// listening and a reachable local address is available.
    func pairingInfo() -> RemotePairingInfo? {
        let port = listeningPort
        guard port != 0 else {
            return nil
        }

        let addresses = Self.localIPAddresses()
        guard let host = Self.preferredPairingAddress(from: addresses) else {
            return nil
        }

        return RemotePairingInfo(host: host, port: port, passcode: Self.currentPasscode())
    }

    private static func preferredPairingAddress(from addresses: [String]) -> String? {
        addresses.first(where: isPrivateLANAddress) ?? addresses.first
    }

    private static func isPrivateLANAddress(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }

        if octets[0] == 10 || (octets[0] == 192 && octets[1] == 168) {
            return true
        }

        return octets[0] == 172 && (16...31).contains(octets[1])
    }

    private func refreshPublicIPAddressIfNeeded(completion: ((String?) -> Void)? = nil) {
        if let publicIPAddress {
            completion?(publicIPAddress)
            return
        }

        if let completion {
            publicIPAddressCompletionHandlers.append(completion)
        }

        guard !publicIPAddressFetchInFlight else {
            return
        }

        publicIPAddressFetchInFlight = true
        fetchPublicIPAddress(urlIndex: 0)
    }

    private func fetchPublicIPAddress(urlIndex: Int) {
        guard urlIndex < Self.publicIPAddressURLStrings.count else {
            queue.async {
                self.finishPublicIPAddressFetch(address: nil)
            }
            return
        }

        guard let url = URL(string: Self.publicIPAddressURLStrings[urlIndex]) else {
            fetchPublicIPAddress(urlIndex: urlIndex + 1)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 4

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self else {
                return
            }

            if let data,
                let text = String(data: data, encoding: .utf8),
                let address = Self.normalizedPublicIPAddress(from: text) {
                self.queue.async {
                    self.finishPublicIPAddressFetch(address: address)
                }
                return
            }

            self.fetchPublicIPAddress(urlIndex: urlIndex + 1)
        }.resume()
    }

    private func finishPublicIPAddressFetch(address: String?) {
        publicIPAddress = address
        publicIPAddressFetchInFlight = false

        let handlers = publicIPAddressCompletionHandlers
        publicIPAddressCompletionHandlers.removeAll()
        handlers.forEach { $0(address) }
    }

    private func fileListMessage(path: String?) throws -> TerminalRemoteProtocol.ServerMessage {
        let directoryURL = try resolvedReadableURL(path)
        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FileAccessError.notDirectory
        }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        )

        let files = urls.compactMap { url -> TerminalRemoteProtocol.FileItem? in
            guard let values = try? url.resourceValues(forKeys: keys) else {
                return nil
            }

            let isDirectory = values.isDirectory == true
            let isRegularFile = values.isRegularFile == true
            guard isDirectory || isRegularFile else {
                return nil
            }

            return TerminalRemoteProtocol.FileItem(
                name: url.lastPathComponent,
                path: url.path,
                isDirectory: isDirectory,
                isMarkdown: !isDirectory && Self.isMarkdownFile(url),
                byteCount: values.fileSize.map(Int64.init)
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        return .init(type: .fileList, path: directoryURL.path, files: files)
    }

    private func markdownMessage(path: String?) throws -> TerminalRemoteProtocol.ServerMessage {
        guard let path else {
            throw FileAccessError.notMarkdown
        }

        let fileURL = try resolvedReadableURL(path)
        guard Self.isMarkdownFile(fileURL) else {
            throw FileAccessError.notMarkdown
        }

        let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        guard values.isDirectory != true else {
            throw FileAccessError.notMarkdown
        }

        if let fileSize = values.fileSize, fileSize > maxMarkdownBytes {
            throw FileAccessError.markdownTooLarge
        }

        let markdown = try String(contentsOf: fileURL, encoding: .utf8)
        let markdownWithImages = markdownByEmbeddingLocalImages(
            in: markdown,
            baseURL: fileURL.deletingLastPathComponent()
        )
        if markdownWithImages.utf8.count > maxMarkdownBytes {
            throw FileAccessError.markdownTooLarge
        }
        let document = TerminalRemoteProtocol.MarkdownDocument(
            path: fileURL.path,
            name: fileURL.lastPathComponent,
            markdown: markdownWithImages
        )

        return .init(type: .markdown, markdown: document)
    }

    private func markdownStreamMessage(
        streamID: UUID,
        sessionID: UUID,
        fileURL: URL,
        isActive: Bool,
        revision: Int,
        updateKind: TerminalRemoteProtocol.MarkdownStreamUpdateKind,
        status: TerminalRemoteProtocol.MarkdownStreamStatus
    ) throws -> TerminalRemoteProtocol.ServerMessage {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize, fileSize > maxMarkdownStreamBytes {
            throw FileAccessError.markdownTooLarge
        }

        let markdown = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        let markdownWithImages = markdownByEmbeddingLocalImages(
            in: markdown,
            baseURL: fileURL.deletingLastPathComponent()
        )
        if markdownWithImages.utf8.count > maxMarkdownStreamBytes {
            throw FileAccessError.markdownTooLarge
        }
        let document = TerminalRemoteProtocol.MarkdownStreamDocument(
            streamID: streamID,
            sessionID: sessionID,
            path: fileURL.path,
            name: fileURL.lastPathComponent,
            markdown: markdownWithImages,
            isActive: isActive,
            revision: revision,
            updateKind: updateKind,
            status: status
        )

        return .init(type: .markdownStream, markdownStream: document)
    }

    private func makeMarkdownStreamFileURL(streamID: UUID, sessionID: UUID, resumePath: String? = nil) throws -> URL {
        if let resumeURL = markdownStreamResumeFileURL(streamID: streamID, path: resumePath) {
            try FileManager.default.createDirectory(
                at: resumeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return resumeURL
        }

        let candidateURLs = markdownStreamDirectoryCandidateURLs(sessionID: sessionID)
        var lastError: Error?

        for directoryURL in candidateURLs {
            do {
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true
                )
                return directoryURL.appendingPathComponent("stream-\(streamID.uuidString).md")
            } catch {
                lastError = error
            }
        }

        throw lastError ?? FileAccessError.notDirectory
    }

    private func markdownStreamResumeFileURL(streamID: UUID, path: String?) -> URL? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }

        let expectedFileName = "stream-\(streamID.uuidString).md"
        let requestedURL = URL(fileURLWithPath: path).standardizedFileURL
        guard requestedURL.lastPathComponent == expectedFileName else {
            return nil
        }

        let requestedPath = requestedURL.path
        let isProjectStreamPath = requestedPath.contains("/.codeeditv2/markdown-streams/")
        let isApplicationSupportStreamPath: Bool
        if let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            let streamRootPath = applicationSupportURL
                .appendingPathComponent("CodeEditV2", isDirectory: true)
                .appendingPathComponent("RemoteMarkdownStreams", isDirectory: true)
                .standardizedFileURL
                .path
            isApplicationSupportStreamPath = requestedPath.hasPrefix(streamRootPath + "/")
        } else {
            isApplicationSupportStreamPath = false
        }

        guard isProjectStreamPath || isApplicationSupportStreamPath else {
            return nil
        }

        let fileManager = FileManager.default
        let homeURL = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedURL: URL

        if fileManager.fileExists(atPath: requestedURL.path) {
            resolvedURL = requestedURL.resolvingSymlinksInPath()
        } else {
            let resolvedParentURL = requestedURL
                .deletingLastPathComponent()
                .resolvingSymlinksInPath()
            resolvedURL = resolvedParentURL.appendingPathComponent(expectedFileName)
        }

        let homePath = homeURL.path
        let resolvedPath = resolvedURL.standardizedFileURL.path
        guard resolvedPath == homePath || resolvedPath.hasPrefix(homePath + "/") else {
            return nil
        }

        return resolvedURL
    }

    private func markdownStreamDirectoryCandidateURLs(sessionID: UUID) -> [URL] {
        var urls: [URL] = []

        if let currentDirectoryURL = currentDirectoryURL(for: sessionID) {
            urls.append(
                currentDirectoryURL
                    .appendingPathComponent(".codeeditv2", isDirectory: true)
                    .appendingPathComponent("markdown-streams", isDirectory: true)
            )
        }

        urls.append(
            defaultBrowseRootURL()
                .appendingPathComponent(".codeeditv2", isDirectory: true)
                .appendingPathComponent("markdown-streams", isDirectory: true)
        )

        if let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            urls.append(
                applicationSupportURL
                    .appendingPathComponent("CodeEditV2", isDirectory: true)
                    .appendingPathComponent("RemoteMarkdownStreams", isDirectory: true)
            )
        }

        return urls
    }

    private func currentDirectoryURL(for sessionID: UUID) -> URL? {
        if Thread.isMainThread {
            return TerminalSessionManager.shared.ensureSession(sessionID)?.currentDirectory
        }

        return DispatchQueue.main.sync {
            TerminalSessionManager.shared.ensureSession(sessionID)?.currentDirectory
        }
    }

    private func resolvedReadableURL(_ path: String?) throws -> URL {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath()
        let url: URL

        if let path, !path.isEmpty {
            url = URL(fileURLWithPath: path)
        } else {
            url = defaultBrowseRootURL()
        }

        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let homePath = homeURL.path
        let resolvedPath = resolvedURL.path

        guard resolvedPath == homePath || resolvedPath.hasPrefix(homePath + "/") else {
            throw FileAccessError.outsideHome
        }

        return resolvedURL
    }

    private func defaultBrowseRootURL() -> URL {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let candidateURLs = [
            homeURL.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Projects"),
            homeURL.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        ]

        for candidateURL in candidateURLs {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidateURL.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidateURL
            }
        }

        return homeURL
    }

    private func markdownByEmbeddingLocalImages(in markdown: String, baseURL: URL) -> String {
        var renderedMarkdown = replacingMarkdownImageReferences(in: markdown, baseURL: baseURL)
        renderedMarkdown = replacingHTMLImageReferences(in: renderedMarkdown, baseURL: baseURL)
        return renderedMarkdown
    }

    private func replacingMarkdownImageReferences(in markdown: String, baseURL: URL) -> String {
        let pattern = #"!\[([^\]]*)\]\(([^)]+)\)"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return markdown
        }

        return replacingMatches(in: markdown, regex: regex) { match, source in
            guard match.numberOfRanges == 3,
                  let matchRange = Range(match.range, in: source),
                  let targetRange = Range(match.range(at: 2), in: source) else {
                return nil
            }

            let target = String(source[targetRange])
            guard let dataURL = imageDataURL(for: target, baseURL: baseURL) else {
                return nil
            }

            return String(source[matchRange.lowerBound..<targetRange.lowerBound])
                + dataURL
                + String(source[targetRange.upperBound..<matchRange.upperBound])
        }
    }

    private func replacingHTMLImageReferences(in markdown: String, baseURL: URL) -> String {
        let pattern = #"(<img\b[^>]*\bsrc=["'])([^"']+)(["'][^>]*>)"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return markdown
        }

        return replacingMatches(in: markdown, regex: regex) { match, source in
            guard match.numberOfRanges == 4,
                  let matchRange = Range(match.range, in: source),
                  let targetRange = Range(match.range(at: 2), in: source) else {
                return nil
            }

            let target = String(source[targetRange])
            guard let dataURL = imageDataURL(for: target, baseURL: baseURL) else {
                return nil
            }

            return String(source[matchRange.lowerBound..<targetRange.lowerBound])
                + dataURL
                + String(source[targetRange.upperBound..<matchRange.upperBound])
        }
    }

    private func replacingMatches(
        in source: String,
        regex: NSRegularExpression,
        replacement: (NSTextCheckingResult, String) -> String?
    ) -> String {
        let matches = regex.matches(
            in: source,
            range: NSRange(source.startIndex..<source.endIndex, in: source)
        )

        var result = source
        for match in matches.reversed() {
            guard let matchRange = Range(match.range, in: result),
                  let replacementValue = replacement(match, result) else {
                continue
            }

            result.replaceSubrange(matchRange, with: replacementValue)
        }

        return result
    }

    private func imageDataURL(for imageReference: String, baseURL: URL) -> String? {
        let trimmedReference = imageReference
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let lowercasedReference = trimmedReference.lowercased()

        guard !lowercasedReference.hasPrefix("http://"),
              !lowercasedReference.hasPrefix("https://"),
              !lowercasedReference.hasPrefix("data:"),
              !lowercasedReference.hasPrefix("#") else {
            return nil
        }

        let decodedReference = trimmedReference.removingPercentEncoding ?? trimmedReference
        let imageURL: URL

        if decodedReference.hasPrefix("/") {
            imageURL = URL(fileURLWithPath: decodedReference)
        } else {
            imageURL = baseURL.appendingPathComponent(decodedReference)
        }

        guard let readableURL = try? resolvedReadableURL(imageURL.path),
              Self.isEmbeddableImageFile(readableURL),
              let values = try? readableURL.resourceValues(forKeys: [.fileSizeKey]),
              (values.fileSize ?? 0) <= maxEmbeddedImageBytes,
              let data = try? Data(contentsOf: readableURL) else {
            return nil
        }

        return "data:\(Self.mimeType(for: readableURL));base64,\(data.base64EncodedString())"
    }

    private static func isMarkdownFile(_ url: URL) -> Bool {
        ["md", "markdown"].contains(url.pathExtension.lowercased())
    }

    private static func isEmbeddableImageFile(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "svg", "heic"].contains(url.pathExtension.lowercased())
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "svg":
            return "image/svg+xml"
        case "heic":
            return "image/heic"
        default:
            return "image/png"
        }
    }

    private static func makeNumericPasscode() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let value = bytes.reduce(UInt32(0)) { partialResult, byte in
            (partialResult << 8) | UInt32(byte)
        }
        return String(format: "%06d", value % 1_000_000)
    }

    private static func localIPAddresses() -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
            return []
        }

        defer {
            freeifaddrs(interfaces)
        }

        var addresses: [String] = []
        var currentInterface: UnsafeMutablePointer<ifaddrs>? = firstInterface

        while let interface = currentInterface?.pointee {
            defer {
                currentInterface = interface.ifa_next
            }

            let flags = Int32(interface.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK
            guard isUp, !isLoopback, let address = interface.ifa_addr else {
                continue
            }

            guard address.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            if result == 0 {
                let ipAddress = String(cString: host)
                if !ipAddress.hasPrefix("169.254.") {
                    addresses.append(ipAddress)
                }
            }
        }

        return Array(Set(addresses)).sorted()
    }

    private static func normalizedPublicIPAddress(from text: String) -> String? {
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPublicIPv4Address(address) else {
            return nil
        }

        return address
    }

    private static func isPublicIPv4Address(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }

        if octets[0] == 0 || octets[0] == 10 || octets[0] == 127 {
            return false
        }

        if octets[0] == 100 && (64...127).contains(octets[1]) {
            return false
        }

        if octets[0] == 169 && octets[1] == 254 {
            return false
        }

        if octets[0] == 172 && (16...31).contains(octets[1]) {
            return false
        }

        if octets[0] == 192 && octets[1] == 168 {
            return false
        }

        return octets[0] < 224
    }

    private enum FileAccessError: LocalizedError {
        case outsideHome
        case notDirectory
        case notMarkdown
        case markdownTooLarge

        var errorDescription: String? {
            switch self {
            case .outsideHome:
                return "Remote file access is limited to the Mac user home folder."
            case .notDirectory:
                return "The requested path is not a folder."
            case .notMarkdown:
                return "The requested path is not a Markdown file."
            case .markdownTooLarge:
                return "The Markdown file is too large to open remotely."
            }
        }
    }
}

private extension TerminalRemoteBridge {
    final class Client {
        let id = UUID()
        var isAuthenticated = false

        private let connection: NWConnection
        private weak var bridge: TerminalRemoteBridge?
        private var receiveBuffer = Data()
        private var outputSubscriptions: [UUID: UUID] = [:]
        private var inputSubscriptions: [UUID: UUID] = [:]
        private var markdownStreams: [UUID: MarkdownStreamWatcher] = [:]

        init(connection: NWConnection, bridge: TerminalRemoteBridge) {
            self.connection = connection
            self.bridge = bridge
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else {
                    return
                }

                switch state {
                case .ready:
                    if let message = self.bridge?.helloMessage() {
                        self.send(message)
                    }
                    self.bridge?.refreshPublicIPAddressIfNeeded { [weak self] address in
                        guard address != nil, let message = self?.bridge?.helloMessage() else {
                            return
                        }

                        self?.send(message)
                    }
                    self.receiveNext()
                case .failed, .cancelled:
                    self.bridge?.removeClient(self.id)
                default:
                    break
                }
            }
            connection.start(queue: bridge?.queue ?? .main)
        }

        func cancel() {
            let sessionIDs = Set(outputSubscriptions.keys).union(inputSubscriptions.keys)
            for sessionID in sessionIDs {
                detach(from: sessionID)
            }
            markdownStreams.values.forEach { $0.cancel(sendFinalSnapshot: false) }
            markdownStreams.removeAll()
            connection.cancel()
        }

        func send(_ message: TerminalRemoteProtocol.ServerMessage) {
            guard let bridge else {
                return
            }

            do {
                var data = try bridge.encoder.encode(message)
                data.append(0x0a)
                connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    if error != nil {
                        self?.bridge?.removeClient(self?.id ?? UUID())
                    }
                })
            } catch {
                bridge.logger.error("Failed to encode terminal remote message: \(error.localizedDescription)")
            }
        }

        func sendError(_ message: String) {
            send(.init(type: .error, message: message))
        }

        func sendSessions() {
            DispatchQueue.main.async { [weak self] in
                let sessions = TerminalSessionManager.shared.sessionDescriptors().map(TerminalRemoteProtocol.Session.init)
                self?.send(.init(type: .sessions, sessions: sessions))
            }
        }

        func sendFileList(path: String?) {
            do {
                let message = try bridge?.fileListMessage(path: path)
                if let message {
                    send(message)
                }
            } catch {
                sendError(error.localizedDescription)
            }
        }

        func sendMarkdown(path: String?) {
            do {
                let message = try bridge?.markdownMessage(path: path)
                if let message {
                    send(message)
                }
            } catch {
                sendError(error.localizedDescription)
            }
        }

        func startMarkdownStream(sessionID: UUID, prompt: String, streamID: UUID, resumePath: String?) {
            guard let bridge else {
                return
            }

            do {
                let fileURL = try bridge.makeMarkdownStreamFileURL(
                    streamID: streamID,
                    sessionID: sessionID,
                    resumePath: resumePath
                )
                let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
                if !fileExists {
                    let initialMarkdown = markdownStreamPreamble(prompt: prompt, streamFileURL: fileURL)
                    try initialMarkdown.write(to: fileURL, atomically: true, encoding: .utf8)
                }

                if let existingWatcher = markdownStreams[streamID] {
                    existingWatcher.publishCurrentSnapshot()
                    return
                }

                let watcher = MarkdownStreamWatcher(
                    streamID: streamID,
                    sessionID: sessionID,
                    fileURL: fileURL,
                    initialPrompt: prompt,
                    client: self
                )
                markdownStreams[streamID] = watcher
                watcher.start()
                watcher.publishCurrentSnapshot()
            } catch {
                sendError(error.localizedDescription)
            }
        }

        func stopMarkdownStream(streamID: UUID?) {
            if let streamID {
                markdownStreams.removeValue(forKey: streamID)?.cancel(sendFinalSnapshot: true)
                return
            }

            markdownStreams.values.forEach { $0.cancel(sendFinalSnapshot: true) }
            markdownStreams.removeAll()
        }

        func triggerMarkdownStreamUpdate(streamID: UUID?) {
            if let streamID {
                markdownStreams[streamID]?.triggerUpdate()
                return
            }

            markdownStreams.values.forEach { $0.triggerUpdate() }
        }

        func rewriteMarkdownStream(streamID: UUID?, prompt: String) {
            if let streamID {
                markdownStreams[streamID]?.rewriteDocument(prompt: prompt)
                return
            }

            markdownStreams.values.forEach { $0.rewriteDocument(prompt: prompt) }
        }

        func sendMarkdownStreamSnapshot(
            streamID: UUID,
            sessionID: UUID,
            fileURL: URL,
            isActive: Bool,
            revision: Int,
            updateKind: TerminalRemoteProtocol.MarkdownStreamUpdateKind,
            status: TerminalRemoteProtocol.MarkdownStreamStatus
        ) {
            do {
                let message = try bridge?.markdownStreamMessage(
                    streamID: streamID,
                    sessionID: sessionID,
                    fileURL: fileURL,
                    isActive: isActive,
                    revision: revision,
                    updateKind: updateKind,
                    status: status
                )
                if let message {
                    send(message)
                }
            } catch {
                sendError(error.localizedDescription)
            }
        }

        func requireAuthentication() -> Bool {
            guard isAuthenticated else {
                sendError("Authenticate before using terminal sessions.")
                return false
            }
            return true
        }

        func attach(to sessionID: UUID, includeRecent: Bool) {
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }

                guard let session = TerminalSessionManager.shared.ensureSession(sessionID) else {
                    self.sendError("Terminal session not found.")
                    return
                }

                if self.outputSubscriptions[sessionID] == nil {
                    self.outputSubscriptions[sessionID] = session.subscribeToProjectedOutput { [weak self] projection in
                        guard projection.hasMeaningfulText else {
                            return
                        }

                        self?.send(
                            .init(
                                type: .output,
                                sessionID: sessionID,
                                projectedOutput: Self.remoteProjectedOutput(from: projection)
                            )
                        )
                    }
                }

                if self.inputSubscriptions[sessionID] == nil {
                    self.inputSubscriptions[sessionID] = session.subscribeToInput { [weak self] bytes in
                        self?.send(.init(type: .input, sessionID: sessionID, data: Data(bytes)))
                    }
                }

                if includeRecent,
                   let output = TerminalSessionManager.shared.recentProjectedOutput(for: sessionID) {
                    self.send(
                            .init(
                                type: .output,
                                sessionID: sessionID,
                                projectedOutput: Self.remoteProjectedOutput(from: output)
                            )
                    )
                }

                self.sendSessions()
            }
        }

        private static func remoteProjectedOutput(
            from output: TerminalProjectedOutput
        ) -> TerminalRemoteProtocol.ProjectedOutput {
            TerminalRemoteProtocol.ProjectedOutput(
                sequence: output.sequence,
                screenMode: output.screenMode,
                columns: output.columns,
                terminalRows: output.terminalRows,
                rows: output.rows.map { row in
                    TerminalRemoteProtocol.ProjectedRow(
                        row: row.row,
                        text: row.text,
                        spans: remoteSpans(from: row.spans)
                    )
                }
            )
        }

        /// Maps styled spans to the wire type, returning `nil` when the whole row uses default
        /// colors and no styling so plain terminal output stays as compact as before.
        private static func remoteSpans(
            from spans: [TerminalProjectedSpan]
        ) -> [TerminalRemoteProtocol.ProjectedSpan]? {
            let hasStyling = spans.contains { span in
                span.foreground != nil || span.background != nil || span.style != 0
            }
            guard hasStyling else {
                return nil
            }

            return spans.map { span in
                TerminalRemoteProtocol.ProjectedSpan(
                    text: span.text,
                    foreground: span.foreground,
                    background: span.background,
                    style: span.style == 0 ? nil : span.style
                )
            }
        }

        func detach(from sessionID: UUID) {
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }

                let outputToken = self.outputSubscriptions.removeValue(forKey: sessionID)
                let inputToken = self.inputSubscriptions.removeValue(forKey: sessionID)
                let session = TerminalSessionManager.shared.getSession(sessionID)

                if let outputToken {
                    session?.unsubscribe(outputToken)
                }

                if let inputToken {
                    session?.unsubscribe(inputToken)
                }
            }
        }

        private func receiveNext() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else {
                    return
                }

                if let data, !data.isEmpty {
                    self.receiveBuffer.append(data)
                    self.processReceiveBuffer()
                }

                if isComplete || error != nil {
                    self.bridge?.removeClient(self.id)
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
                    let message = try bridge?.decoder.decode(TerminalRemoteProtocol.ClientMessage.self, from: Data(frame))
                    if let message {
                        bridge?.handle(message, from: self)
                    }
                } catch {
                    sendError("Invalid terminal remote message.")
                }
            }
        }

        private func markdownStreamPreamble(prompt: String, streamFileURL: URL) -> String {
            """
            # Markdown Stream Agent

            **Stream file:** `\(streamFileURL.path)`
            **Instruction:** \(prompt)

            ---

            The stream buffers selected terminal output. CodeEditV2 starts a short-lived Claude job when
            you press Update in the iOS MD Stream tab and writes the returned Markdown here.

            After this stream is started, send prompts or commands in the Terminal tab. Press Update when
            the terminal output you want to capture has appeared.

            """
        }

        private final class MarkdownStreamWatcher {
            private struct ClaudeUpdateFiles {
                let promptURL: URL
                let stdoutURL: URL
                let stderrURL: URL

                var cleanupURLs: [URL] {
                    [promptURL, stdoutURL, stderrURL]
                }
            }

            private struct ClaudeUpdateHandles {
                let stdin: FileHandle
                let stdout: FileHandle
                let stderr: FileHandle

                func close() {
                    try? stdin.close()
                    try? stdout.close()
                    try? stderr.close()
                }
            }

            private weak var client: Client?
            private let streamID: UUID
            private let sessionID: UUID
            private let fileURL: URL
            private let initialPrompt: String
            private var timer: DispatchSourceTimer?
            private var lastSignature = ""
            private var revision = 0
            private var streamStatus = TerminalRemoteProtocol.MarkdownStreamStatus(
                phase: .starting,
                title: "Starting Markdown stream"
            )
            private var outputSubscriptionToken: UUID?
            private var rawOutputSubscriptionToken: UUID?
            private var inputSubscriptionToken: UUID?
            private var terminalInputBuffer = ""
            private var currentTerminalPrompt: String?
            private var terminalRawCapture = Data()
            private var hasMeaningfulRawCapture = false
            private var shellIntegrationBuffer = ""
            private var pendingShellCommandFinished = false
            private var rawCaptureWasTruncated = false
            private var projectedCaptureWasTruncated = false
            private var terminalOutputRows: [Int: String] = [:]
            private var terminalOutputRowOrder: [Int] = []
            private var terminalOutputCharacterCount = 0
            private var isClaudeRunning = false
            private var needsFollowUpRun = false
            private var claudeProcess: Process?
            private var isCancelled = false
            private var autoUpdateWorkItem: DispatchWorkItem?

            private let maxTerminalDeltaBytes = 1_000_000
            private let maxTerminalDeltaCharacters = 240_000
            private let maxTerminalPromptCharacters = 4_000
            private let maxStatusDetailCharacters = 4_000
            /// Idle window after the last terminal output chunk before the Markdown update runs on its own.
            private let autoUpdateIdleDelay: DispatchTimeInterval = .milliseconds(2_000)
            private let commandFinishedUpdateDelay: DispatchTimeInterval = .milliseconds(300)

            init(
                streamID: UUID,
                sessionID: UUID,
                fileURL: URL,
                initialPrompt: String,
                client: Client
            ) {
                self.streamID = streamID
                self.sessionID = sessionID
                self.fileURL = fileURL
                self.initialPrompt = initialPrompt
                self.client = client
            }

            func start() {
                startSnapshotTimer()
                subscribeToTerminalEvents()
            }

            func publishCurrentSnapshot() {
                publishIfChanged(isActive: true, force: true, updateKind: .snapshot)
            }

            func triggerUpdate() {
                guard !isCancelled else {
                    return
                }

                if currentTerminalPrompt == nil {
                    guard captureRecentTerminalProjectionForManualUpdate() else {
                        setStatus(
                            .watching,
                            title: "No pending Markdown update",
                            detail: "Run a terminal command first, then press Update after its output appears."
                        )
                        return
                    }
                }

                startClaudeUpdateIfPossible()
            }

            func rewriteDocument(prompt: String) {
                guard !isCancelled else {
                    return
                }

                let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedPrompt.isEmpty else {
                    setStatus(
                        .error,
                        title: "No rewrite prompt",
                        detail: "Enter rewrite instructions before asking Claude to rewrite the Markdown file."
                    )
                    return
                }

                guard !isClaudeRunning else {
                    setStatus(
                        .queued,
                        title: "Claude busy",
                        detail: "Wait for the current Claude Markdown job to finish, then try the rewrite again."
                    )
                    return
                }

                let currentMarkdown = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
                isClaudeRunning = true
                setStatus(.rewriting, title: "Rewriting Markdown")
                runClaudeRewrite(userPrompt: trimmedPrompt, currentMarkdown: currentMarkdown)
            }

            func cancel(sendFinalSnapshot: Bool) {
                isCancelled = true
                timer?.cancel()
                timer = nil
                cancelAutomaticUpdate()
                claudeProcess?.terminate()
                claudeProcess = nil

                if let outputSubscriptionToken {
                    DispatchQueue.main.async {
                        TerminalSessionManager.shared.getSession(self.sessionID)?.unsubscribe(outputSubscriptionToken)
                    }
                }
                outputSubscriptionToken = nil

                if let rawOutputSubscriptionToken {
                    DispatchQueue.main.async {
                        TerminalSessionManager.shared.getSession(self.sessionID)?.unsubscribe(rawOutputSubscriptionToken)
                    }
                }
                rawOutputSubscriptionToken = nil

                if let inputSubscriptionToken {
                    DispatchQueue.main.async {
                        TerminalSessionManager.shared.getSession(self.sessionID)?.unsubscribe(inputSubscriptionToken)
                    }
                }
                inputSubscriptionToken = nil

                if sendFinalSnapshot {
                    setStatus(.stopped, title: "Markdown stream stopped", publishActive: false, force: true)
                }
            }

            private func startSnapshotTimer() {
                guard let queue = client?.bridge?.queue else {
                    return
                }

                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(750), leeway: .milliseconds(150))
                timer.setEventHandler { [weak self] in
                    self?.publishIfChanged(isActive: true)
                }
                timer.resume()
                self.timer = timer
            }

            private func subscribeToTerminalEvents() {
                DispatchQueue.main.async { [weak self] in
                    guard let self else {
                        return
                    }

                    guard let session = TerminalSessionManager.shared.ensureSession(self.sessionID) else {
                        self.client?.bridge?.queue.async { [weak self] in
                            self?.setStatus(
                                .error,
                                title: "Terminal session not found",
                                detail: "CodeEditV2 could not attach the Markdown stream watcher to the selected terminal."
                            )
                        }
                        return
                    }

                    let token = session.subscribeToProjectedOutput { [weak self] projection in
                        self?.client?.bridge?.queue.async { [weak self] in
                            self?.appendTerminalOutput(projection)
                        }
                    }
                    let rawToken = session.subscribeToRawOutput { [weak self] bytes, screenMode in
                        let data = Data(bytes)
                        self?.client?.bridge?.queue.async { [weak self] in
                            self?.appendRawOutput(data, screenMode: screenMode)
                        }
                    }
                    let inputToken = session.subscribeToInput { [weak self] bytes in
                        let data = Data(bytes)
                        self?.client?.bridge?.queue.async { [weak self] in
                            self?.recordTerminalInput(data)
                        }
                    }

                    self.client?.bridge?.queue.async { [weak self] in
                        guard let self else {
                            return
                        }

                        guard !self.isCancelled else {
                            DispatchQueue.main.async {
                                session.unsubscribe(token)
                                session.unsubscribe(rawToken)
                                session.unsubscribe(inputToken)
                            }
                            return
                        }

                        self.outputSubscriptionToken = token
                        self.rawOutputSubscriptionToken = rawToken
                        self.inputSubscriptionToken = inputToken
                        self.setStatus(.watching, title: "Watching terminal input")
                    }
                }
            }

            private func recordTerminalInput(_ data: Data) {
                guard !isCancelled else {
                    return
                }

                let text = Self.plainTerminalText(from: data)
                guard !text.isEmpty else {
                    return
                }

                terminalInputBuffer += text
                terminalInputBuffer = Self.cappedSuffix(
                    terminalInputBuffer,
                    limit: maxTerminalPromptCharacters
                )
                armIfInputContainsSubmission()
            }

            private func armIfInputContainsSubmission() {
                guard terminalInputBuffer.contains("\n") else {
                    return
                }

                let submittedLines = terminalInputBuffer
                    .components(separatedBy: .newlines)
                    .dropLast()
                let prompt = submittedLines
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .last { !$0.isEmpty }

                terminalInputBuffer = terminalInputBuffer.hasSuffix("\n")
                    ? ""
                    : terminalInputBuffer.components(separatedBy: .newlines).last ?? ""

                guard let prompt else {
                    return
                }

                armForTerminalPrompt(prompt)
            }

            private func armForTerminalPrompt(_ prompt: String) {
                currentTerminalPrompt = Self.cappedSuffix(prompt, limit: maxTerminalPromptCharacters)
                terminalRawCapture.removeAll(keepingCapacity: true)
                hasMeaningfulRawCapture = false
                rawCaptureWasTruncated = false
                projectedCaptureWasTruncated = false
                pendingShellCommandFinished = false
                terminalOutputRows.removeAll(keepingCapacity: true)
                terminalOutputRowOrder.removeAll(keepingCapacity: true)
                terminalOutputCharacterCount = 0
                needsFollowUpRun = false
                cancelAutomaticUpdate()
                setStatus(.capturing, title: "Waiting for command output")
            }

            private func appendRawOutput(
                _ data: Data,
                screenMode: TerminalRemoteProtocol.ScreenMode
            ) {
                guard !isCancelled, !data.isEmpty else {
                    return
                }

                processShellIntegrationEvents(in: Self.decodedTerminalText(from: data))

                guard currentTerminalPrompt != nil else {
                    pendingShellCommandFinished = false
                    return
                }

                guard screenMode == .main else {
                    finishPendingShellCommandIfNeeded()
                    return
                }

                terminalRawCapture.append(data)
                if terminalRawCapture.count > maxTerminalDeltaBytes {
                    terminalRawCapture.removeFirst(terminalRawCapture.count - maxTerminalDeltaBytes)
                    rawCaptureWasTruncated = true
                }

                if !hasMeaningfulRawCapture,
                   Self.hasMeaningfulTerminalText(in: Self.plainTerminalText(from: data)) {
                    hasMeaningfulRawCapture = true
                    setStatus(.capturing, title: "Capturing terminal output", isTruncated: captureWasTruncated())
                }
                scheduleAutomaticUpdate()
                finishPendingShellCommandIfNeeded()
            }

            private func appendTerminalOutput(_ projection: TerminalProjectedOutput) {
                guard !isCancelled, currentTerminalPrompt != nil else {
                    return
                }

                let wasEmpty = terminalOutputCharacterCount == 0
                for row in projection.rows {
                    if terminalOutputRows[row.row] == nil {
                        terminalOutputRowOrder.append(row.row)
                    }
                    terminalOutputCharacterCount -= terminalOutputRows[row.row]?.count ?? 0
                    terminalOutputCharacterCount += row.text.count
                    terminalOutputRows[row.row] = row.text
                }
                trimTerminalOutputRowsIfNeeded()
                if wasEmpty, terminalOutputCharacterCount > 0 {
                    setStatus(.capturing, title: "Capturing terminal output", isTruncated: captureWasTruncated())
                }
                scheduleAutomaticUpdate()
            }

            private func captureRecentTerminalProjectionForManualUpdate() -> Bool {
                guard let output = recentTerminalProjection(), output.hasMeaningfulText else {
                    return false
                }

                armForTerminalPrompt("Visible terminal output")
                appendTerminalOutput(output)
                return terminalOutputCharacterCount > 0
            }

            private func recentTerminalProjection() -> TerminalProjectedOutput? {
                if Thread.isMainThread {
                    return TerminalSessionManager.shared.getSession(sessionID)?.recentProjectedOutputSnapshot()
                }

                return DispatchQueue.main.sync {
                    TerminalSessionManager.shared.getSession(sessionID)?.recentProjectedOutputSnapshot()
                }
            }

            private func terminalOutputText() -> String {
                terminalOutputRowOrder
                    .compactMap { terminalOutputRows[$0] }
                    .joined(separator: "\n")
            }

            private func trimTerminalOutputRowsIfNeeded() {
                while terminalOutputCharacterCount > maxTerminalDeltaCharacters,
                      let firstRow = terminalOutputRowOrder.first {
                    terminalOutputCharacterCount -= terminalOutputRows.removeValue(forKey: firstRow)?.count ?? 0
                    terminalOutputRowOrder.removeFirst()
                    projectedCaptureWasTruncated = true
                }
            }

            private func currentTerminalDelta() -> String {
                let rawText = Self.plainTerminalText(from: terminalRawCapture)
                if Self.hasMeaningfulTerminalText(in: rawText) {
                    return rawText
                }

                return terminalOutputText()
            }

            private func captureWasTruncated(delta: String? = nil) -> Bool {
                rawCaptureWasTruncated
                    || projectedCaptureWasTruncated
                    || terminalRawCapture.count >= maxTerminalDeltaBytes
                    || terminalOutputCharacterCount >= maxTerminalDeltaCharacters
                    || (delta?.count ?? 0) >= maxTerminalDeltaCharacters
            }

            private func processShellIntegrationEvents(in text: String) {
                guard !text.isEmpty else {
                    return
                }

                shellIntegrationBuffer += text
                parseShellIntegrationBuffer()
                if shellIntegrationBuffer.count > 8_000 {
                    shellIntegrationBuffer = String(shellIntegrationBuffer.suffix(4_000))
                }
            }

            private func parseShellIntegrationBuffer() {
                let prefix = "\u{001B}]133;"

                while let prefixRange = shellIntegrationBuffer.range(of: prefix) {
                    if prefixRange.lowerBound > shellIntegrationBuffer.startIndex {
                        shellIntegrationBuffer.removeSubrange(shellIntegrationBuffer.startIndex..<prefixRange.lowerBound)
                    }

                    let payloadStart = prefixRange.upperBound
                    guard let terminatorRange = Self.firstOSCTerminatorRange(
                        in: shellIntegrationBuffer,
                        from: payloadStart
                    ) else {
                        return
                    }

                    let payload = String(shellIntegrationBuffer[payloadStart..<terminatorRange.lowerBound])
                    handleShellIntegrationPayload(payload)
                    shellIntegrationBuffer.removeSubrange(shellIntegrationBuffer.startIndex..<terminatorRange.upperBound)
                }

                shellIntegrationBuffer = ""
            }

            private func handleShellIntegrationPayload(_ payload: String) {
                if payload == "C" || payload.hasPrefix("C;") {
                    handleShellCommandStarted()
                } else if payload == "D" || payload.hasPrefix("D;") {
                    pendingShellCommandFinished = true
                }
            }

            private func handleShellCommandStarted() {
                let bufferedPrompt = terminalInputBuffer
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let prompt = currentTerminalPrompt ?? (bufferedPrompt.isEmpty ? "Terminal command" : bufferedPrompt)
                armForTerminalPrompt(prompt)
            }

            private func handleShellCommandFinished() {
                guard currentTerminalPrompt != nil else {
                    return
                }

                guard hasMeaningfulRawCapture || terminalOutputCharacterCount > 0 else {
                    currentTerminalPrompt = nil
                    setStatus(.watching, title: "Watching terminal input")
                    return
                }

                cancelAutomaticUpdate()
                setStatus(.queued, title: "Queued Markdown update", isTruncated: captureWasTruncated())
                guard let queue = client?.bridge?.queue else {
                    return
                }

                let workItem = DispatchWorkItem { [weak self] in
                    guard let self, !self.isCancelled, self.currentTerminalPrompt != nil else {
                        return
                    }
                    self.autoUpdateWorkItem = nil
                    self.startClaudeUpdateIfPossible()
                }
                autoUpdateWorkItem = workItem
                queue.asyncAfter(deadline: .now() + commandFinishedUpdateDelay, execute: workItem)
            }

            private func finishPendingShellCommandIfNeeded() {
                guard pendingShellCommandFinished else {
                    return
                }

                pendingShellCommandFinished = false
                handleShellCommandFinished()
            }

            /// Runs the Markdown update automatically once terminal output for the current command has been
            /// idle for `autoUpdateIdleDelay` — i.e. the command appears to have finished — so terminal
            /// activity is reflected in the stream without a manual press. The manual trigger still works.
            private func scheduleAutomaticUpdate() {
                guard !isCancelled, currentTerminalPrompt != nil, let queue = client?.bridge?.queue else {
                    return
                }

                setStatus(.queued, title: "Queued Markdown update", isTruncated: captureWasTruncated())
                autoUpdateWorkItem?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self else {
                        return
                    }
                    self.autoUpdateWorkItem = nil
                    guard !self.isCancelled, self.currentTerminalPrompt != nil else {
                        return
                    }
                    guard self.hasMeaningfulRawCapture || self.terminalOutputCharacterCount > 0 else {
                        return
                    }
                    self.startClaudeUpdateIfPossible()
                }

                autoUpdateWorkItem = workItem
                queue.asyncAfter(deadline: .now() + autoUpdateIdleDelay, execute: workItem)
            }

            private func cancelAutomaticUpdate() {
                autoUpdateWorkItem?.cancel()
                autoUpdateWorkItem = nil
            }

            private func startClaudeUpdateIfPossible() {
                guard !isCancelled else {
                    return
                }

                guard let terminalPrompt = currentTerminalPrompt else {
                    return
                }

                guard !isClaudeRunning else {
                    needsFollowUpRun = true
                    setStatus(.queued, title: "Queued Markdown update", isTruncated: captureWasTruncated())
                    return
                }

                let terminalDelta = currentTerminalDelta()
                let wasTruncated = captureWasTruncated(delta: terminalDelta)
                cancelAutomaticUpdate()
                terminalRawCapture.removeAll(keepingCapacity: true)
                hasMeaningfulRawCapture = false
                rawCaptureWasTruncated = false
                projectedCaptureWasTruncated = false
                terminalOutputRows.removeAll(keepingCapacity: true)
                terminalOutputRowOrder.removeAll(keepingCapacity: true)
                terminalOutputCharacterCount = 0
                needsFollowUpRun = false
                isClaudeRunning = true
                setStatus(.running, title: "Running Markdown update", isTruncated: wasTruncated)
                runClaudeUpdate(
                    terminalPrompt: terminalPrompt,
                    terminalDelta: terminalDelta
                )
            }

            private func runClaudeUpdate(terminalPrompt: String, terminalDelta: String) {
                guard let bridge = client?.bridge else {
                    handleClaudeLaunchFailure(message: "The remote bridge is no longer available.")
                    return
                }

                let files = makeClaudeUpdateFiles()

                do {
                    let handles = try prepareClaudeUpdateFiles(
                        files,
                        terminalPrompt: terminalPrompt,
                        terminalDelta: terminalDelta
                    )
                    let process = makeClaudeProcess(files: files, handles: handles, bridge: bridge)
                    process.terminationHandler = { [weak self] process in
                        handles.close()
                        guard let self, let queue = self.client?.bridge?.queue else {
                            files.cleanupURLs.forEach { try? FileManager.default.removeItem(at: $0) }
                            return
                        }

                        queue.async {
                            self.finishClaudeUpdate(
                                exitCode: process.terminationStatus,
                                files: files
                            )
                        }
                    }

                    try process.run()
                    claudeProcess = process
                } catch {
                    handleClaudeLaunchFailure(error: error, cleanupURLs: files.cleanupURLs)
                }
            }

            private func runClaudeRewrite(userPrompt: String, currentMarkdown: String) {
                guard let bridge = client?.bridge else {
                    handleClaudeRewriteLaunchFailure(message: "The remote bridge is no longer available.")
                    return
                }

                let files = makeClaudeUpdateFiles()

                do {
                    let handles = try prepareClaudeRewriteFiles(
                        files,
                        userPrompt: userPrompt,
                        currentMarkdown: currentMarkdown
                    )
                    let process = makeClaudeRewriteProcess(files: files, handles: handles, bridge: bridge)
                    process.terminationHandler = { [weak self] process in
                        handles.close()
                        guard let self, let queue = self.client?.bridge?.queue else {
                            files.cleanupURLs.forEach { try? FileManager.default.removeItem(at: $0) }
                            return
                        }

                        queue.async {
                            self.finishClaudeRewrite(
                                exitCode: process.terminationStatus,
                                files: files
                            )
                        }
                    }

                    try process.run()
                    claudeProcess = process
                } catch {
                    handleClaudeRewriteLaunchFailure(error: error, cleanupURLs: files.cleanupURLs)
                }
            }

            private func makeClaudeUpdateFiles() -> ClaudeUpdateFiles {
                ClaudeUpdateFiles(
                    promptURL: temporaryFileURL(suffix: "prompt.txt"),
                    stdoutURL: temporaryFileURL(suffix: "stdout.txt"),
                    stderrURL: temporaryFileURL(suffix: "stderr.txt")
                )
            }

            private func prepareClaudeUpdateFiles(
                _ files: ClaudeUpdateFiles,
                terminalPrompt: String,
                terminalDelta: String
            ) throws -> ClaudeUpdateHandles {
                let prompt = claudePrompt(
                    terminalPrompt: terminalPrompt,
                    terminalDelta: terminalDelta
                )
                try prompt.write(to: files.promptURL, atomically: true, encoding: .utf8)
                FileManager.default.createFile(atPath: files.stdoutURL.path, contents: nil)
                FileManager.default.createFile(atPath: files.stderrURL.path, contents: nil)

                return ClaudeUpdateHandles(
                    stdin: try FileHandle(forReadingFrom: files.promptURL),
                    stdout: try FileHandle(forWritingTo: files.stdoutURL),
                    stderr: try FileHandle(forWritingTo: files.stderrURL)
                )
            }

            private func prepareClaudeRewriteFiles(
                _ files: ClaudeUpdateFiles,
                userPrompt: String,
                currentMarkdown: String
            ) throws -> ClaudeUpdateHandles {
                let prompt = claudeRewritePrompt(
                    userPrompt: userPrompt,
                    currentMarkdown: currentMarkdown
                )
                try prompt.write(to: files.promptURL, atomically: true, encoding: .utf8)
                FileManager.default.createFile(atPath: files.stdoutURL.path, contents: nil)
                FileManager.default.createFile(atPath: files.stderrURL.path, contents: nil)

                return ClaudeUpdateHandles(
                    stdin: try FileHandle(forReadingFrom: files.promptURL),
                    stdout: try FileHandle(forWritingTo: files.stdoutURL),
                    stderr: try FileHandle(forWritingTo: files.stderrURL)
                )
            }

            private func makeClaudeProcess(
                files: ClaudeUpdateFiles,
                handles: ClaudeUpdateHandles,
                bridge: TerminalRemoteBridge
            ) -> Process {
                let process = Process()
                let workspaceURL = bridge.currentDirectoryURL(for: sessionID)
                    ?? fileURL.deletingLastPathComponent()
                let command = Self.claudeLaunchCommand(
                    arguments: claudeExecArguments()
                )

                process.executableURL = command.executableURL
                process.arguments = command.arguments
                process.currentDirectoryURL = workspaceURL
                process.environment = Self.claudeEnvironment()
                process.standardInput = handles.stdin
                process.standardOutput = handles.stdout
                process.standardError = handles.stderr
                return process
            }

            private func makeClaudeRewriteProcess(
                files: ClaudeUpdateFiles,
                handles: ClaudeUpdateHandles,
                bridge: TerminalRemoteBridge
            ) -> Process {
                let process = Process()
                let workspaceURL = bridge.currentDirectoryURL(for: sessionID)
                    ?? fileURL.deletingLastPathComponent()
                let command = Self.claudeLaunchCommand(
                    arguments: claudeRewriteArguments()
                )

                process.executableURL = command.executableURL
                process.arguments = command.arguments
                process.currentDirectoryURL = workspaceURL
                process.environment = Self.claudeEnvironment()
                process.standardInput = handles.stdin
                process.standardOutput = handles.stdout
                process.standardError = handles.stderr
                return process
            }

            private func claudeExecArguments() -> [String] {
                [
                    "-p",
                    "--model",
                    "claude-opus-4-8",
                    "--effort",
                    "medium",
                    "--no-session-persistence",
                    "--output-format",
                    "text",
                    "--permission-mode",
                    "dontAsk",
                    "--disallowedTools",
                    "Bash,Edit,Write,MultiEdit,Read,Glob,Grep,LS"
                ]
            }

            private func claudeRewriteArguments() -> [String] {
                claudeExecArguments()
            }

            private func handleClaudeLaunchFailure(error: Error, cleanupURLs: [URL]) {
                cleanupURLs.forEach { try? FileManager.default.removeItem(at: $0) }
                handleClaudeLaunchFailure(message: error.localizedDescription)
            }

            private func handleClaudeLaunchFailure(message: String) {
                isClaudeRunning = false
                claudeProcess = nil
                setStatus(.error, title: "Claude launch failed", detail: message)
                scheduleFollowUpIfNeeded()
            }

            private func handleClaudeRewriteLaunchFailure(error: Error, cleanupURLs: [URL]) {
                cleanupURLs.forEach { try? FileManager.default.removeItem(at: $0) }
                handleClaudeRewriteLaunchFailure(message: error.localizedDescription)
            }

            private func handleClaudeRewriteLaunchFailure(message: String) {
                isClaudeRunning = false
                claudeProcess = nil
                setStatus(.error, title: "Claude rewrite launch failed", detail: message)
            }

            private func finishClaudeUpdate(
                exitCode: Int32,
                files: ClaudeUpdateFiles
            ) {
                defer {
                    files.cleanupURLs.forEach { try? FileManager.default.removeItem(at: $0) }
                    isClaudeRunning = false
                    claudeProcess = nil
                    scheduleFollowUpIfNeeded()
                }

                guard !isCancelled else {
                    return
                }

                let output = (try? String(contentsOf: files.stdoutURL, encoding: .utf8)) ?? ""
                if exitCode == 0 {
                    let markdown = Self.normalizedMarkdownOutput(output)
                    guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        setStatus(
                            .watching,
                            title: "No Markdown appended",
                            detail: "Claude finished but did not return a non-empty append entry."
                        )
                        return
                    }
                    do {
                        try appendMarkdownEntry(markdown)
                        setStatus(.watching, title: "Watching terminal input", publish: false)
                        publishIfChanged(isActive: true, force: true, updateKind: .append)
                    } catch {
                        setStatus(.error, title: "Markdown write failed", detail: error.localizedDescription)
                    }
                    return
                }

                let stdout = (try? String(contentsOf: files.stdoutURL, encoding: .utf8)) ?? ""
                let stderr = (try? String(contentsOf: files.stderrURL, encoding: .utf8)) ?? ""
                let detail = Self.claudeFailureDetail(exitCode: exitCode, stdout: stdout, stderr: stderr)
                setStatus(.error, title: "Claude update failed", detail: detail)
            }

            private func finishClaudeRewrite(
                exitCode: Int32,
                files: ClaudeUpdateFiles
            ) {
                defer {
                    files.cleanupURLs.forEach { try? FileManager.default.removeItem(at: $0) }
                    isClaudeRunning = false
                    claudeProcess = nil
                }

                guard !isCancelled else {
                    return
                }

                let output = (try? String(contentsOf: files.stdoutURL, encoding: .utf8)) ?? ""
                if exitCode == 0 {
                    let markdown = Self.normalizedMarkdownOutput(output)
                    guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        setStatus(
                            .watching,
                            title: "No Markdown replacement",
                            detail: "Claude finished but did not return a non-empty Markdown file."
                        )
                        return
                    }
                    do {
                        try replaceMarkdownDocument(markdown)
                        setStatus(.watching, title: "Watching terminal input", publish: false)
                        publishIfChanged(isActive: true, force: true, updateKind: .replace)
                    } catch {
                        setStatus(.error, title: "Markdown rewrite failed", detail: error.localizedDescription)
                    }
                    return
                }

                let stdout = (try? String(contentsOf: files.stdoutURL, encoding: .utf8)) ?? ""
                let stderr = (try? String(contentsOf: files.stderrURL, encoding: .utf8)) ?? ""
                let detail = Self.claudeFailureDetail(exitCode: exitCode, stdout: stdout, stderr: stderr)
                setStatus(.error, title: "Claude rewrite failed", detail: detail)
            }

            private func scheduleFollowUpIfNeeded() {
                guard !isCancelled else {
                    return
                }

                let hasBufferedOutput = hasMeaningfulRawCapture
                    || terminalOutputCharacterCount > 0
                guard needsFollowUpRun || hasBufferedOutput else {
                    currentTerminalPrompt = nil
                    setStatus(.watching, title: "Watching terminal input")
                    return
                }

                needsFollowUpRun = false
                setStatus(.capturing, title: "Capturing terminal output", isTruncated: captureWasTruncated())
                scheduleAutomaticUpdate()
            }

            private func claudePrompt(
                terminalPrompt: String,
                terminalDelta: String
            ) -> String {
                let markdownSourceTerminalDelta = Self.cappedSuffix(
                    terminalDelta,
                    limit: maxTerminalDeltaCharacters
                )
                let terminalPromptForPrompt = Self.cappedSuffix(
                    terminalPrompt,
                    limit: maxTerminalPromptCharacters
                )

                return """
                You are CodeEditV2's Markdown Stream chunk formatter.

                You will receive the newly added terminal output for one command, captured from the Mac
                shell's raw stdout/stderr before SwiftTerm grid rendering. ANSI escape/color sequences have
                been removed and carriage-return/backspace control characters normalized, but lines are not
                wrapped to terminal width and cursor-repositioning redraws are not collapsed. Full-screen
                alternate-screen TUI output is excluded. Some captures may instead be a terminal-grid
                projection fallback; treat any line-wrapping or redraw repetition as cosmetic.
                Return only a GitHub-flavored Markdown chunk for that new terminal text.
                The app will append your chunk to the existing Markdown file after you return it. Do not
                return the complete document. Do not wrap the whole response in a code fence unless the
                chunk itself is a code block.

                Standing stream instruction:
                \(initialPrompt)

                Terminal input that triggered this update:
                \(terminalPromptForPrompt)

                Requirements:
                \(Self.claudePromptRequirements)

                ----- NEW TERMINAL SOURCE CHUNK START -----
                \(markdownSourceTerminalDelta)
                ----- NEW TERMINAL SOURCE CHUNK END -----
                """
            }

            private func claudeRewritePrompt(userPrompt: String, currentMarkdown: String) -> String {
                """
                You are CodeEditV2's Markdown Stream full-document editor.

                You will receive the current entire Markdown stream file and a user rewrite prompt.
                Apply the user prompt to the whole document and return the complete replacement Markdown file.

                Requirements:
                - Return only the full replacement Markdown document.
                - Preserve all technical details unless the user explicitly asks to remove or summarize them.
                - Keep formulas, tables, code blocks, image references, links, headings, and lists valid Markdown.
                - Preserve Markdown image syntax and HTML image tags when images are referenced.
                - Preserve LaTeX formulas with their delimiters, including $$ display math blocks.
                - Do not wrap the whole output in a code fence.
                - Do not explain your changes outside the Markdown document.

                ----- USER REWRITE PROMPT START -----
                \(userPrompt)
                ----- USER REWRITE PROMPT END -----

                ----- CURRENT MARKDOWN FILE START -----
                \(currentMarkdown)
                ----- CURRENT MARKDOWN FILE END -----

                Return the complete Markdown file that should replace the current file.
                """
            }

            private static var claudePromptRequirements: String {
                """
                - Produce one append-only Markdown chunk based only on the triggering terminal input and the
                  new terminal chunk.
                - You do not have the previous Markdown file. Do not infer, reference, update, revise,
                  summarize, or repeat prior entries.
                - Convert the increment to rendered Markdown. You may condense ordinary prose, but technical
                  artifacts must be lossless.
                - Use the new terminal source chunk as the source of truth. Do not ask for, mention, or
                  depend on terminal screenshots, previous stream entries, or the iOS Agent tab.
                - Preserve repeated lines when they carry meaningful output, such as table rows, formulas,
                  logs, numbered steps, or command results.
                - Collapse carriage-return progress redraws, such as repeated near-identical spinner or
                  percentage lines, to their final state; keep every distinct logical line otherwise.
                - Preserve one-to-one correspondence for formulas, equations, lemmas, definitions, numbered
                  steps, code blocks, table rows, numeric values, file paths, commands, and decisions.
                - Never replace omitted technical details with phrases like "and similar formulas",
                  "additional rows", "other terms", or "see the terminal".
                - Do not mention or depend on previous stream entries. The app appends your returned chunk
                  to the stream file.
                - Keep the document valid GitHub-flavored Markdown.
                - Use LaTeX delimiters for formulas when formulas appear, and include every distinct formula
                  from the new terminal chunk.
                - Preserve Markdown image syntax and HTML image tags when images are referenced.
                - Convert table-like output to native Markdown tables. Preserve every row and column when
                  the table is the important result.
                - Use fenced code blocks only for actual code, commands, stack traces, or raw output that
                  cannot be represented accurately as Markdown.
                - Do not place ordinary summaries, tables, or prose inside fenced code blocks.
                - If the new terminal chunk is empty or adds no useful information, return an empty
                  response.
                - Do not describe this instruction prompt.
                """
            }

            private func appendMarkdownEntry(_ markdown: String) throws {
                let currentMarkdown = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
                let separator = currentMarkdown.hasSuffix("\n") ? "\n---\n\n" : "\n\n---\n\n"
                let block = "## Update \(Self.updateTimestamp())\n\n\(markdown)"
                try (currentMarkdown + separator + block + "\n").write(
                    to: fileURL,
                    atomically: true,
                    encoding: .utf8
                )
            }

            private func replaceMarkdownDocument(_ markdown: String) throws {
                try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
            }

            private func setStatus(
                _ phase: TerminalRemoteProtocol.MarkdownStreamPhase,
                title: String,
                detail: String? = nil,
                isTruncated: Bool? = nil,
                publishActive: Bool = true,
                publish: Bool = true,
                force: Bool = false
            ) {
                let cappedDetail = detail.map { Self.cappedSuffix($0, limit: maxStatusDetailCharacters) }
                let status = TerminalRemoteProtocol.MarkdownStreamStatus(
                    phase: phase,
                    title: title,
                    detail: cappedDetail,
                    isTruncated: isTruncated
                )
                guard force || status != streamStatus else {
                    return
                }

                streamStatus = status
                if publish {
                    publishIfChanged(isActive: publishActive, force: true, updateKind: .status)
                }
            }

            private func publishIfChanged(
                isActive: Bool,
                force: Bool = false,
                updateKind: TerminalRemoteProtocol.MarkdownStreamUpdateKind = .snapshot
            ) {
                let signature = fileSignature()
                guard force || signature != lastSignature else {
                    return
                }

                if force || signature != lastSignature {
                    revision += 1
                }
                lastSignature = signature
                client?.sendMarkdownStreamSnapshot(
                    streamID: streamID,
                    sessionID: sessionID,
                    fileURL: fileURL,
                    isActive: isActive,
                    revision: revision,
                    updateKind: updateKind,
                    status: streamStatus
                )
            }

            private func fileSignature() -> String {
                guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
                    return "missing"
                }

                let timestamp = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                let byteCount = values.fileSize ?? 0
                return "\(timestamp)-\(byteCount)"
            }

            private func temporaryFileURL(suffix: String) -> URL {
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("codeeditv2-mdstream-\(streamID.uuidString)-\(UUID().uuidString).\(suffix)")
            }

            private static func claudeLaunchCommand(arguments: [String]) -> (
                executableURL: URL,
                arguments: [String]
            ) {
                if let executableURL = claudeExecutableURL() {
                    return (executableURL, arguments)
                }

                return (URL(fileURLWithPath: "/usr/bin/env"), ["claude"] + arguments)
            }

            private static func claudeExecutableURL() -> URL? {
                let fileManager = FileManager.default
                let homePath = fileManager.homeDirectoryForCurrentUser.path
                let configuredPath = ProcessInfo.processInfo.environment["CODEEDITV2_CLAUDE_PATH"]
                let candidates = [
                    configuredPath,
                    "\(homePath)/.npm-global/bin/claude",
                    "\(homePath)/.local/bin/claude",
                    "/opt/homebrew/bin/claude",
                    "/usr/local/bin/claude"
                ].compactMap { $0 }

                return candidates
                    .map { URL(fileURLWithPath: $0) }
                    .first { fileManager.isExecutableFile(atPath: $0.path) }
            }

            private static func claudeEnvironment() -> [String: String] {
                var environment = ProcessInfo.processInfo.environment
                let homePath = FileManager.default.homeDirectoryForCurrentUser.path
                let extraPath = [
                    "\(homePath)/.npm-global/bin",
                    "\(homePath)/.local/bin",
                    "/opt/homebrew/bin",
                    "/usr/local/bin",
                    "/usr/bin",
                    "/bin",
                    "/usr/sbin",
                    "/sbin"
                ].joined(separator: ":")
                let currentPath = environment["PATH"] ?? ""
                environment["PATH"] = currentPath.isEmpty ? extraPath : "\(extraPath):\(currentPath)"
                environment["HOME"] = homePath
                return environment
            }

            private static func normalizedMarkdownOutput(_ output: String) -> String {
                var lines = output
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: .newlines)

                if let firstLine = lines.first,
                   firstLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    lines.removeFirst()
                }

                if let lastLine = lines.last,
                   lastLine.trimmingCharacters(in: .whitespaces) == "```" {
                    lines.removeLast()
                }

                return lines.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    + "\n"
            }

            private static func updateTimestamp() -> String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                return formatter.string(from: Date())
            }

            private static func claudeFailureDetail(exitCode: Int32, stdout: String, stderr: String) -> String {
                let combinedOutput = [stdout, stderr]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")

                if combinedOutput.isEmpty {
                    return "Claude exited with status \(exitCode) and did not return Markdown."
                }

                return "Claude exited with status \(exitCode).\n\n\(combinedOutput)"
            }

            private static func cappedSuffix(_ text: String, limit: Int) -> String {
                guard text.count > limit else {
                    return text
                }

                return String(text.suffix(limit))
            }

            private static func hasMeaningfulTerminalText(in text: String) -> Bool {
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }

            private static func plainTerminalText(from data: Data) -> String {
                let text = decodedTerminalText(from: data)
                return strippingANSIEscapes(from: text)
            }

            private static func decodedTerminalText(from data: Data) -> String {
                data.withUnsafeBytes { rawBuffer in
                    let bytes = rawBuffer.bindMemory(to: UInt8.self)
                    return String(decoding: bytes, as: UTF8.self)
                }
            }

            private static func firstOSCTerminatorRange(
                in text: String,
                from startIndex: String.Index
            ) -> Range<String.Index>? {
                let bell = "\u{0007}"
                let stringTerminator = "\u{001B}\\"
                let bellRange = text.range(of: bell, range: startIndex..<text.endIndex)
                let stRange = text.range(of: stringTerminator, range: startIndex..<text.endIndex)

                switch (bellRange, stRange) {
                case (.some(let bellRange), .some(let stRange)):
                    return bellRange.lowerBound < stRange.lowerBound ? bellRange : stRange
                case (.some(let bellRange), .none):
                    return bellRange
                case (.none, .some(let stRange)):
                    return stRange
                case (.none, .none):
                    return nil
                }
            }

            private static func strippingANSIEscapes(from text: String) -> String {
                let escape = "\u{001B}"
                let patterns = [
                    "\(escape)\\[[0-?]*[ -/]*[@-~]",
                    "\(escape)\\][^\u{0007}\u{001B}]*(?:\u{0007}|\(escape)\\\\)",
                    "\(escape)."
                ]
                let withoutEscapes = patterns.reduce(text) { partialResult, pattern in
                    partialResult.replacingOccurrences(
                        of: pattern,
                        with: "",
                        options: .regularExpression
                    )
                }

                return normalizingTerminalControlCharacters(in: withoutEscapes)
            }

            private static func normalizingTerminalControlCharacters(in text: String) -> String {
                let text = text
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n")
                var result = String.UnicodeScalarView()

                for scalar in text.unicodeScalars {
                    appendNormalizedTerminalScalar(scalar, to: &result)
                }

                return String(result)
            }

            private static func appendNormalizedTerminalScalar(
                _ scalar: Unicode.Scalar,
                to result: inout String.UnicodeScalarView
            ) {
                switch scalar.value {
                case 0x08:
                    if !result.isEmpty {
                        result.removeLast()
                    }
                case 0x0D:
                    result.append("\n")
                case 0x0A, 0x09:
                    result.append(scalar)
                case 0x20...0x10FFFF:
                    result.append(scalar)
                default:
                    break
                }
            }
        }
    }
}
