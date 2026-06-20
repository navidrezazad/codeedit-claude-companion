//
//  MarkdownFileExtensions.swift
//  CodeEdit
//
//  Created by Claude on 01/05/2026.
//

import Foundation

enum MarkdownFileExtensions {
    static let supported: Set<String> = [
        "markdown",
        "md",
        "mdown",
        "mdwn",
        "mkd",
        "mkdn",
        "mdx",
        "qmd",
        "rmd"
    ]
}

extension URL {
    var isMarkdownDocument: Bool {
        MarkdownFileExtensions.supported.contains(pathExtension.lowercased())
    }
}
