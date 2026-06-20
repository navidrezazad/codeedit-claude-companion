//
//  TerminalEmulatorView+Coordinator.swift
//  CodeEditModules/TerminalEmulator
//
//  Created by Lukas Pistrol on 24.03.22.
//

import SwiftUI
import SwiftTerm

extension TerminalEmulatorView {
    final class Coordinator: NSObject, CELocalShellTerminalViewDelegate {
        private let terminalID: UUID
        public var onTitleChange: (_ title: String) -> Void
        public var onCurrentDirectoryChange: (_ directory: String?) -> Void

        var mode: TerminalMode

        init(
            terminalID: UUID,
            mode: TerminalMode,
            onTitleChange: @escaping (_ title: String) -> Void,
            onCurrentDirectoryChange: @escaping (_ directory: String?) -> Void
        ) {
            self.terminalID = terminalID
            self.onTitleChange = onTitleChange
            self.onCurrentDirectoryChange = onCurrentDirectoryChange
            self.mode = mode
            super.init()
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            onCurrentDirectoryChange(directory)
        }

        func sizeChanged(source: CETerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: CETerminalView, title: String) {
            onTitleChange(title)
        }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            guard let exitCode else {
                return
            }
            if case .shell = mode {
                source.feed(text: "Exit code: \(exitCode)\n\r\n")
                source.feed(text: "To open a new session, create a new terminal tab.")
                TerminalSessionManager.shared.removeSession(terminalID)
            }
        }
    }
}
