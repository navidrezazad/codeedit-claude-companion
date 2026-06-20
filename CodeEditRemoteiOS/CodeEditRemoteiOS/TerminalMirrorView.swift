//
//  TerminalMirrorView.swift
//  CodeEditRemoteiOS
//
//  Created by Claude on 6/13/26.
//

import SwiftUI
import UIKit

/// A styled run of characters within a mirrored terminal row. Colors are packed `0xRRGGBB`
/// (`nil` = terminal default); `style` is an `OR` of `TerminalRemoteProtocol.SpanStyle` bits.
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

/// Fixed dark-terminal palette so the mirror reads like a real terminal regardless of the iPhone's
/// light/dark appearance. The default colors match `TerminalRemoteProtocol`'s shared constants.
enum TerminalPalette {
    static let background = Color(packedRGB: TerminalRemoteProtocol.defaultBackgroundRGB)
    static let defaultForeground = Color(packedRGB: TerminalRemoteProtocol.defaultForegroundRGB)
}

extension Color {
    init(packedRGB: Int) {
        self.init(
            .sRGB,
            red: Double((packedRGB >> 16) & 0xFF) / 255.0,
            green: Double((packedRGB >> 8) & 0xFF) / 255.0,
            blue: Double(packedRGB & 0xFF) / 255.0
        )
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

struct TerminalMirrorView: View {
    let snapshot: TerminalMirrorSnapshot
    let session: TerminalRemoteProtocol.Session?

    @State private var pendingScrollWorkItem: DispatchWorkItem?

    private let bottomID = "terminal-mirror-bottom"
    private let characterWidth: CGFloat = 6.9
    private let lineHeight: CGFloat = 14.5
    private let fontSize: CGFloat = 11

    var body: some View {
        VStack(spacing: 0) {
            mirrorHeader
            Divider()
            mirrorGrid
                .environment(\.colorScheme, .dark)
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
                            Text(attributedRow(row))
                                .font(.system(size: fontSize, design: .monospaced))
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
            .background(TerminalPalette.background)
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

    /// Builds a styled `AttributedString` for a row. Runs carry their own font/colors, so the whole
    /// row renders as a single `Text` view, keeping the `LazyVStack` cheap and smooth.
    private func attributedRow(_ row: TerminalMirrorRow) -> AttributedString {
        var result = AttributedString()

        for segment in row.segments where !segment.text.isEmpty {
            var piece = AttributedString(segment.text)
            piece.mergeAttributes(container(for: segment))
            result.append(piece)
        }

        if result.characters.isEmpty {
            var blank = AttributedString(" ")
            blank.font = .system(size: fontSize, design: .monospaced)
            blank.foregroundColor = TerminalPalette.defaultForeground
            return blank
        }

        return result
    }

    private func container(for segment: TerminalMirrorSegment) -> AttributeContainer {
        var container = AttributeContainer()

        var font = Font.system(size: fontSize, design: .monospaced)
        if segment.style & TerminalRemoteProtocol.SpanStyle.bold != 0 {
            font = font.weight(.bold)
        }
        if segment.style & TerminalRemoteProtocol.SpanStyle.italic != 0 {
            font = font.italic()
        }
        container.font = font

        let isDim = segment.style & TerminalRemoteProtocol.SpanStyle.dim != 0
        let foreground = segment.foreground.map(Color.init(packedRGB:)) ?? TerminalPalette.defaultForeground
        container.foregroundColor = isDim ? foreground.opacity(0.6) : foreground

        if let background = segment.background {
            container.backgroundColor = Color(packedRGB: background)
        }

        if segment.style & TerminalRemoteProtocol.SpanStyle.underline != 0 {
            container.underlineStyle = .single
        }
        if segment.style & TerminalRemoteProtocol.SpanStyle.strikethrough != 0 {
            container.strikethroughStyle = .single
        }

        return container
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
