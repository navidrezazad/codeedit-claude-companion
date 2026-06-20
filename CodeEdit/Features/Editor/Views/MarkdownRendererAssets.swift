//
//  MarkdownRendererAssets.swift
//  CodeEdit
//
//  Created by Claude on 01/05/2026.
//

import Foundation

// Vendored from jsDelivr npm distributions so Markdown preview works offline.
// marked: MIT, DOMPurify: Apache-2.0/MPL-2.0, KaTeX: MIT.
enum MarkdownRendererAssets {
    static let markedJS = loadResource("marked.min", fileExtension: "js")
    static let domPurifyJS = loadResource("purify.min", fileExtension: "js")
    static let katexCSS = loadResource("katex.min", fileExtension: "css")
    static let katexJS = loadResource("katex.min", fileExtension: "js")

    private static func loadResource(_ name: String, fileExtension: String) -> String {
        guard let url = bundledResourceURL(name, fileExtension: fileExtension) ?? sourceTreeResourceURL(
            name,
            fileExtension: fileExtension
        ) else {
            assertionFailure("Missing Markdown renderer resource: \(name).\(fileExtension)")
            return ""
        }

        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            assertionFailure("Could not load Markdown renderer resource \(url.path): \(error)")
            return ""
        }
    }

    private static func bundledResourceURL(_ name: String, fileExtension: String) -> URL? {
        let bundle = Bundle.main
        let subdirectories = [
            nil,
            "MarkdownRenderer",
            "Resources/MarkdownRenderer",
            "Features/Editor/Resources/MarkdownRenderer"
        ]

        for subdirectory in subdirectories {
            if let url = bundle.url(forResource: name, withExtension: fileExtension, subdirectory: subdirectory) {
                return url
            }
        }

        return nil
    }

    private static func sourceTreeResourceURL(_ name: String, fileExtension: String) -> URL? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources/MarkdownRenderer/\(name).\(fileExtension)")
            .standardizedFileURL

        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
