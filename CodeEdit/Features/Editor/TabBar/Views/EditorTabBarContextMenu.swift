//
//  EditorTabBarContextMenu.swift
//  CodeEdit
//
//  Created by Khan Winter on 6/4/22.
//

import SwiftUI
import Foundation

extension View {
    func tabBarContextMenu(item: Editor.Tab, isTemporary: Bool) -> some View {
        modifier(EditorTabBarContextMenu(item: item, isTemporary: isTemporary))
    }
}

struct EditorTabBarContextMenu: ViewModifier {
    init(
        item: Editor.Tab,
        isTemporary: Bool
    ) {
        self.item = item
        self.isTemporary = isTemporary
    }

    @EnvironmentObject var workspace: WorkspaceDocument

    @EnvironmentObject var tabs: Editor

    @Environment(\.splitEditor)
    var splitEditor

    private var item: Editor.Tab
    private var isTemporary: Bool

    // swiftlint:disable:next function_body_length
    func body(content: Content) -> some View {
        content.contextMenu(menuItems: {
            Group {
                Button("Close Tab") {
                    withAnimation {
                        tabs.closeTab(tab: item)
                    }
                }
                .keyboardShortcut("w", modifiers: [.command])

                if item.file.url.isMarkdownDocument {
                    Button("Close Source and Preview Tabs") {
                        withAnimation {
                            tabs.closeTab(file: item.file)
                        }
                    }
                }

                Button("Close Other Tabs") {
                    withAnimation {
                        Array(tabs.tabs).forEach { tab in
                            if tab != item {
                                tabs.closeTab(tab: tab)
                            }
                        }
                    }
                }

                Button("Close Tabs to the Right") {
                    withAnimation {
                        if let index = tabs.tabs.firstIndex(of: item), index + 1 < tabs.tabs.count {
                            Array(tabs.tabs[(index + 1)...]).forEach { tab in
                                tabs.closeTab(tab: tab)
                            }
                        }
                    }
                }
                // Disable this option when current tab is the last one.
                .disabled(tabs.tabs.last == item)

                Button("Close All") {
                    withAnimation {
                        Array(tabs.tabs).forEach { tab in
                            tabs.closeTab(tab: tab)
                        }
                    }
                }

                if isTemporary {
                    Button("Keep Open") {
                        tabs.temporaryTab = nil
                    }
                }
            }

            Divider()

            Group {
                Button("Copy Path") {
                    copyPath(item: item.file)
                }

                Button("Copy Relative Path") {
                    copyRelativePath(item: item.file)
                }

                if item.file.url.isMarkdownDocument {
                    Button("Export Preview as HTML...") {
                        exportMarkdownPreview()
                    }
                }
            }

            Divider()

            Group {
                Button("Show in Finder") {
                    item.file.showInFinder()
                }

                Button("Reveal in Project Navigator") {
                    workspace.listenerModel.highlightedFileItem = item.file
                }

                Button("Open in New Window") {

                }
                .disabled(true)
            }

            Divider()

            Button("Split Up") {
                moveToNewSplit(.top)
            }
            Button("Split Down") {
                moveToNewSplit(.bottom)
            }
            Button("Split Left") {
                moveToNewSplit(.leading)
            }
            Button("Split Right") {
                moveToNewSplit(.trailing)
            }
        })
    }

    // MARK: - Actions

    /// Copies the absolute path of the given `FileItem`
    /// - Parameter item: The `FileItem` to use.
    private func copyPath(item: CEWorkspaceFile) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.url.standardizedFileURL.path, forType: .string)
    }

    func moveToNewSplit(_ edge: Edge) {
        let newEditor = Editor(files: [item], workspace: workspace)
        splitEditor(edge, newEditor)
        tabs.closeTab(tab: item)
        workspace.editorManager?.activeEditor = newEditor
    }

    /// Copies the relative path from the workspace folder to the given file item to the pasteboard.
    /// - Parameter item: The `FileItem` to use.
    private func copyRelativePath(item: CEWorkspaceFile) {
        guard let rootPath = workspace.workspaceFileManager?.folderUrl else {
            return
        }
        let destinationComponents = item.url.standardizedFileURL.pathComponents
        let baseComponents = rootPath.standardizedFileURL.pathComponents

        // Find common prefix length
        var prefixCount = 0
        while prefixCount < min(destinationComponents.count, baseComponents.count)
                && destinationComponents[prefixCount] == baseComponents[prefixCount] {
            prefixCount += 1
        }
        // Build the relative path
        let upPath = String(repeating: "../", count: baseComponents.count - prefixCount)
        let downPath = destinationComponents[prefixCount...].joined(separator: "/")

        // Copy it to the clipboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(upPath + downPath, forType: .string)
    }

    private func exportMarkdownPreview() {
        let markdown = item.file.fileDocument?.content?.string
            ?? (try? String(contentsOf: item.file.url, encoding: .utf8))
            ?? ""

        MarkdownPreviewExporter.exportHTML(markdown: markdown, sourceURL: item.file.url)
    }
}
