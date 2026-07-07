//
//  TerminalSessionManager.swift
//  CodeEdit
//
//  Created by Claude on 6/12/26.
//

import Darwin
import Foundation
import SwiftTerm

protocol CELocalShellTerminalViewSessionDelegate: AnyObject {
    func terminalView(_ terminalView: CELocalShellTerminalView, didReceiveOutput bytes: ArraySlice<UInt8>)
    func terminalView(_ terminalView: CELocalShellTerminalView, didSendInput bytes: ArraySlice<UInt8>)
    func terminalViewDidRenderOutput(_ terminalView: CELocalShellTerminalView)
}

struct TerminalSessionDescriptor: Identifiable, Equatable {
    let id: UUID
    let title: String
    let currentDirectory: URL?
    let shell: Shell?
    let isRunning: Bool
    let columns: Int?
    let rows: Int?
    /// The tmux session name backing this terminal, when tmux is the session store; `nil` for a
    /// plain-shell fallback terminal.
    let tmuxName: String?
}

struct TerminalProjectedSpan: Equatable {
    let text: String
    let foreground: Int?
    let background: Int?
    let style: Int
}

struct TerminalProjectedRow {
    let row: Int
    let text: String
    let spans: [TerminalProjectedSpan]

    init(row: Int, text: String, spans: [TerminalProjectedSpan] = []) {
        self.row = row
        self.text = text
        self.spans = spans
    }
}

struct TerminalProjectedOutput {
    let sequence: Int
    let screenMode: TerminalRemoteProtocol.ScreenMode
    let columns: Int
    let terminalRows: Int
    let rows: [TerminalProjectedRow]

    var text: String {
        guard !rows.isEmpty else {
            return ""
        }

        return rows.map(\.text).joined(separator: "\n") + "\n"
    }

    var hasMeaningfulText: Bool {
        rows.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

private struct RegisteredTerminalSession {
    var title: String
    var currentDirectory: URL?
    var shell: Shell?
    var tmuxSessionName: String?
}

final class TerminalSession: ObservableObject, Identifiable {
    typealias ByteHandler = (ArraySlice<UInt8>) -> Void
    typealias ProjectedOutputHandler = (TerminalProjectedOutput) -> Void
    typealias RawOutputHandler = (ArraySlice<UInt8>, TerminalRemoteProtocol.ScreenMode) -> Void

    let id: UUID
    let view: CELocalShellTerminalView
    let shell: Shell?
    /// The tmux session name this terminal is attached to, or `nil` for a plain-shell terminal.
    let tmuxSessionName: String?

    @Published private(set) var title: String
    @Published private(set) var currentDirectory: URL?

    private var inputSubscribers: [UUID: ByteHandler] = [:]
    private var projectedOutputSubscribers: [UUID: ProjectedOutputHandler] = [:]
    private var rawOutputSubscribers: [UUID: RawOutputHandler] = [:]
    private var projectedRows: [Int: ProjectedRowContent] = [:]
    private var projectedOutputSequence = 0
    private var lastProjectedColumns = 0
    private var lastProjectedRows = 0
    private var screenMode: TerminalRemoteProtocol.ScreenMode = .main
    private var terminalControlTail = ""
    private let maxProjectedRows = 5_000

    var isRunning: Bool {
        view.process?.running == true
    }

    init(
        id: UUID,
        view: CELocalShellTerminalView,
        shell: Shell?,
        title: String,
        currentDirectory: URL?,
        tmuxSessionName: String?
    ) {
        self.id = id
        self.view = view
        self.shell = shell
        self.title = title
        self.currentDirectory = currentDirectory
        self.tmuxSessionName = tmuxSessionName
    }

    func update(title: String) {
        self.title = title
    }

    func update(currentDirectory: URL) {
        self.currentDirectory = currentDirectory
    }

    @discardableResult
    func subscribeToInput(_ handler: @escaping ByteHandler) -> UUID {
        let token = UUID()
        inputSubscribers[token] = handler
        return token
    }

    @discardableResult
    func subscribeToProjectedOutput(_ handler: @escaping ProjectedOutputHandler) -> UUID {
        let token = UUID()
        projectedOutputSubscribers[token] = handler
        return token
    }

    @discardableResult
    func subscribeToRawOutput(_ handler: @escaping RawOutputHandler) -> UUID {
        let token = UUID()
        rawOutputSubscribers[token] = handler
        return token
    }

    func unsubscribe(_ token: UUID) {
        inputSubscribers[token] = nil
        projectedOutputSubscribers[token] = nil
        rawOutputSubscribers[token] = nil
    }

    func sendInput(_ bytes: ArraySlice<UInt8>) {
        guard isRunning else {
            return
        }
        view.process.send(data: bytes)
        publishInput(bytes)
    }

    func recentProjectedOutputSnapshot() -> TerminalProjectedOutput? {
        let rows = projectedRows.keys
            .sorted()
            .compactMap { row -> TerminalProjectedRow? in
                guard let content = projectedRows[row],
                      !content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }

                return TerminalProjectedRow(row: row, text: content.text, spans: content.spans)
            }

        guard !rows.isEmpty else {
            return nil
        }

        let terminal = view.getTerminal()
        return TerminalProjectedOutput(
            sequence: projectedOutputSequence,
            screenMode: screenMode,
            columns: terminal.cols,
            terminalRows: terminal.rows,
            rows: rows
        )
    }

    func descriptor() -> TerminalSessionDescriptor {
        TerminalSessionDescriptor(
            id: id,
            title: title,
            currentDirectory: currentDirectory,
            shell: shell,
            isRunning: isRunning,
            columns: view.getTerminal().cols,
            rows: view.getTerminal().rows,
            tmuxName: tmuxSessionName
        )
    }

    fileprivate func appendOutput(_ bytes: ArraySlice<UInt8>) {
        updateScreenMode(from: bytes)
        let currentScreenMode = screenMode

        rawOutputSubscribers.values.forEach { $0(bytes, currentScreenMode) }
    }

    fileprivate func publishRenderedOutputIfNeeded() {
        guard let projection = renderedOutputProjection() else {
            return
        }

        projectedOutputSubscribers.values.forEach { $0(projection) }
    }

    fileprivate func publishInput(_ bytes: ArraySlice<UInt8>) {
        inputSubscribers.values.forEach { $0(bytes) }
    }

    private func renderedOutputProjection() -> TerminalProjectedOutput? {
        let terminal = view.getTerminal()

        // A window/pane resize reflows the whole SwiftTerm buffer, which renumbers the scroll-invariant
        // row indices the mirror keys on. The wire protocol overwrites rows by index and has no
        // "row removed" signal, so without this the iOS mirror keeps stale rows at the old indices and
        // duplicates content. On a dimension change, resync: drop the change-detection cache, restart the
        // sequence (so the mirror clears via its sequence-regression path), and re-mark the full screen so
        // the current contents are re-sent under their new indices.
        if terminal.cols != lastProjectedColumns || terminal.rows != lastProjectedRows {
            lastProjectedColumns = terminal.cols
            lastProjectedRows = terminal.rows
            projectedRows.removeAll(keepingCapacity: true)
            projectedOutputSequence = 0
            terminal.refresh(startRow: 0, endRow: max(0, terminal.rows - 1))
        }

        guard let range = terminal.getScrollInvariantUpdateRange() else {
            return nil
        }

        let startRow = min(range.startY, range.endY)
        let endRow = max(range.startY, range.endY)
        var rows: [TerminalProjectedRow] = []

        for row in startRow...endRow {
            guard let line = terminal.getScrollInvariantLine(row: row) else {
                continue
            }

            let content = Self.projectedRowContent(from: line)
            guard projectedRows[row] != content else {
                continue
            }

            projectedRows[row] = content
            rows.append(TerminalProjectedRow(row: row, text: content.text, spans: content.spans))
        }

        guard !rows.isEmpty else {
            return nil
        }

        trimProjectedRowsIfNeeded()
        projectedOutputSequence += 1
        return TerminalProjectedOutput(
            sequence: projectedOutputSequence,
            screenMode: screenMode,
            columns: terminal.cols,
            terminalRows: terminal.rows,
            rows: rows
        )
    }

    private func updateScreenMode(from bytes: ArraySlice<UInt8>) {
        let text = String(decoding: bytes, as: UTF8.self)
        terminalControlTail = String((terminalControlTail + text).suffix(512))

        guard let mode = Self.latestScreenModeChange(in: terminalControlTail),
              mode != screenMode else {
            return
        }

        screenMode = mode
        projectedRows.removeAll(keepingCapacity: true)
    }

    private func trimProjectedRowsIfNeeded() {
        guard projectedRows.count > maxProjectedRows else {
            return
        }

        for key in projectedRows.keys.sorted().prefix(projectedRows.count - maxProjectedRows) {
            projectedRows[key] = nil
        }
    }

    private static func latestScreenModeChange(in text: String) -> TerminalRemoteProtocol.ScreenMode? {
        let alternateOnSequences = [
            "\u{001B}[?1049h",
            "\u{001B}[?1047h",
            "\u{001B}[?47h"
        ]
        let alternateOffSequences = [
            "\u{001B}[?1049l",
            "\u{001B}[?1047l",
            "\u{001B}[?47l"
        ]

        var latestChange: (index: String.Index, mode: TerminalRemoteProtocol.ScreenMode)?

        for sequence in alternateOnSequences {
            if let range = text.range(of: sequence, options: .backwards),
               latestChange == nil || range.lowerBound > latestChange!.index {
                latestChange = (range.lowerBound, .alternate)
            }
        }

        for sequence in alternateOffSequences {
            if let range = text.range(of: sequence, options: .backwards),
               latestChange == nil || range.lowerBound > latestChange!.index {
                latestChange = (range.lowerBound, .main)
            }
        }

        return latestChange?.mode
    }

    /// Cached styled contents of a single projected row, used both for change detection and for the
    /// "recent output" snapshot sent on attach.
    private struct ProjectedRowContent: Equatable {
        let text: String
        let spans: [TerminalProjectedSpan]
    }

    /// Builds the plain text and run-length-encoded styled spans for a SwiftTerm buffer line,
    /// mirroring `translateToString(trimRight:)` while also capturing ANSI color/style.
    private static func projectedRowContent(from line: BufferLine) -> ProjectedRowContent {
        let trimmedLength = line.getTrimmedLength()
        guard trimmedLength > 0 else {
            return ProjectedRowContent(text: "", spans: [])
        }

        var spans: [TerminalProjectedSpan] = []
        var text = ""
        var currentText = ""
        var currentKey: SpanKey?

        func flush() {
            guard let key = currentKey, !currentText.isEmpty else {
                return
            }
            spans.append(
                TerminalProjectedSpan(
                    text: currentText,
                    foreground: key.foreground,
                    background: key.background,
                    style: key.style
                )
            )
            currentText = ""
        }

        var column = 0
        while column < trimmedLength {
            let cell = line[column]
            column += 1

            // Skip the trailing placeholder cell of a wide (2-column) character.
            if cell.width == 0 {
                continue
            }

            let rawCharacter = cell.getCharacter()
            let character: Character = rawCharacter == "\0" ? " " : rawCharacter
            let key = SpanKey(attribute: cell.attribute)
            if key != currentKey {
                flush()
                currentKey = key
            }
            currentText.append(character)
            text.append(character)
        }
        flush()

        return ProjectedRowContent(text: text, spans: spans)
    }

    /// Resolved color/style for a cell, used to coalesce equally-styled neighbors into one span.
    private struct SpanKey: Equatable {
        let foreground: Int?
        let background: Int?
        let style: Int

        init(attribute: Attribute) {
            var style = 0
            let cellStyle = attribute.style
            if cellStyle.contains(.bold) { style |= TerminalRemoteProtocol.SpanStyle.bold }
            if cellStyle.contains(.italic) { style |= TerminalRemoteProtocol.SpanStyle.italic }
            if cellStyle.contains(.underline) { style |= TerminalRemoteProtocol.SpanStyle.underline }
            if cellStyle.contains(.crossedOut) { style |= TerminalRemoteProtocol.SpanStyle.strikethrough }
            if cellStyle.contains(.dim) { style |= TerminalRemoteProtocol.SpanStyle.dim }
            self.style = style

            var foreground = Self.packedColor(attribute.fg)
            var background = Self.packedColor(attribute.bg)

            if cellStyle.contains(.inverse) {
                let resolvedForeground = foreground ?? TerminalRemoteProtocol.defaultForegroundRGB
                let resolvedBackground = background ?? TerminalRemoteProtocol.defaultBackgroundRGB
                foreground = resolvedBackground
                background = resolvedForeground
            }

            if cellStyle.contains(.invisible) {
                foreground = background
            }

            self.foreground = foreground
            self.background = background
        }

        private static func packedColor(_ color: Attribute.Color) -> Int? {
            switch color {
            case .defaultColor, .defaultInvertedColor:
                return nil
            case let .trueColor(red, green, blue):
                return (Int(red) << 16) | (Int(green) << 8) | Int(blue)
            case let .ansi256(code):
                return TerminalANSIPalette.packed[Int(code)]
            }
        }
    }
}

/// The standard 256-entry xterm palette as packed `0xRRGGBB` integers. The first 16 entries match
/// SwiftTerm's default installed ANSI colors so the iPhone shows the same hues as the Mac terminal.
private enum TerminalANSIPalette {
    static let packed: [Int] = build()

    private static func build() -> [Int] {
        var colors: [Int] = [
            0x0000_0000, 0x0099_0001, 0x0000_A603, 0x0099_9900,
            0x0003_00B2, 0x00B2_00B2, 0x0000_A5B2, 0x00BF_BFBF,
            0x008A_898A, 0x00E5_0001, 0x0000_D800, 0x00E5_E500,
            0x0007_00FE, 0x00E5_00E5, 0x0000_E5E5, 0x00E5_E5E5
        ]

        let levels = [0x00, 0x5F, 0x87, 0xAF, 0xD7, 0xFF]
        for index in 0..<216 {
            let red = levels[(index / 36) % 6]
            let green = levels[(index / 6) % 6]
            let blue = levels[index % 6]
            colors.append((red << 16) | (green << 8) | blue)
        }

        for index in 0..<24 {
            let value = 8 + index * 10
            colors.append((value << 16) | (value << 8) | value)
        }

        return colors
    }
}

extension TerminalSession: CELocalShellTerminalViewSessionDelegate {
    func terminalView(_ terminalView: CELocalShellTerminalView, didReceiveOutput bytes: ArraySlice<UInt8>) {
        appendOutput(bytes)
    }

    func terminalView(_ terminalView: CELocalShellTerminalView, didSendInput bytes: ArraySlice<UInt8>) {
        publishInput(bytes)
    }

    func terminalViewDidRenderOutput(_ terminalView: CELocalShellTerminalView) {
        publishRenderedOutputIfNeeded()
    }
}

final class TerminalSessionManager {
    static let shared = TerminalSessionManager()

    private var sessions: [UUID: TerminalSession] = [:]
    private var registeredSessions: [UUID: RegisteredTerminalSession] = [:]
    private var registeredSessionOrder: [UUID] = []
    private var configurationSignatures: [UUID: String] = [:]

    private init() {}

    func getSession(_ id: UUID) -> TerminalSession? {
        sessions[id]
    }

    /// The tmux session name backing a terminal id, if any (from the live session or its registration).
    func tmuxSessionName(for id: UUID) -> String? {
        sessions[id]?.tmuxSessionName ?? registeredSessions[id]?.tmuxSessionName
    }

    func sessionDescriptors() -> [TerminalSessionDescriptor] {
        let registeredDescriptors = registeredSessionOrder.compactMap { id -> TerminalSessionDescriptor? in
            guard let registration = registeredSessions[id] else {
                return nil
            }

            if let session = sessions[id] {
                return session.descriptor()
            }

            return TerminalSessionDescriptor(
                id: id,
                title: registration.title,
                currentDirectory: registration.currentDirectory,
                shell: registration.shell,
                isRunning: false,
                columns: nil,
                rows: nil,
                tmuxName: registration.tmuxSessionName
            )
        }

        let activeOnlyDescriptors = sessions
            .filter { id, _ in registeredSessions[id] == nil }
            .map { _, session in session.descriptor() }

        return registeredDescriptors + activeOnlyDescriptors
            .sorted { lhs, rhs in lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending }
    }

    func registerTerminal(
        id: UUID,
        title: String,
        currentDirectory: URL?,
        shell: Shell?,
        tmuxSessionName: String? = nil
    ) {
        if registeredSessions[id] == nil {
            registeredSessionOrder.append(id)
        }

        registeredSessions[id] = RegisteredTerminalSession(
            title: title,
            currentDirectory: currentDirectory,
            shell: shell,
            tmuxSessionName: tmuxSessionName
        )
    }

    func ensureSession(_ id: UUID) -> TerminalSession? {
        if let session = sessions[id] {
            return session
        }

        guard let registration = registeredSessions[id] else {
            return nil
        }

        return getOrCreateSession(
            id: id,
            workspaceURL: registration.currentDirectory,
            shell: registration.shell,
            tmuxSessionName: registration.tmuxSessionName
        ).session
    }

    func getOrCreateSession(
        id: UUID,
        workspaceURL: URL?,
        shell: Shell?,
        tmuxSessionName: String? = nil
    ) -> (session: TerminalSession, isNew: Bool) {
        if let session = sessions[id] {
            return (session, false)
        }

        let registration = registeredSessions[id]
        let currentDirectory = workspaceURL ?? registration?.currentDirectory
        let resolvedShell = shell ?? registration?.shell
        // tmux is the session store: back every terminal with a tmux session when tmux is available,
        // and fall back to a plain shell when it isn't. An explicit name (from the session manager) or a
        // previously registered name wins; otherwise a stable per-terminal name is derived from the id.
        let resolvedTmuxName: String?
        if TmuxService.shared.isAvailable {
            resolvedTmuxName = tmuxSessionName
                ?? registration?.tmuxSessionName
                ?? "codeedit-\(id.uuidString.prefix(8).lowercased())"
        } else {
            resolvedTmuxName = nil
        }
        let view = CELocalShellTerminalView(frame: .zero)
        let title = registration?.title ?? resolvedTmuxName ?? resolvedShell?.rawValue ?? "terminal"
        let session = TerminalSession(
            id: id,
            view: view,
            shell: resolvedShell,
            title: title,
            currentDirectory: currentDirectory,
            tmuxSessionName: resolvedTmuxName
        )

        view.sessionDelegate = session
        view.startProcess(
            workspaceURL: currentDirectory,
            shell: resolvedShell,
            tmuxSessionName: resolvedTmuxName
        )
        if resolvedTmuxName != nil {
            // Enable tmux mouse mode shortly after the server starts so trackpad scrolling works even for
            // the first session (before any sidebar reconcile has run). Runs off the main thread.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.6) {
                TmuxService.shared.enableMouseModeOnce()
            }
        }
        sessions[id] = session
        if registeredSessions[id] == nil {
            registeredSessionOrder.append(id)
        }
        registeredSessions[id] = RegisteredTerminalSession(
            title: title,
            currentDirectory: currentDirectory,
            shell: resolvedShell,
            tmuxSessionName: resolvedTmuxName
        )

        return (session, true)
    }

    func sendInput(_ bytes: ArraySlice<UInt8>, to id: UUID) {
        ensureSession(id)?.sendInput(bytes)
    }

    func resizeSession(_ id: UUID, columns: Int, rows: Int) {
        guard
            columns > 0,
            rows > 0,
            let session = ensureSession(id),
            session.isRunning
        else {
            return
        }

        let terminal = session.view.getTerminal()
        guard terminal.cols != columns || terminal.rows != rows else {
            return
        }

        session.view.resize(cols: columns, rows: rows)
    }

    func recentProjectedOutput(for id: UUID) -> TerminalProjectedOutput? {
        sessions[id]?.recentProjectedOutputSnapshot()
    }

    func updateSession(_ id: UUID, title: String) {
        sessions[id]?.update(title: title)
        if var registration = registeredSessions[id] {
            registration.title = title
            registeredSessions[id] = registration
        }
    }

    func updateSession(_ id: UUID, currentDirectory: URL) {
        sessions[id]?.update(currentDirectory: currentDirectory)
        if var registration = registeredSessions[id] {
            registration.currentDirectory = currentDirectory
            registeredSessions[id] = registration
        }
    }

    func terminateSession(_ id: UUID, signal: Int32 = SIGHUP) {
        guard
            let process = sessions[id]?.view.process,
            process.running,
            process.shellPid != 0
        else {
            return
        }

        _ = kill(-process.shellPid, signal)
        _ = kill(process.shellPid, signal)
    }

    func removeSession(_ id: UUID) {
        sessions[id]?.view.sessionDelegate = nil
        sessions[id] = nil
        registeredSessions[id] = nil
        registeredSessionOrder.removeAll { $0 == id }
        configurationSignatures[id] = nil
    }

    func terminateAndRemoveSession(_ id: UUID, signal: Int32 = SIGHUP) {
        terminateSession(id, signal: signal)
        removeSession(id)
    }

    func getConfigurationSignature(_ id: UUID) -> String? {
        configurationSignatures[id]
    }

    func cacheConfigurationSignature(_ signature: String, for id: UUID) {
        configurationSignatures[id] = signature
    }
}
