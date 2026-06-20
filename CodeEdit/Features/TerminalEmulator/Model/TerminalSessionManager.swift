//
//  TerminalSessionManager.swift
//  CodeEdit
//
//  Created by Claude on 6/12/26.
//

import Darwin
import Foundation

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

struct TerminalProjectedRow {
    let row: Int
    let text: String
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
}

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
    private var projectedRows: [Int: String] = [:]
    private var projectedOutputSequence = 0
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
                guard let text = projectedRows[row],
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }

                return TerminalProjectedRow(row: row, text: text)
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
            rows: view.getTerminal().rows
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

            let text = line.translateToString(trimRight: true)
            guard projectedRows[row] != text else {
                continue
            }

            projectedRows[row] = text
            rows.append(TerminalProjectedRow(row: row, text: text))
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
        if registeredSessions[id] == nil {
            registeredSessionOrder.append(id)
        }

        registeredSessions[id] = RegisteredTerminalSession(
            title: title,
            currentDirectory: currentDirectory,
            shell: shell
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
