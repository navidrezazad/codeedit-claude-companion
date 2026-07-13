//
//  ImageFileView.swift
//  CodeEdit
//
//  Created by Paul Ebose on 2024/5/9.
//

import SwiftUI

/// A view for previewing an image in the full available editor area.
///
/// It receives a URL to an image file and attempts to preview it.
///
/// ```swift
/// ImageFileView(imageURL)
/// ```
/// If the preview image cannot be created, it shows a  *"Cannot preview image"* text.
struct ImageFileView: View {

    /// URL of the image you want to preview.
    private let imageURL: URL

    init(_ imageURL: URL) {
        self.imageURL = imageURL
    }

    var body: some View {
        if NSImage(contentsOf: imageURL) != nil {
            GeometryReader { proxy in
                AnyFileView(imageURL)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        } else {
            Text("Cannot preview image")
        }
    }

}
