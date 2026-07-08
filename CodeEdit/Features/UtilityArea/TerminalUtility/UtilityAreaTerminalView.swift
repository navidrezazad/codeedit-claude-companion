//
//  UtilityAreaTerminal.swift
//  CodeEdit
//
//  Created by Austin Condiff on 5/25/23.
//

import SwiftUI
import Cocoa

struct UtilityAreaTerminalView: View {
    @AppSettings(\.theme.matchAppearance)
    private var matchAppearance
    @AppSettings(\.terminal.darkAppearance)
    private var darkAppearance
    @AppSettings(\.theme.useThemeBackground)
    private var useThemeBackground
    @AppSettings(\.textEditing.font)
    private var textEditingFont
    @AppSettings(\.terminal.font)
    private var terminalFont
    @AppSettings(\.terminal.useTextEditorFont)
    private var useTextEditorFont

    @Environment(\.colorScheme)
    private var colorScheme

    @EnvironmentObject private var workspace: WorkspaceDocument

    @EnvironmentObject private var utilityAreaViewModel: UtilityAreaViewModel

    @State private var sidebarIsCollapsed = false

    @StateObject private var themeModel: ThemeModel = .shared

    @State private var isMenuVisible = false

    @State private var popoverSource: CGRect = .zero

    var font: NSFont {
        useTextEditorFont == true ? textEditingFont.current : terminalFont.current
    }

    /// Returns the `background` color of the selected theme
    private var backgroundColor: NSColor {
        if let selectedTheme = matchAppearance && darkAppearance
            ? themeModel.selectedDarkTheme
            : themeModel.selectedTheme,
           let index = themeModel.themes.firstIndex(of: selectedTheme) {
            return NSColor(themeModel.themes[index].terminal.background.swiftColor)
        }
        return .windowBackgroundColor
    }

    /// Decides the color scheme used in the terminal.
    ///
    /// Decision list:
    /// - If there is no selection, use the system color scheme ``UtilityAreaTerminalView/colorScheme``
    /// - If the match appearance and dark appearance settings are true, return dark if the selected dark theme is dark.
    /// - Otherwise, return dark if the selected theme is dark.
    private var terminalColorScheme: ColorScheme {
        return if utilityAreaViewModel.selectedTerminals.isEmpty {
            colorScheme
        } else if matchAppearance && darkAppearance {
            themeModel.selectedDarkTheme?.appearance == .dark ? .dark : .light
        } else {
            themeModel.selectedTheme?.appearance == .dark ? .dark : .light
        }
    }

    private var terminalPanelCanRunSelectedShell: Bool {
        utilityAreaViewModel.selectedTab == .terminal
            && (
                utilityAreaViewModel.isMaximized
                || (!utilityAreaViewModel.isCollapsed && utilityAreaViewModel.currentHeight > 1)
            )
    }

    private var selectedTerminalID: UUID? {
        utilityAreaViewModel.selectedTerminals.first
    }

    /// Finds the selected terminal.
    /// - Returns: The selected terminal.
    private func getSelectedTerminal() -> UtilityAreaTerminal? {
        guard let selectedTerminalID = utilityAreaViewModel.selectedTerminals.first else {
            return nil
        }
        return utilityAreaViewModel.terminals.first(where: { $0.id == selectedTerminalID })
    }

    /// Match SwiftTerm's cell height calculation so the SwiftUI frame contains full terminal rows.
    /// - Parameter nsFont: The font being used in the terminal.
    /// - Returns: The height in pixels of the font.
    func fontTotalHeight(nsFont: NSFont) -> CGFloat {
        let ctFont = nsFont as CTFont
        let ascent = CTFontGetAscent(ctFont)
        let descent = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)
        return ceil(ascent + descent + leading)
    }

    var body: some View {
        UtilityAreaTabView(model: utilityAreaViewModel.tabViewModel) { tabState in
            ZStack {
                // Keeps the sidebar from changing sizes because TerminalEmulatorView takes a µs to load in
                HStack { Spacer() }

                if utilityAreaViewModel.terminals.isEmpty {
                    CEContentUnavailableView("No Selection")
                } else if terminalPanelCanRunSelectedShell {
                    GeometryReader { geometry in
                        let containerHeight = geometry.size.height
                        let totalFontHeight = fontTotalHeight(nsFont: font).rounded(.up)
                        let constrainedHeight = containerHeight - containerHeight.truncatingRemainder(
                            dividingBy: totalFontHeight
                        )
                        VStack(spacing: 0) {
                            Spacer(minLength: 0).frame(minHeight: 0)
                            selectedTerminalView(height: max(0, constrainedHeight))
                        }
                    }
                } else {
                    Color.clear
                }
            }
            .padding(.horizontal, 10)
            .paneToolbar {
                PaneToolbarSection {
                    UtilityAreaTerminalPicker(
                        selectedIDs: $utilityAreaViewModel.selectedTerminals,
                        terminals: utilityAreaViewModel.terminals
                    )
                    .opacity(tabState.leadingSidebarIsCollapsed ? 1 : 0)
                }
                Spacer()
                PaneToolbarSection {
                    Button {
                        guard let terminal = getSelectedTerminal() else {
                            return
                        }
                        utilityAreaViewModel.replaceTerminal(terminal.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Reset the terminal")
                    .disabled(getSelectedTerminal() == nil)
                    Button {
                        // split terminal
                    } label: {
                        Image(systemName: "square.split.2x1")
                    }
                    .help("Implementation Needed")
                    .disabled(true)
                }
            }
            .background {
                backgroundEffectView
            }
            .colorScheme(terminalColorScheme)
        } leadingSidebar: { _ in
            UtilityAreaTerminalSidebar()
        }
        .onAppear {
            guard let workspaceURL = workspace.fileURL else {
                assertionFailure("Workspace does not have a file URL.")
                return
            }
            utilityAreaViewModel.initializeTerminals(workspaceURL: workspaceURL)
            persistTerminals()
        }
        .onChange(of: utilityAreaViewModel.terminals.map(\.id)) { _, _ in
            persistTerminals()
        }
        .onChange(of: utilityAreaViewModel.selectedTerminals) { _, _ in
            if let selectedTerminalID {
                TerminalPerformanceLog.mark("terminal selection changed \(selectedTerminalID)")
            }
            persistTerminals()
        }
        .accessibilityIdentifier("terminal-area")
    }

    @ViewBuilder
    private func selectedTerminalView(height: CGFloat) -> some View {
        Group {
            if let terminal = getSelectedTerminal() {
                terminalView(for: terminal)
                    .frame(height: height)
            } else {
                Color.clear.frame(height: height)
            }
        }
        .frame(height: height)
    }

    private func terminalView(for terminal: UtilityAreaTerminal) -> some View {
        TerminalEmulatorView(
            url: terminal.url,
            terminalID: terminal.id,
            shellType: terminal.shell,
            onTitleChange: { [weak terminal] newTitle in
                guard let id = terminal?.id else { return }
                // This can be called during view updates, so dispatch before mutating state.
                DispatchQueue.main.async { [weak utilityAreaViewModel] in
                    if utilityAreaViewModel?.updateTerminal(id, title: newTitle) == true {
                        persistTerminals()
                    }
                }
            },
            onCurrentDirectoryChange: { [weak terminal] directory in
                guard
                    let id = terminal?.id,
                    let url = terminalDirectoryURL(from: directory)
                else {
                    return
                }

                DispatchQueue.main.async { [weak utilityAreaViewModel] in
                    if utilityAreaViewModel?.updateTerminal(id, url: url) == true {
                        persistTerminals()
                    }
                }
            }
        )
        .id(terminal.id)
        .accessibilityIdentifier("terminal")
    }

    @ViewBuilder var backgroundEffectView: some View {
        if utilityAreaViewModel.selectedTerminals.isEmpty {
            EffectView(.contentBackground)
        } else if useThemeBackground {
            Color(nsColor: backgroundColor)
        } else {
            if colorScheme == .dark {
                EffectView(.underPageBackground)
            } else {
                EffectView(.contentBackground)
            }
        }
    }

    private func terminalDirectoryURL(from directory: String?) -> URL? {
        guard let directory, !directory.isEmpty else {
            return nil
        }

        if let url = URL(string: directory), url.isFileURL {
            return url
        }

        if directory.hasPrefix("file://") {
            let filePath = directory
                .trimmingPrefix("file://")
                .drop { $0 != "/" }

            guard !filePath.isEmpty else {
                return nil
            }

            let path = String(filePath).removingPercentEncoding ?? String(filePath)
            return URL(filePath: path, directoryHint: .isDirectory)
        }

        return URL(filePath: directory, directoryHint: .isDirectory)
    }

    private func persistTerminals() {
        utilityAreaViewModel.scheduleRestorationStateSave(workspace)
    }
}
