//
//  TerminalMirrorView.swift
//  CodeEditRemoteiOS
//
//  Created by Claude on 6/13/26.
//

import SwiftUI
import UIKit

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

struct TerminalMirrorView: View {
    let snapshot: TerminalMirrorSnapshot
    let session: TerminalRemoteProtocol.Session?

    @State private var pendingScrollWorkItem: DispatchWorkItem?

    private let bottomID = "terminal-mirror-bottom"
    private let lineHeight: CGFloat = 14.5
    private let fontSize: CGFloat = 11

    private var characterWidth: CGFloat {
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return ("M" as NSString).size(withAttributes: [.font: font]).width
    }

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
                            terminalRow(row)
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

    private func terminalRow(_ row: TerminalMirrorRow) -> some View {
        ZStack(alignment: .leading) {
            Text(attributedRow(row))
                .font(.system(size: fontSize, design: .monospaced))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            if let cursor = snapshot.cursor,
               cursor.isVisible,
               cursor.row == row.id {
                cursorIndicator(cursor)
                    .offset(x: CGFloat(cursor.column) * characterWidth)
            }
        }
        .frame(height: lineHeight, alignment: .leading)
    }

    @ViewBuilder
    private func cursorIndicator(_ cursor: TerminalRemoteProtocol.ProjectedCursor) -> some View {
        switch cursor.shape {
        case .block:
            Rectangle()
                .fill(Color.cyan.opacity(0.46))
                .frame(width: characterWidth, height: lineHeight)
        case .underline:
            Rectangle()
                .fill(Color.cyan.opacity(0.9))
                .frame(width: characterWidth, height: 2)
                .offset(y: (lineHeight / 2) - 1)
        case .bar:
            Rectangle()
                .fill(Color.cyan.opacity(0.9))
                .frame(width: 1.5, height: lineHeight)
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
