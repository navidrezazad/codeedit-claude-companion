//
//  UtilityAreaViewModel.swift
//  CodeEdit
//
//  Created by Lukas Pistrol on 20.03.22.
//

import Darwin
import SwiftUI

/// # UtilityAreaViewModel
///
/// A model class to host and manage data for the Utility area.
class UtilityAreaViewModel: ObservableObject {
    private var restorationSaveWorkItem: DispatchWorkItem?

    private struct TerminalRestorationState: Codable {
        let terminals: [TerminalRestorationItem]
        let selectedTerminalIDs: [UUID]
    }

    private struct TerminalRestorationItem: Codable {
        let id: UUID
        let url: URL
        let title: String
        let terminalTitle: String
        let shellRawValue: String?
        let customTitle: Bool

        init(_ terminal: UtilityAreaTerminal) {
            self.id = terminal.id
            self.url = terminal.url
            self.title = terminal.title
            self.terminalTitle = terminal.terminalTitle
            self.shellRawValue = terminal.shell?.rawValue
            self.customTitle = terminal.customTitle
        }

        func restoredTerminal() -> UtilityAreaTerminal {
            let terminal = UtilityAreaTerminal(
                id: id,
                url: url,
                title: title,
                shell: shellRawValue.flatMap(Shell.init(rawValue:))
            )
            terminal.terminalTitle = terminalTitle
            terminal.customTitle = customTitle
            return terminal
        }
    }

    @Published var selectedTab: UtilityAreaTab? = .terminal

    @Published var terminals: [UtilityAreaTerminal] = []

    @Published var selectedTerminals: Set<UtilityAreaTerminal.ID> = []

    /// Indicates whether debugger is collapse or not
    @Published var isCollapsed: Bool = false

    /// Indicates whether collapse animation should be enabled when utility area is toggled
    @Published var animateCollapse: Bool = true

    /// Returns true when the drawer is visible
    @Published var isMaximized: Bool = false

    /// The current height of the drawer. Zero if hidden
    @Published var currentHeight: Double = 0

    /// The tab bar items for the UtilityAreaView
    @Published var tabItems: [UtilityAreaTab] = UtilityAreaTab.allCases

    /// The tab bar view model for UtilityAreaTabView
    @Published var tabViewModel = UtilityAreaTabViewModel()

    // MARK: - State Restoration

    func restoreFromState(_ workspace: WorkspaceDocument) {
        isCollapsed = workspace.getFromWorkspaceState(.utilityAreaCollapsed) as? Bool ?? false
        let restoredHeight = workspace.getFromWorkspaceState(.utilityAreaHeight) as? Double ?? 300.0
        currentHeight = restoredHeight > 1 ? restoredHeight : 300.0
        isMaximized = workspace.getFromWorkspaceState(.utilityAreaMaximized) as? Bool ?? false

        guard
            let data = workspace.getFromWorkspaceState(.openTerminals) as? Data,
            let restoredState = try? JSONDecoder().decode(TerminalRestorationState.self, from: data)
        else {
            return
        }

        terminals = restoredState.terminals.map { $0.restoredTerminal() }
        terminals.forEach(registerTerminal)

        let restoredIDs = Set(terminals.map(\.id))
        selectedTerminals = Set(restoredState.selectedTerminalIDs.filter { restoredIDs.contains($0) })

        if selectedTerminals.isEmpty, let terminal = terminals.last {
            selectedTerminals = [terminal.id]
        }
    }

    func saveRestorationState(_ workspace: WorkspaceDocument) {
        restorationSaveWorkItem?.cancel()
        restorationSaveWorkItem = nil

        workspace.addToWorkspaceState(key: .utilityAreaCollapsed, value: isCollapsed)
        workspace.addToWorkspaceState(key: .utilityAreaHeight, value: currentHeight)
        workspace.addToWorkspaceState(key: .utilityAreaMaximized, value: isMaximized)

        let state = TerminalRestorationState(
            terminals: terminals.map(TerminalRestorationItem.init),
            selectedTerminalIDs: Array(selectedTerminals)
        )

        if let data = try? JSONEncoder().encode(state) {
            workspace.addToWorkspaceState(key: .openTerminals, value: data)
        }
    }

    func scheduleRestorationStateSave(_ workspace: WorkspaceDocument) {
        restorationSaveWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self, weak workspace] in
            guard let self, let workspace else {
                return
            }
            self.saveRestorationState(workspace)
        }

        restorationSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
    }

    func togglePanel(animation: Bool = true) {
        self.animateCollapse = animation
        self.isMaximized = false
        self.isCollapsed.toggle()
    }

    // MARK: - Terminal Management

    /// Removes all terminals included in the given set and selects a new terminal if the selection was modified.
    /// The new selection is either the same selection minus the ids removed, or if that's empty the last terminal.
    /// - Parameter ids: A set of all terminal ids to remove.
    func removeTerminals(_ ids: Set<UUID>) {
        for (idx, terminal) in terminals.enumerated().reversed()
        where ids.contains(terminal.id) {
            TerminalSessionManager.shared.terminateAndRemoveSession(terminal.id)
            terminals.remove(at: idx)
        }

        var newSelection = selectedTerminals.subtracting(ids)

        if newSelection.isEmpty, let terminal = terminals.last {
            newSelection = [terminal.id]
        }

        selectedTerminals = newSelection
    }

    /// Terminates all terminal sessions owned by this utility area and clears cached terminal views.
    func cleanUpTerminals() {
        for terminal in terminals {
            TerminalSessionManager.shared.terminateAndRemoveSession(terminal.id)
        }
    }

    /// Update a terminal's title.
    /// - Parameters:
    ///   - id: The id of the terminal to update.
    ///   - title: The title to set. If left `nil`, will set the terminal's
    ///            ``UtilityAreaTerminal/customTitle`` to `false`.
    @discardableResult
    func updateTerminal(_ id: UUID, title: String?) -> Bool {
        guard let terminal = terminals.first(where: { $0.id == id }) else { return false }

        if let newTitle = title {
            var didChange = false

            if !terminal.customTitle {
                if terminal.title != newTitle {
                    terminal.title = newTitle
                    didChange = true
                }
            }

            if terminal.terminalTitle != newTitle {
                terminal.terminalTitle = newTitle
                didChange = true
            }

            if didChange {
                TerminalSessionManager.shared.updateSession(id, title: newTitle)
            }

            return didChange
        } else {
        guard terminal.customTitle else {
            return false
        }
        terminal.customTitle = false
        registerTerminal(terminal)
        return true
    }
    }

    /// Update a terminal's current directory.
    /// - Parameters:
    ///   - id: The id of the terminal to update.
    ///   - url: The current directory URL reported by the shell.
    @discardableResult
    func updateTerminal(_ id: UUID, url: URL) -> Bool {
        guard let terminal = terminals.first(where: { $0.id == id }), terminal.url != url else {
            return false
        }

        terminal.url = url
        TerminalSessionManager.shared.updateSession(id, currentDirectory: url)
        registerTerminal(terminal)
        return true
    }

    /// Create a new terminal if there are no existing terminals.
    /// Will not perform any action if terminals exist in the ``terminals`` array.
    /// - Parameter workspaceURL: The base url of the workspace, to initialize terminals.l
    func initializeTerminals(workspaceURL: URL) {
        guard terminals.isEmpty else { return }
        addTerminal(rootURL: workspaceURL)
    }

    /// Add a new terminal to the workspace and selects it.
    /// - Parameters:
    ///   - shell: The shell to use, `nil` if auto-detect the default shell.
    ///   - rootURL: The url to start the new terminal at. If left `nil` defaults to the user's home directory.
    func addTerminal(shell: Shell? = nil, rootURL: URL?) {
        let id = UUID()
        let terminal = UtilityAreaTerminal(
            id: id,
            url: rootURL ?? URL(filePath: "~/"),
            title: shell?.rawValue ?? "terminal",
            shell: shell
        )

        terminals.append(terminal)
        registerTerminal(terminal)

        selectedTerminals = [id]
    }

    /// Replaces the terminal with a given ID, killing the shell and restarting it at the same directory.
    ///
    /// Terminals being replaced will have the `SIGKILL` signal sent to the running shell. The new terminal will
    /// inherit the same `url` and `shell` parameters from the old one.
    /// - Parameter replacing: The ID of a terminal to replace with a new terminal.
    func replaceTerminal(_ replacing: UUID) {
        guard let index = terminals.firstIndex(where: { $0.id == replacing }) else {
            return
        }

        let id = UUID()
        let url = terminals[index].url
        let shell = terminals[index].shell
        TerminalSessionManager.shared.terminateAndRemoveSession(replacing, signal: SIGKILL)

        let terminal = UtilityAreaTerminal(
            id: id,
            url: url,
            title: shell?.rawValue ?? "terminal",
            shell: shell
        )
        terminals[index] = terminal
        registerTerminal(terminal)
        selectedTerminals = [id]
        return
    }

    /// Reorders terminals in the ``utilityAreaViewModel``.
    /// - Parameters:
    ///   - source: The source indices.
    ///   - destination: The destination indices.
    func reorderTerminals(from source: IndexSet, to destination: Int) {
        terminals.move(fromOffsets: source, toOffset: destination)
    }

    private func registerTerminal(_ terminal: UtilityAreaTerminal) {
        TerminalSessionManager.shared.registerTerminal(
            id: terminal.id,
            title: terminal.terminalTitle,
            currentDirectory: terminal.url,
            shell: terminal.shell
        )
    }
}
