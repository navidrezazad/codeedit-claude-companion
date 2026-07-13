//
//  EditorStateRestorationTests.swift
//  CodeEditTests
//
//  Created by Khan Winter on 7/3/25.
//

import Testing
import Foundation
import OrderedCollections
@testable import CodeEdit

@Suite
struct EditorStateRestorationTests {
    private struct LegacyEditorState: Codable {
        let tabs: [URL]
        let selectedTab: URL
        let id: UUID
    }

    @Test
    func preservesMarkdownTabPresentations() throws {
        let url = URL(fileURLWithPath: "/tmp/readme.md")
        let file = CEWorkspaceFile(url: url)
        let source = EditorInstance(workspace: nil, file: file, presentation: .source)
        let preview = EditorInstance(workspace: nil, file: file, presentation: .markdownPreview)
        let editor = Editor(files: OrderedSet([source, preview]), selectedTab: preview)

        let restored = try JSONDecoder().decode(Editor.self, from: JSONEncoder().encode(editor))

        #expect(restored.tabs.map(\.presentation) == [.source, .markdownPreview])
        #expect(restored.selectedTab?.presentation == .markdownPreview)
    }

    @Test
    func legacyMarkdownTabsRestoreAsPreview() throws {
        let url = URL(fileURLWithPath: "/tmp/readme.md")
        let legacyState = LegacyEditorState(tabs: [url], selectedTab: url, id: UUID())

        let restored = try JSONDecoder().decode(Editor.self, from: JSONEncoder().encode(legacyState))

        #expect(restored.tabs.first?.presentation == .markdownPreview)
        #expect(restored.selectedTab?.presentation == .markdownPreview)
    }

    @Test
    func createsDatabase() throws {
        try withTempDir { dir in
            let url = dir.appending(path: "database.db")
            _ = try EditorStateRestoration(url)
            #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        }
    }

    @Test
    func savesAndRetrievesStateForFile() throws {
        try withTempDir { dir in
            let url = dir.appending(path: "database.db")
            let restoration = try EditorStateRestoration(url)

            // Update some state
            restoration.updateRestorationState(
                for: dir.appending(path: "file.txt"),
                data: .init(cursorPositions: [], scrollPosition: .zero)
            )

            // Retrieve it
            #expect(
                restoration.restorationState(for: dir.appending(path: "file.txt"))
                == EditorStateRestoration.StateRestorationData(cursorPositions: [], scrollPosition: .zero)
            )
        }
    }

    @Test
    func savesScrollPosition() throws {
        try withTempDir { dir in
            let url = dir.appending(path: "database.db")
            let restoration = try EditorStateRestoration(url)

            // Update some state
            restoration.updateRestorationState(
                for: dir.appending(path: "file.txt"),
                data: .init(cursorPositions: [], scrollPosition: CGPoint(x: 100, y: 100))
            )

            // Retrieve it
            #expect(
                restoration.restorationState(for: dir.appending(path: "file.txt"))
                == EditorStateRestoration.StateRestorationData(
                    cursorPositions: [],
                    scrollPosition: CGPoint(x: 100, y: 100)
                )
            )
        }
    }

    @Test
    func clearsCorruptedDatabase() throws {
        try withTempDir { dir in
            let url = dir.appending(path: "database.db")
            try "bad data".write(to: url, atomically: true, encoding: .utf8)
            // This will throw if it can't connect to the database.
            _ = try EditorStateRestoration(url)
        }
    }
}
