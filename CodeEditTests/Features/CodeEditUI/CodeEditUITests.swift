//
//  UnitTests.swift
//  CodeEditModules/CodeEditUITests
//
//  Created by Lukas Pistrol on 19.04.22.
//

@testable import CodeEdit
import Foundation
import QuickLookUI
import SnapshotTesting
import SwiftUI
import XCTest

final class ImageFileViewTests: XCTestCase {

    func testImagePreviewFillsAvailableArea() throws {
        try withTempDir { directory in
            let imageURL = directory.appending(path: "image.png")
            try writeTestImage(to: imageURL)

            let hosting = NSHostingView(rootView: ImageFileView(imageURL))
            hosting.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            hosting.layoutSubtreeIfNeeded()

            let preview = try XCTUnwrap(findSubview(of: QLPreviewView.self, in: hosting))
            XCTAssertEqual(preview.frame.width, 800, accuracy: 1)
            XCTAssertEqual(preview.frame.height, 600, accuracy: 1)
        }
    }

    func testImagePreviewProvidesCopyImageContextMenu() throws {
        try withTempDir { directory in
            let imageURL = directory.appending(path: "image.png")
            try writeTestImage(to: imageURL)

            let hosting = NSHostingView(rootView: ImageFileView(imageURL))
            hosting.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
            hosting.layoutSubtreeIfNeeded()

            let preview = try XCTUnwrap(findSubview(of: QLPreviewView.self, in: hosting))
            let copyItem = try XCTUnwrap(preview.menu?.items.first { $0.title == "Copy Image" })
            XCTAssertNotNil(copyItem.action)
            XCTAssertNotNil(copyItem.target)
        }
    }

    func testCopyImageWritesReadableImageToPasteboard() throws {
        try withTempDir { directory in
            let imageURL = directory.appending(path: "image.png")
            try writeTestImage(to: imageURL)
            let pasteboard = NSPasteboard(name: .init("ImageFileViewTests.\(UUID().uuidString)"))
            defer { pasteboard.clearContents() }

            XCTAssertTrue(ImagePasteboardWriter.copyImage(at: imageURL, to: pasteboard))
            XCTAssertNotNil(NSImage(pasteboard: pasteboard))
        }
    }

    private func writeTestImage(to imageURL: URL) throws {
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 10,
                pixelsHigh: 10,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: imageURL)
    }

    private func findSubview<ViewType: NSView>(of type: ViewType.Type, in view: NSView) -> ViewType? {
        if let view = view as? ViewType {
            return view
        }

        return view.subviews.lazy.compactMap { self.findSubview(of: type, in: $0) }.first
    }
}

final class CodeEditUIUnitTests: XCTestCase {

    // MARK: Help Button

    func testHelpButtonLight() throws {
        let view = HelpButton(action: {})
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: .init(width: 40, height: 40))
        hosting.appearance = .init(named: .aqua)
        assertSnapshot(matching: hosting, as: .image(size: .init(width: 40, height: 40)))
    }

    func testHelpButtonDark() throws {
        let view = HelpButton(action: {})
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = .init(named: .darkAqua)
        hosting.frame = CGRect(origin: .zero, size: .init(width: 40, height: 40))
        assertSnapshot(matching: hosting, as: .image)
    }

    // MARK: Segmented Control

    func testSegmentedControlLight() throws {
        let view = SegmentedControl(.constant(0), options: ["Opt1", "Opt2"])
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = .init(named: .aqua)
        hosting.frame = CGRect(origin: .zero, size: .init(width: 100, height: 30))
        assertSnapshot(matching: hosting, as: .image)
    }

    func testSegmentedControlDark() throws {
        let view = SegmentedControl(.constant(0), options: ["Opt1", "Opt2"])
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = .init(named: .darkAqua)
        hosting.frame = CGRect(origin: .zero, size: .init(width: 100, height: 30))
        assertSnapshot(matching: hosting, as: .image)
    }

    func testSegmentedControlProminentLight() throws {
        let view = SegmentedControl(.constant(0), options: ["Opt1", "Opt2"], prominent: true)
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = .init(named: .aqua)
        hosting.frame = CGRect(origin: .zero, size: .init(width: 100, height: 30))
        assertSnapshot(matching: hosting, as: .image)
    }

    func testSegmentedControlProminentDark() throws {
        let view = SegmentedControl(.constant(0), options: ["Opt1", "Opt2"], prominent: true)
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = .init(named: .darkAqua)
        hosting.frame = CGRect(origin: .zero, size: .init(width: 100, height: 30))
        assertSnapshot(matching: hosting, as: .image)
    }

    // MARK: EffectView

    func testEffectViewLight() throws {
        let view = EffectView()
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = .init(named: .aqua)
        hosting.frame = CGRect(origin: .zero, size: .init(width: 20, height: 20))
        assertSnapshot(matching: hosting, as: .image)
    }

    func testEffectViewDark() throws {
        let view = EffectView()
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = .init(named: .darkAqua)
        hosting.frame = CGRect(origin: .zero, size: .init(width: 20, height: 20))
        assertSnapshot(matching: hosting, as: .image)
    }

    // MARK: ToolbarBranchPicker

    func testBranchPickerLight() throws {
        let view = ToolbarBranchPicker(
            workspaceFileManager: nil
        )
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = .init(named: .aqua)
        hosting.frame = CGRect(origin: .zero, size: .init(width: 100, height: 50))
        assertSnapshot(matching: hosting, as: .image)
    }

    func testBranchPickerDark() throws {
        let view = ToolbarBranchPicker(
            workspaceFileManager: nil
        )
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = .init(named: .darkAqua)
        hosting.frame = CGRect(origin: .zero, size: .init(width: 100, height: 50))
        assertSnapshot(matching: hosting, as: .image)
    }
}
