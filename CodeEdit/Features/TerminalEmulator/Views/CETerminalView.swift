//
//  CETerminalView.swift
//  CodeEdit
//
//  Created by Khan Winter on 7/11/25.
//

import SwiftTerm
import AppKit

/// # Please see dev note in ``CELocalShellTerminalView``!

private let terminalFollowScrollThreshold = 0.985
private let terminalBackwardDelete = String(NSEvent.SpecialKey.delete.unicodeScalar)
private let terminalKillToBeginningOfLine: [UInt8] = [0x15]
private let terminalKillPreviousWord: [UInt8] = [0x1b, 0x7f]
private let terminalInteractiveRedrawWindow: TimeInterval = 0.35

class CETerminalView: TerminalView {
    var performanceIdentifier: UUID?
    private(set) var mirroredCursorIsVisible = true
    private(set) var mirroredCursorStyle = CursorStyle.blinkBlock
    private var userIsReadingScrollback = false
    private var isForwardingFrameToSwiftTerm = false
    private var isSettlingAttachLayout = false
    private var pendingAttachLayoutWorkItem: DispatchWorkItem?
    private var interactiveRedrawDeadline = Date.distantPast
    private var pendingInteractiveRedrawWorkItem: DispatchWorkItem?

    func noteInteractiveInput(_ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty, !bytes.contains(0x0a), !bytes.contains(0x0d) else {
            return
        }

        interactiveRedrawDeadline = Date().addingTimeInterval(terminalInteractiveRedrawWindow)
    }

    func guaranteeInteractiveOutputDisplay() {
        guard Date() <= interactiveRedrawDeadline,
              pendingInteractiveRedrawWorkItem == nil,
              superview != nil,
              window != nil else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }

            self.pendingInteractiveRedrawWorkItem = nil
            guard self.superview != nil, self.window != nil else {
                return
            }

            // SwiftTerm normally invalidates only its changed rows. A stale row/frame mapping after
            // reattachment can miss that rectangle, so guarantee one visible redraw for typed input.
            self.setNeedsDisplay(self.bounds)
            self.displayIfNeeded()
        }
        pendingInteractiveRedrawWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(17), execute: workItem)
    }

    func prepareForAttachmentLayout() {
        pendingAttachLayoutWorkItem?.cancel()
        pendingAttachLayoutWorkItem = nil
        isSettlingAttachLayout = true

        if superview != nil {
            scheduleAttachLayoutFinalization()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != .zero {
            if isForwardingFrameToSwiftTerm {
                super.setFrameSize(newSize)
                return
            }

            preservingScrollPositionIfNeeded {
                applyFrameThroughSwiftTerm(CGRect(origin: super.frame.origin, size: newSize))
            }
        }
    }

    override open var frame: CGRect {
        get {
            super.frame
        }
        set {
            if newValue.size != .zero {
                if isForwardingFrameToSwiftTerm {
                    super.setFrameOrigin(newValue.origin)
                    super.setFrameSize(newValue.size)
                    return
                }

                preservingScrollPositionIfNeeded {
                    applyFrameThroughSwiftTerm(newValue)
                }
            }
        }
    }

    private func applyFrameThroughSwiftTerm(_ newFrame: CGRect, allowHeightOnlyResize: Bool = true) {
        if isSettlingAttachLayout {
            applyFrameWithoutTerminalResize(newFrame)
            scheduleAttachLayoutFinalization()
            return
        }

        isForwardingFrameToSwiftTerm = true
        defer {
            isForwardingFrameToSwiftTerm = false
        }

        if allowHeightOnlyResize, let size = projectedTerminalSize(for: newFrame.size) {
            let widthDelta = abs(newFrame.size.width - super.frame.size.width)
            let widthIsEffectivelyUnchanged = widthDelta < terminalCellSize().width
            if widthIsEffectivelyUnchanged, terminal.rows != size.rows {
                applyHeightOnlyFrame(newFrame, rows: size.rows)
                return
            }
        }

        super.frame = newFrame
    }

    func terminalSizeDidChange(columns: Int, rows: Int, frame: CGRect) {}

    private func applyFrameWithoutTerminalResize(_ newFrame: CGRect) {
        isForwardingFrameToSwiftTerm = true
        defer {
            isForwardingFrameToSwiftTerm = false
        }

        super.setFrameOrigin(newFrame.origin)
        super.setFrameSize(newFrame.size)
        needsDisplay = true
    }

    private func scheduleAttachLayoutFinalization() {
        pendingAttachLayoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.finalizeAttachLayout()
        }
        pendingAttachLayoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80), execute: workItem)
    }

    private func finalizeAttachLayout() {
        pendingAttachLayoutWorkItem = nil

        guard terminal != nil else {
            isSettlingAttachLayout = false
            return
        }

        guard superview != nil else {
            return
        }

        guard frame.size != .zero else {
            isSettlingAttachLayout = false
            return
        }

        isSettlingAttachLayout = false

        guard let size = projectedTerminalSize(for: frame.size) else {
            terminal.refresh(startRow: 0, endRow: max(0, terminal.rows - 1))
            needsDisplay = true
            return
        }

        if terminal.cols != size.columns {
            preservingScrollPositionIfNeeded {
                applyFrameThroughSwiftTerm(frame, allowHeightOnlyResize: false)
            }
        } else if terminal.rows != size.rows {
            preservingScrollPositionIfNeeded {
                applyHeightOnlyFrame(frame, rows: size.rows)
            }
        } else {
            terminal.refresh(startRow: 0, endRow: max(0, terminal.rows - 1))
            needsDisplay = true
        }
    }

    private func applyHeightOnlyFrame(_ newFrame: CGRect, rows: Int) {
        super.setFrameOrigin(newFrame.origin)
        super.setFrameSize(newFrame.size)

        guard terminal.rows != rows else {
            needsDisplay = true
            return
        }

        terminal.resize(cols: terminal.cols, rows: rows)
        terminalSizeDidChange(columns: terminal.cols, rows: terminal.rows, frame: newFrame)
        terminal.refresh(startRow: 0, endRow: max(0, terminal.rows - 1))
        needsDisplay = true
    }

    private func projectedTerminalSize(for size: CGSize) -> (columns: Int, rows: Int)? {
        guard terminal != nil, size.width > 0, size.height > 0 else {
            return nil
        }

        let cellSize = terminalCellSize()
        let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let effectiveWidth = max(0, size.width - scrollerWidth)
        return (
            columns: max(2, Int(effectiveWidth / cellSize.width)),
            rows: max(1, Int(size.height / cellSize.height))
        )
    }

    private func terminalCellSize() -> CGSize {
        let ctFont = font as CTFont
        let lineAscent = CTFontGetAscent(ctFont)
        let lineDescent = CTFontGetDescent(ctFont)
        let lineLeading = CTFontGetLeading(ctFont)
        let cellHeight = ceil(lineAscent + lineDescent + lineLeading)
        let glyph = font.glyph(withName: "W")
        let cellWidth = font.advancement(forGlyph: glyph).width
        return CGSize(width: max(1, cellWidth), height: max(1, min(cellHeight, 8192)))
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()

        if superview == nil {
            pendingAttachLayoutWorkItem?.cancel()
            pendingAttachLayoutWorkItem = nil
            pendingInteractiveRedrawWorkItem?.cancel()
            pendingInteractiveRedrawWorkItem = nil
            isSettlingAttachLayout = false
            if let performanceIdentifier {
                TerminalPerformanceLog.mark("terminal detached \(performanceIdentifier)")
            }
        } else {
            if let performanceIdentifier {
                TerminalPerformanceLog.mark("terminal attached \(performanceIdentifier)")
            }
            prepareForAttachmentLayout()
        }
    }

    var shouldFollowOutput: Bool {
        !userIsReadingScrollback && (!canScroll || scrollPosition >= terminalFollowScrollThreshold)
    }

    func preserveScrollPositionIfNeeded<T>(_ operation: () -> T) -> T {
        let shouldPreserve = !shouldFollowOutput
        let previousYDisplay = terminal.buffer.yDisp
        let result = operation()

        if shouldPreserve {
            restoreScrollPosition(previousYDisplay)
        }

        return result
    }

    private func preservingScrollPositionIfNeeded(_ operation: () -> Void) {
        guard terminal != nil else {
            operation()
            return
        }

        let start = TerminalPerformanceLog.timestamp()
        preserveScrollPositionIfNeeded(operation)

        if let performanceIdentifier {
            TerminalPerformanceLog.duration("terminal resize \(performanceIdentifier)", from: start)
        }
    }

    private func restoreScrollPosition(_ previousYDisplay: Int) {
        let delta = terminal.buffer.yDisp - previousYDisplay

        if delta > 0 {
            scrollUp(lines: delta)
        } else if delta < 0 {
            scrollDown(lines: -delta)
        }
    }

    func updateScrollbackReadingState(position: Double) {
        if !canScroll || position >= terminalFollowScrollThreshold {
            userIsReadingScrollback = false
        } else if NSApp.currentEvent?.type == .scrollWheel {
            userIsReadingScrollback = true
        }
    }

    func handleDeleteShortcut(_ event: NSEvent) -> Bool {
        guard event.charactersIgnoringModifiers == terminalBackwardDelete else {
            return false
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if modifiers.contains(.command) {
            send(terminalKillToBeginningOfLine)
            return true
        }

        if modifiers.contains(.option) {
            send(terminalKillPreviousWord)
            return true
        }

        return false
    }

    override func showCursor(source: Terminal) {
        mirroredCursorIsVisible = true
        super.showCursor(source: source)
    }

    override func hideCursor(source: Terminal) {
        mirroredCursorIsVisible = false
        super.hideCursor(source: source)
    }

    override func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        mirroredCursorStyle = newStyle
        super.cursorStyleChanged(source: source, newStyle: newStyle)
    }

    @objc
    override open func copy(_ sender: Any) {
        let range = selectedPositions()
        let text = terminal.getText(start: range.start, end: range.end)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    override open func isAccessibilityElement() -> Bool {
        true
    }

    override open func isAccessibilityEnabled() -> Bool {
        true
    }

    override open func accessibilityLabel() -> String? {
        "Terminal Emulator"
    }

    override open func accessibilityRole() -> NSAccessibility.Role? {
        .textArea
    }

    override open func accessibilityValue() -> Any? {
        terminal.getText(
            start: Position(col: 0, row: 0),
            end: Position(col: terminal.buffer.x, row: terminal.getTopVisibleRow() + terminal.rows)
        )
    }

    override open func accessibilitySelectedText() -> String? {
        let range = selectedPositions()
        let text = terminal.getText(start: range.start, end: range.end)
        return text
    }

}
