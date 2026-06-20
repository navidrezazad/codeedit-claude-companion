//
//  MarkdownStreamAgentView.swift
//  CodeEditRemoteiOS
//
//  Created by Claude on 6/12/26.
//

import SwiftUI

struct MarkdownStreamAgentView: View {
    let document: TerminalRemoteProtocol.MarkdownStreamDocument?
    let status: String
    let session: TerminalRemoteProtocol.Session?
    let isActive: Bool
    let onTrigger: () -> Void
    let onRewrite: (String) -> Void
    let onStop: () -> Void

    @State private var rewritePrompt = ""
    @State private var showsRewritePanel = false

    var body: some View {
        VStack(spacing: 0) {
            streamHeader

            if showsRewritePanel {
                Divider()
                rewritePanel
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Divider()

            Group {
                if let document {
                    MarkdownWebView(markdown: document.markdown, scrollsToBottom: true)
                } else {
                    ContentUnavailableView("No Markdown Stream", systemImage: "doc.richtext")
                        .frame(maxWidth: .infinity, minHeight: 320)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
    }

    private var streamHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: isActive ? "dot.radiowaves.left.and.right" : "doc.richtext")
                .font(.subheadline)
                .foregroundStyle(isActive ? Color.green : Color.accentColor)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(session?.title ?? "Markdown Stream")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isActive {
                Button {
                    onTrigger()
                } label: {
                    Image(systemName: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel("Update Markdown stream")

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showsRewritePanel.toggle()
                    }
                } label: {
                    Image(systemName: showsRewritePanel ? "chevron.up" : "square.and.pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(showsRewritePanel ? "Hide rewrite controls" : "Show rewrite controls")

                Button {
                    onStop()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Stop Markdown stream")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var rewritePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $rewritePrompt)
                .frame(minHeight: 44, maxHeight: 64)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if rewritePrompt.isEmpty {
                        Text("Rewrite the whole Markdown file...")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }

            HStack {
                Text("Claude Opus 4.8 - medium - replaces full stream file")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                Button {
                    onRewrite(rewritePrompt)
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showsRewritePanel = false
                    }
                } label: {
                    Label("Rewrite MD", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(rewritePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(uiColor: .systemBackground))
    }

    private var subtitle: String {
        if let path = document?.path, !path.isEmpty {
            return URL(fileURLWithPath: path).lastPathComponent
        }

        return status
    }
}
