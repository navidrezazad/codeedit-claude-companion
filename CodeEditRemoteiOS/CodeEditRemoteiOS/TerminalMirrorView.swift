//
//  TerminalMirrorView.swift
//  CodeEditRemoteiOS
//
//  Created by Claude on 6/13/26.
//

import SwiftUI
import UIKit

struct TerminalMirrorRow: Identifiable, Equatable {
    let id: Int
    let text: String
}

struct TerminalMirrorSnapshot: Equatable {
    var sequence: Int
    var screenMode: TerminalRemoteProtocol.ScreenMode
    var columns: Int
    var terminalRows: Int
    var rows: [TerminalMirrorRow]

    static let empty = TerminalMirrorSnapshot(
        sequence: 0,
        screenMode: .main,
        columns: 80,
        terminalRows: 24,
        rows: []
    )

    var isAlternateScreen: Bool {
        screenMode == .alternate
    }
}

struct TerminalMirrorBuffer {
    private let maxMainRows = 5_000
    private var mainRows: [Int: String] = [:]
    private var alternateRows: [Int: String] = [:]
    private var lastSequence = 0
    private var screenMode = TerminalRemoteProtocol.ScreenMode.main
    private var columns = 80
    private var terminalRows = 24

    mutating func reset() -> TerminalMirrorSnapshot {
        mainRows.removeAll(keepingCapacity: true)
        alternateRows.removeAll(keepingCapacity: true)
        lastSequence = 0
        screenMode = .main
        columns = 80
        terminalRows = 24
        return .empty
    }

    mutating func apply(_ output: TerminalRemoteProtocol.ProjectedOutput) -> TerminalMirrorSnapshot {
        let nextScreenMode = output.screenMode ?? screenMode
        let nextColumns = max(1, output.columns ?? columns)
        let nextRows = max(1, output.terminalRows ?? terminalRows)

        columns = nextColumns
        terminalRows = nextRows

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
        if output.sequence < lastSequence {
            mainRows.removeAll(keepingCapacity: true)
        }

        screenMode = .main
        lastSequence = output.sequence

        for row in output.rows where row.row >= 0 {
            mainRows[row.row] = row.text
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
            alternateRows[row.row] = row.text
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
        let rows = renderedRows()
        return TerminalMirrorSnapshot(
            sequence: lastSequence,
            screenMode: screenMode,
            columns: columns,
            terminalRows: terminalRows,
            rows: rows
        )
    }

    private func renderedRows() -> [TerminalMirrorRow] {
        switch screenMode {
        case .main:
            return mainRows.keys.sorted().map {
                TerminalMirrorRow(id: $0, text: mainRows[$0] ?? "")
            }
        case .alternate:
            guard terminalRows > 0 else {
                return []
            }
            return (0..<terminalRows).map {
                TerminalMirrorRow(id: $0, text: alternateRows[$0] ?? "")
            }
        }
    }
}

struct TerminalMirrorView: View {
    let snapshot: TerminalMirrorSnapshot
    let session: TerminalRemoteProtocol.Session?

    @State private var pendingScrollWorkItem: DispatchWorkItem?

    private let bottomID = "terminal-mirror-bottom"
    private let characterWidth: CGFloat = 6.9
    private let lineHeight: CGFloat = 14.5

    var body: some View {
        VStack(spacing: 0) {
            mirrorHeader
            Divider()
            mirrorGrid
        }
        .background(Color(uiColor: .systemBackground))
    }

    private var mirrorHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.terminal")
                .font(.subheadline)
                .foregroundStyle(Color.cyan)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(session?.title ?? "Terminal")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                UIPasteboard.general.string = snapshot.rows.map(\.text).joined(separator: "\n")
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(snapshot.rows.isEmpty)
            .accessibilityLabel("Copy terminal text")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var mirrorGrid: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal], showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if snapshot.rows.isEmpty {
                        ContentUnavailableView("No Terminal Output", systemImage: "terminal")
                            .frame(minWidth: 320, maxWidth: .infinity, minHeight: 180)
                    } else {
                        ForEach(snapshot.rows) { row in
                            Text(row.text.isEmpty ? " " : row.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color(uiColor: .label))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .id(row.id)
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .frame(minWidth: gridWidth, minHeight: gridHeight, alignment: .topLeading)
                .padding(6)
            }
            .background(Color(uiColor: .systemBackground))
            .onAppear {
                scheduleScrollToBottom(proxy, delay: 0)
            }
            .onChange(of: snapshot.sequence) { _, _ in
                scheduleScrollToBottom(proxy, delay: 0.04)
            }
            .onDisappear {
                pendingScrollWorkItem?.cancel()
                pendingScrollWorkItem = nil
            }
        }
    }

    private var subtitle: String {
        let mode = snapshot.isAlternateScreen ? "alternate" : "main"
        return "\(snapshot.columns)x\(snapshot.terminalRows) - \(mode)"
    }

    private var gridWidth: CGFloat {
        CGFloat(max(snapshot.columns, 1)) * characterWidth
    }

    private var gridHeight: CGFloat {
        CGFloat(max(snapshot.terminalRows, 1)) * lineHeight
    }

    private func scheduleScrollToBottom(_ proxy: ScrollViewProxy, delay: TimeInterval) {
        pendingScrollWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            proxy.scrollTo(bottomID, anchor: .bottomLeading)
        }
        pendingScrollWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}
