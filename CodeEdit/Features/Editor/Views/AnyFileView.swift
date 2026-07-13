//
//  AnyFileView.swift
//  CodeEdit
//
//  Created by Paul Ebose on 2024/5/9.
//

import SwiftUI
import QuickLookUI

/// A view for previewing any kind of file.
///
/// ```swift
/// AnyFileView(fileURL)
/// ```
/// If the file cannot be previewed, a file icon thumbnail is shown instead.
struct AnyFileView: NSViewRepresentable {

    /// URL of the file to preview. You can pass in any file type.
    private let fileURL: NSURL
    private let allowsCopyingImage: Bool

    init(_ fileURL: URL, allowsCopyingImage: Bool = false) {
        self.fileURL = fileURL as NSURL
        self.allowsCopyingImage = allowsCopyingImage
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(fileURL: fileURL as URL)
    }

    func makeNSView(context: Context) -> ContextMenuPreviewView {
        let qlPreviewView = ContextMenuPreviewView()
        qlPreviewView.previewItem = fileURL
        qlPreviewView.shouldCloseWithWindow = false // Temp work around for something more reasonable.
        configureContextMenu(for: qlPreviewView, coordinator: context.coordinator)
        return qlPreviewView
    }

    func updateNSView(_ qlPreviewView: ContextMenuPreviewView, context: Context) {
        context.coordinator.fileURL = fileURL as URL
        qlPreviewView.previewItem = fileURL
        configureContextMenu(for: qlPreviewView, coordinator: context.coordinator)
    }

    private func configureContextMenu(for previewView: ContextMenuPreviewView, coordinator: Coordinator) {
        previewView.usesCustomContextMenu = allowsCopyingImage
        previewView.menu = allowsCopyingImage ? coordinator.copyImageMenu : nil
    }

    // Temp work around for something more reasonable.
    // Open quickly should empty the results (but cache the query) when closed,
    // and then re-search or recompute the results when re-opened.
    static func dismantleNSView(_ qlPreviewView: ContextMenuPreviewView, coordinator: Coordinator) {
        qlPreviewView.close()
    }

    final class Coordinator: NSObject {
        var fileURL: URL

        lazy var copyImageMenu: NSMenu = {
            let menu = NSMenu()
            let item = NSMenuItem(
                title: "Copy Image",
                action: #selector(copyImage(_:)),
                keyEquivalent: ""
            )
            item.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy Image")
            item.target = self
            menu.addItem(item)
            return menu
        }()

        init(fileURL: URL) {
            self.fileURL = fileURL
        }

        @objc
        private func copyImage(_ sender: NSMenuItem) {
            ImagePasteboardWriter.copyImage(at: fileURL)
        }
    }
}

final class ContextMenuPreviewView: QLPreviewView {
    var usesCustomContextMenu = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard usesCustomContextMenu,
              bounds.contains(point),
              let event = NSApp.currentEvent,
              isContextClick(event) else {
            return super.hitTest(point)
        }
        return self
    }

    override func rightMouseDown(with event: NSEvent) {
        guard usesCustomContextMenu, let menu else {
            super.rightMouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func mouseDown(with event: NSEvent) {
        guard usesCustomContextMenu,
              event.modifierFlags.contains(.control),
              let menu else {
            super.mouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func isContextClick(_ event: NSEvent) -> Bool {
        event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
    }
}
