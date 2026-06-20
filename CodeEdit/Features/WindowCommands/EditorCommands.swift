//
//  EditorCommands.swift
//  CodeEdit
//
//  Created by Bogdan Belogurov on 21/05/2025.
//

import SwiftUI
import CodeEditKit

struct EditorCommands: Commands {

    @UpdatingWindowController var windowController: CodeEditWindowController?
    private var editor: Editor? {
        windowController?.workspace?.editorManager?.activeEditor
    }

    private var selectedMarkdownTab: Editor.Tab? {
        guard let tab = editor?.selectedTab, tab.file.url.isMarkdownDocument else {
            return nil
        }

        return tab
    }

    var body: some Commands {
        CommandMenu("Editor") {
            Menu("Structure") {
                Button("Move line up") {
                    editor?.selectedTab?.rangeTranslator.moveLinesUp()
                }
                .keyboardShortcut("[", modifiers: [.command, .option])

                Button("Move line down") {
                    editor?.selectedTab?.rangeTranslator.moveLinesDown()
                }
                .keyboardShortcut("]", modifiers: [.command, .option])
            }

            Menu("Markdown") {
                Button("Show Source") {
                    editor?.selectMarkdownPresentation(.source)
                }
                .disabled(selectedMarkdownTab == nil || selectedMarkdownTab?.presentation == .source)

                Button("Show Preview") {
                    editor?.selectMarkdownPresentation(.markdownPreview)
                }
                .disabled(selectedMarkdownTab == nil || selectedMarkdownTab?.presentation == .markdownPreview)

                Divider()

                Button("Open Source and Preview Tabs") {
                    editor?.openMarkdownPairForSelectedFile()
                }
                .disabled(selectedMarkdownTab == nil)

                Button("Close Source and Preview Tabs") {
                    editor?.closeMarkdownPairForSelectedFile()
                }
                .disabled(selectedMarkdownTab == nil)

                Divider()

                Button("Export Preview as HTML...") {
                    exportSelectedMarkdown()
                }
                .disabled(selectedMarkdownTab == nil)
            }
        }
    }

    private func exportSelectedMarkdown() {
        guard let tab = selectedMarkdownTab else {
            return
        }

        let markdown = tab.file.fileDocument?.content?.string
            ?? (try? String(contentsOf: tab.file.url, encoding: .utf8))
            ?? ""

        MarkdownPreviewExporter.exportHTML(markdown: markdown, sourceURL: tab.file.url)
    }
}
