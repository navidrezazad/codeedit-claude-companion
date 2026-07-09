//
//  TerminalSessionManager.swift
//  CodeEdit
//
//  Created by Claude on 6/12/26.
//

import Darwin
import Foundation
import SwiftTerm

extension Notification.Name {
    static let terminalSessionDescriptorsDidChange = Notification.Name(
        "CodeEditV2.TerminalSessionDescriptorsDidChange"
    )
}

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

struct TerminalProjectedCursor: Equatable {
    let row: Int
    let column: Int
    let isVisible: Bool
    let shape: TerminalRemoteProtocol.CursorShape
    let isBlinking: Bool
}

struct TerminalProjectedOutput {
    let sequence: Int
    let generation: Int
    let isSnapshot: Bool
    let screenMode: TerminalRemoteProtocol.ScreenMode
    let columns: Int
    let terminalRows: Int
    let cursor: TerminalProjectedCursor
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

private struct RegisteredTerminalSession: Equatable {
    var title: String
    var currentDirectory: URL?
    var shell: Shell?
}

// swiftlint:disable:next type_body_length
final class TerminalSession: ObservableObject, Identifiable {
    typealias ByteHandler = (ArraySlice<UInt8>) -> Void
    typealias ProjectedOutputHandler = (TerminalProjectedOutput) -> Void
    typealias RawOutputHandler = (ArraySlice<UInt8>, TerminalRemoteProtocol.ScreenMode) -> Void

    let id: UUID
    let view: CELocalShellTerminalView
    let shell: Shell?

    @Published private(set) var title: String
    @Published private(set) var currentDirectory: URL?

    private var inputSubscribers: [UUID: ByteHandler] = [:]
    private var projectedOutputSubscribers: [UUID: ProjectedOutputHandler] = [:]
    private var rawOutputSubscribers: [UUID: RawOutputHandler] = [:]
    private var projectedRows: [Int: ProjectedRowContent] = [:]
    private var projectedOutputSequence = 0
    private var projectedOutputGeneration = 0
    private var lastProjectedColumns = 0
    private var lastProjectedRows = 0
    private var lastProjectedCursor: TerminalProjectedCursor?
    private var pendingProjectedOutputRange: (startY: Int, endY: Int)?
    private var pendingProjectedOutputIsSnapshot = false
    private var pendingProjectedMetadataUpdate = false
    private var pendingProjectedOutputWorkItem: DispatchWorkItem?
    private var screenMode: TerminalRemoteProtocol.ScreenMode = .main
    private var terminalControlTail = ""
    private let maxProjectedRows = 5_000
    private let projectedOutputPublishDelay: DispatchTimeInterval = .milliseconds(33)

    var isRunning: Bool {
        view.process?.running == true
    }

    init(
        id: UUID,
        view: CELocalShellTerminalView,
        shell: Shell?,
        title: String,
        currentDirectory: URL?
    ) {
        self.id = id
        self.view = view
        self.shell = shell
        self.title = title
        self.currentDirectory = currentDirectory
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

        if projectedOutputSubscribers.isEmpty {
            pendingProjectedOutputWorkItem?.cancel()
            pendingProjectedOutputWorkItem = nil
            pendingProjectedOutputRange = nil
            pendingProjectedOutputIsSnapshot = false
            pendingProjectedMetadataUpdate = false
        }
    }

    func sendInput(_ bytes: ArraySlice<UInt8>) {
        guard isRunning else {
            return
        }
        view.process.send(data: bytes)
        publishInput(bytes)
    }

    func recentProjectedOutputSnapshot() -> TerminalProjectedOutput? {
        let terminal = view.getTerminal()
        if terminal.cols != lastProjectedColumns || terminal.rows != lastProjectedRows {
            resetProjectionForDimensionChange(terminal)
        }

        let startRow = terminal.buffer.yDisp
        let endRow = startRow + max(0, terminal.rows - 1)
        var rows: [TerminalProjectedRow] = []

        if startRow <= endRow {
            for row in startRow...endRow {
                guard let line = terminal.getScrollInvariantLine(row: row) else {
                    continue
                }

                let content = Self.projectedRowContent(from: line)
                projectedRows[row] = content
                rows.append(TerminalProjectedRow(row: row, text: content.text, spans: content.spans))
            }
        }

        guard !rows.isEmpty else {
            return nil
        }

        let cursor = projectedCursor(for: terminal)
        lastProjectedCursor = cursor
        return TerminalProjectedOutput(
            sequence: projectedOutputSequence,
            generation: projectedOutputGeneration,
            isSnapshot: true,
            screenMode: screenMode,
            columns: terminal.cols,
            terminalRows: terminal.rows,
            cursor: cursor,
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
            rows: view.getTerminal().rows
        )
    }

    fileprivate func appendOutput(_ bytes: ArraySlice<UInt8>) {
        updateScreenMode(from: bytes)
        let currentScreenMode = screenMode

        rawOutputSubscribers.values.forEach { $0(bytes, currentScreenMode) }
    }

    fileprivate func publishRenderedOutputIfNeeded() {
        guard !projectedOutputSubscribers.isEmpty else {
            return
        }

        recordRenderedOutputUpdate()
    }

    fileprivate func publishInput(_ bytes: ArraySlice<UInt8>) {
        inputSubscribers.values.forEach { $0(bytes) }
    }

    private func recordRenderedOutputUpdate() {
        let terminal = view.getTerminal()
        var recordedUpdate = false

        // A resize can renumber the scroll-invariant row indices. Start a new generation and send a
        // complete visible snapshot so the remote never combines pre-reflow and post-reflow rows.
        if terminal.cols != lastProjectedColumns || terminal.rows != lastProjectedRows {
            resetProjectionForDimensionChange(terminal)
            pendingProjectedOutputIsSnapshot = true
            pendingProjectedMetadataUpdate = true
            mergePendingProjectedOutputRange(
                startY: terminal.buffer.yDisp,
                endY: terminal.buffer.yDisp + max(0, terminal.rows - 1)
            )
            recordedUpdate = true
        }

        if let range = terminal.getScrollInvariantUpdateRange() {
            mergePendingProjectedOutputRange(startY: range.startY, endY: range.endY)
            recordedUpdate = true
        }

        if projectedCursor(for: terminal) != lastProjectedCursor {
            pendingProjectedMetadataUpdate = true
            recordedUpdate = true
        }

        guard recordedUpdate
                || pendingProjectedOutputRange != nil
                || pendingProjectedOutputIsSnapshot
                || pendingProjectedMetadataUpdate else {
            return
        }

        schedulePendingProjectedOutputPublish()
    }

    private func mergePendingProjectedOutputRange(startY: Int, endY: Int) {
        let lowerBound = min(startY, endY)
        let upperBound = max(startY, endY)
        let cappedStart = max(lowerBound, upperBound - maxProjectedRows + 1)

        if let pendingProjectedOutputRange {
            self.pendingProjectedOutputRange = (
                startY: min(pendingProjectedOutputRange.startY, cappedStart),
                endY: max(pendingProjectedOutputRange.endY, upperBound)
            )
        } else {
            pendingProjectedOutputRange = (startY: cappedStart, endY: upperBound)
        }
    }

    private func schedulePendingProjectedOutputPublish() {
        guard pendingProjectedOutputWorkItem == nil else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.publishPendingProjectedOutput()
        }
        pendingProjectedOutputWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + projectedOutputPublishDelay, execute: workItem)
    }

    private func publishPendingProjectedOutput() {
        pendingProjectedOutputWorkItem = nil

        guard !projectedOutputSubscribers.isEmpty else {
            pendingProjectedOutputRange = nil
            return
        }

        let range = pendingProjectedOutputRange
        let isSnapshot = pendingProjectedOutputIsSnapshot
        pendingProjectedOutputRange = nil
        pendingProjectedOutputIsSnapshot = false
        pendingProjectedMetadataUpdate = false

        guard let projection = renderedOutputProjection(for: range, isSnapshot: isSnapshot) else {
            return
        }

        projectedOutputSubscribers.values.forEach { $0(projection) }
    }

    private func renderedOutputProjection(
        for range: (startY: Int, endY: Int)?,
        isSnapshot requestedSnapshot: Bool
    ) -> TerminalProjectedOutput? {
        let terminal = view.getTerminal()
        var startRow = range.map { min($0.startY, $0.endY) }
        var endRow = range.map { max($0.startY, $0.endY) }
        var isSnapshot = requestedSnapshot

        if terminal.cols != lastProjectedColumns || terminal.rows != lastProjectedRows {
            resetProjectionForDimensionChange(terminal)
            isSnapshot = true
            startRow = terminal.buffer.yDisp
            endRow = terminal.buffer.yDisp + max(0, terminal.rows - 1)
        }

        var rows: [TerminalProjectedRow] = []

        if let startRow, let endRow, startRow <= endRow {
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
        }

        let cursor = projectedCursor(for: terminal)
        let cursorChanged = cursor != lastProjectedCursor
        guard !rows.isEmpty || cursorChanged || isSnapshot else {
            return nil
        }

        trimProjectedRowsIfNeeded()
        lastProjectedCursor = cursor
        projectedOutputSequence += 1
        return TerminalProjectedOutput(
            sequence: projectedOutputSequence,
            generation: projectedOutputGeneration,
            isSnapshot: isSnapshot,
            screenMode: screenMode,
            columns: terminal.cols,
            terminalRows: terminal.rows,
            cursor: cursor,
            rows: rows
        )
    }

    private func resetProjectionForDimensionChange(_ terminal: Terminal) {
        lastProjectedColumns = terminal.cols
        lastProjectedRows = terminal.rows
        projectedRows.removeAll(keepingCapacity: true)
        projectedOutputGeneration += 1
        // Keep protocol-v1 clients functional while protocol v2 uses the generation as the authority.
        projectedOutputSequence = 0
    }

    private func projectedCursor(for terminal: Terminal) -> TerminalProjectedCursor {
        let location = terminal.getCursorLocation()
        let shape: TerminalRemoteProtocol.CursorShape
        let isBlinking: Bool

        switch view.mirroredCursorStyle {
        case .blinkBlock:
            shape = .block
            isBlinking = true
        case .steadyBlock:
            shape = .block
            isBlinking = false
        case .blinkUnderline:
            shape = .underline
            isBlinking = true
        case .steadyUnderline:
            shape = .underline
            isBlinking = false
        case .blinkBar:
            shape = .bar
            isBlinking = true
        case .steadyBar:
            shape = .bar
            isBlinking = false
        }

        return TerminalProjectedCursor(
            row: terminal.getTopVisibleRow() + location.y,
            column: max(0, min(location.x, max(0, terminal.cols - 1))),
            isVisible: view.mirroredCursorIsVisible,
            shape: shape,
            isBlinking: isBlinking
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

    /// Builds the plain text and run-length-encoded styled spans for a SwiftTerm buffer line.
    /// Trailing default cells are omitted, but styled blank cells are retained because TUIs use
    /// them for full-width backgrounds, selections, and status bars.
    private static func projectedRowContent(from line: BufferLine) -> ProjectedRowContent {
        var contentLength = line.count
        while contentLength > 0, !line.hasContent(index: contentLength - 1) {
            contentLength -= 1
        }

        guard contentLength > 0 else {
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
        while column < contentLength {
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
                rows: nil
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
        shell: Shell?
    ) {
        let registration = RegisteredTerminalSession(
            title: title,
            currentDirectory: currentDirectory,
            shell: shell
        )
        let isNew = registeredSessions[id] == nil
        let didChange = registeredSessions[id] != registration

        if isNew {
            registeredSessionOrder.append(id)
        }

        registeredSessions[id] = registration
        if isNew || didChange {
            notifySessionDescriptorsDidChange()
        }
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
            shell: registration.shell
        ).session
    }

    func getOrCreateSession(
        id: UUID,
        workspaceURL: URL?,
        shell: Shell?
    ) -> (session: TerminalSession, isNew: Bool) {
        if let session = sessions[id] {
            return (session, false)
        }

        let registration = registeredSessions[id]
        let currentDirectory = workspaceURL ?? registration?.currentDirectory
        let resolvedShell = shell ?? registration?.shell
        let view = CELocalShellTerminalView(frame: .zero)
        let title = registration?.title ?? resolvedShell?.rawValue ?? "terminal"
        let session = TerminalSession(
            id: id,
            view: view,
            shell: resolvedShell,
            title: title,
            currentDirectory: currentDirectory
        )

        view.sessionDelegate = session
        view.startProcess(workspaceURL: currentDirectory, shell: resolvedShell)
        sessions[id] = session
        if registeredSessions[id] == nil {
            registeredSessionOrder.append(id)
        }
        registeredSessions[id] = RegisteredTerminalSession(
            title: title,
            currentDirectory: currentDirectory,
            shell: resolvedShell
        )
        notifySessionDescriptorsDidChange()

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

        session.view.resizeFromRemote(columns: columns, rows: rows)
    }

    func recentProjectedOutput(for id: UUID) -> TerminalProjectedOutput? {
        sessions[id]?.recentProjectedOutputSnapshot()
    }

    func updateSession(_ id: UUID, title: String) {
        var didChange = false
        if let session = sessions[id], session.title != title {
            session.update(title: title)
            didChange = true
        }
        if var registration = registeredSessions[id] {
            if registration.title != title {
                registration.title = title
                registeredSessions[id] = registration
                didChange = true
            }
        }
        if didChange {
            notifySessionDescriptorsDidChange()
        }
    }

    func updateSession(_ id: UUID, currentDirectory: URL) {
        var didChange = false
        if let session = sessions[id], session.currentDirectory != currentDirectory {
            session.update(currentDirectory: currentDirectory)
            didChange = true
        }
        if var registration = registeredSessions[id] {
            if registration.currentDirectory != currentDirectory {
                registration.currentDirectory = currentDirectory
                registeredSessions[id] = registration
                didChange = true
            }
        }
        if didChange {
            notifySessionDescriptorsDidChange()
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
        let didExist = sessions[id] != nil || registeredSessions[id] != nil
        sessions[id]?.view.sessionDelegate = nil
        sessions[id] = nil
        registeredSessions[id] = nil
        registeredSessionOrder.removeAll { $0 == id }
        configurationSignatures[id] = nil
        if didExist {
            notifySessionDescriptorsDidChange()
        }
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

    private func notifySessionDescriptorsDidChange() {
        NotificationCenter.default.post(name: .terminalSessionDescriptorsDidChange, object: nil)
    }
}
