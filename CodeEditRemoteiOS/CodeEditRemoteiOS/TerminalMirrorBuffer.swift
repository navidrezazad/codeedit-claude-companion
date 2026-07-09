//
//  TerminalMirrorBuffer.swift
//  CodeEditRemoteiOS
//

import Foundation

struct TerminalMirrorSegment: Equatable {
    let text: String
    let foreground: Int?
    let background: Int?
    let style: Int
}

struct TerminalMirrorRow: Identifiable, Equatable {
    let id: Int
    let text: String
    let segments: [TerminalMirrorSegment]
}

struct TerminalMirrorSnapshot: Equatable {
    var sequence: Int
    var generation: Int
    var screenMode: TerminalRemoteProtocol.ScreenMode
    var columns: Int
    var terminalRows: Int
    var cursor: TerminalRemoteProtocol.ProjectedCursor?
    var rows: [TerminalMirrorRow]

    static let empty = TerminalMirrorSnapshot(
        sequence: 0,
        generation: 0,
        screenMode: .main,
        columns: 80,
        terminalRows: 24,
        cursor: nil,
        rows: []
    )

    var isAlternateScreen: Bool {
        screenMode == .alternate
    }
}

struct TerminalMirrorBuffer {
    private struct RowContent: Equatable {
        let text: String
        let segments: [TerminalMirrorSegment]
    }

    private let maxMainRows = 5_000
    private var mainRows: [Int: RowContent] = [:]
    private var alternateRows: [Int: RowContent] = [:]
    private var lastSequence = 0
    private var generation = 0
    private var screenMode = TerminalRemoteProtocol.ScreenMode.main
    private var columns = 80
    private var terminalRows = 24
    private var cursor: TerminalRemoteProtocol.ProjectedCursor?

    mutating func reset() -> TerminalMirrorSnapshot {
        mainRows.removeAll(keepingCapacity: true)
        alternateRows.removeAll(keepingCapacity: true)
        lastSequence = 0
        generation = 0
        screenMode = .main
        columns = 80
        terminalRows = 24
        cursor = nil
        return .empty
    }

    mutating func apply(_ output: TerminalRemoteProtocol.ProjectedOutput) -> TerminalMirrorSnapshot {
        let nextGeneration = output.generation ?? generation
        if nextGeneration < generation {
            return snapshot()
        }

        if nextGeneration > generation {
            clearAllRows()
            generation = nextGeneration
            lastSequence = 0
            cursor = nil
        } else if output.generation == nil, output.sequence < lastSequence {
            // Compatibility with protocol v1, where a sequence regression represented a reflow reset.
            clearAllRows()
            lastSequence = 0
            cursor = nil
        } else if output.sequence < lastSequence {
            return snapshot()
        }

        let nextScreenMode = output.screenMode ?? screenMode
        let nextColumns = max(1, output.columns ?? columns)
        let nextRows = max(1, output.terminalRows ?? terminalRows)

        if output.isSnapshot == true {
            clearRows(for: nextScreenMode)
        }

        columns = nextColumns
        terminalRows = nextRows
        if nextScreenMode != screenMode, output.cursor == nil {
            cursor = nil
        }
        cursor = output.cursor ?? cursor

        switch nextScreenMode {
        case .main:
            ingestMain(output)
        case .alternate:
            ingestAlternate(output)
        }

        return snapshot()
    }

    private mutating func ingestMain(_ output: TerminalRemoteProtocol.ProjectedOutput) {
        if screenMode == .alternate {
            alternateRows.removeAll(keepingCapacity: true)
        }
        screenMode = .main
        lastSequence = output.sequence

        for row in output.rows where row.row >= 0 {
            mainRows[row.row] = Self.rowContent(from: row)
        }

        trimMainRowsIfNeeded()
    }

    private mutating func ingestAlternate(_ output: TerminalRemoteProtocol.ProjectedOutput) {
        if screenMode != .alternate {
            alternateRows.removeAll(keepingCapacity: true)
        }

        screenMode = .alternate
        lastSequence = output.sequence

        for row in output.rows where row.row >= 0 && row.row < terminalRows {
            alternateRows[row.row] = Self.rowContent(from: row)
        }
    }

    private mutating func clearAllRows() {
        mainRows.removeAll(keepingCapacity: true)
        alternateRows.removeAll(keepingCapacity: true)
    }

    private mutating func clearRows(for mode: TerminalRemoteProtocol.ScreenMode) {
        switch mode {
        case .main:
            mainRows.removeAll(keepingCapacity: true)
        case .alternate:
            alternateRows.removeAll(keepingCapacity: true)
        }
    }

    private mutating func trimMainRowsIfNeeded() {
        guard mainRows.count > maxMainRows else {
            return
        }

        for key in mainRows.keys.sorted().prefix(mainRows.count - maxMainRows) {
            mainRows[key] = nil
        }
    }

    private func snapshot() -> TerminalMirrorSnapshot {
        TerminalMirrorSnapshot(
            sequence: lastSequence,
            generation: generation,
            screenMode: screenMode,
            columns: columns,
            terminalRows: terminalRows,
            cursor: cursor,
            rows: renderedRows()
        )
    }

    private func renderedRows() -> [TerminalMirrorRow] {
        switch screenMode {
        case .main:
            return mainRows.keys.sorted().map { key in
                let content = mainRows[key]
                return TerminalMirrorRow(
                    id: key,
                    text: content?.text ?? "",
                    segments: content?.segments ?? []
                )
            }
        case .alternate:
            guard terminalRows > 0 else {
                return []
            }
            return (0..<terminalRows).map { key in
                let content = alternateRows[key]
                return TerminalMirrorRow(
                    id: key,
                    text: content?.text ?? "",
                    segments: content?.segments ?? []
                )
            }
        }
    }

    private static func rowContent(from row: TerminalRemoteProtocol.ProjectedRow) -> RowContent {
        guard let spans = row.spans, !spans.isEmpty else {
            return RowContent(
                text: row.text,
                segments: [TerminalMirrorSegment(text: row.text, foreground: nil, background: nil, style: 0)]
            )
        }

        let segments = spans.map { span in
            TerminalMirrorSegment(
                text: span.text,
                foreground: span.foreground,
                background: span.background,
                style: span.style ?? 0
            )
        }
        return RowContent(text: row.text, segments: segments)
    }
}
