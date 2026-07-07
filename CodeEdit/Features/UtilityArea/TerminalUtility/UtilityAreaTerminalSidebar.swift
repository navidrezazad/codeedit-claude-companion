//
//  UtilityAreaTerminalSidebar.swift
//  CodeEdit
//
//  Created by Khan Winter on 8/19/24.
//

import SwiftUI

/// The view that displays the list of available terminals in the utility area.
/// See ``UtilityAreaTerminalView`` for use.
struct UtilityAreaTerminalSidebar: View {
    @EnvironmentObject private var workspace: WorkspaceDocument
    @EnvironmentObject private var utilityAreaViewModel: UtilityAreaViewModel

    @State private var isShowingNewTmux = false
    @State private var newTmuxName = ""

    var body: some View {
        List(selection: $utilityAreaViewModel.selectedTerminals) {
            ForEach(utilityAreaViewModel.terminals, id: \.self.id) { terminal in
                UtilityAreaTerminalTab(
                    terminal: terminal,
                    removeTerminals: utilityAreaViewModel.removeTerminals,
                    isSelected: utilityAreaViewModel.selectedTerminals.contains(terminal.id),
                    selectedIDs: utilityAreaViewModel.selectedTerminals
                )
                .tag(terminal.id)
                .listRowSeparator(.hidden)
            }
            .onMove { [weak utilityAreaViewModel] (source, destination) in
                utilityAreaViewModel?.reorderTerminals(from: source, to: destination)
            }
        }
        .focusedObject(utilityAreaViewModel)
        .listStyle(.automatic)
        .accentColor(.secondary)
        .contextMenu {
            Button("New Terminal") {
                utilityAreaViewModel.addTerminal(rootURL: workspace.fileURL)
            }
            Menu("New Terminal With Profile") {
                Button("Default") {
                    utilityAreaViewModel.addTerminal(rootURL: workspace.fileURL)
                }
                Divider()
                ForEach(Shell.allCases, id: \.self) { shell in
                    Button(shell.rawValue) {
                        utilityAreaViewModel.addTerminal(shell: shell, rootURL: workspace.fileURL)
                    }
                }
            }
            if utilityAreaViewModel.isTmuxAvailable {
                Divider()
                Button("New Named tmux Session…") {
                    newTmuxName = ""
                    isShowingNewTmux = true
                }
                if let selectedID = utilityAreaViewModel.selectedTerminals.first,
                   let tmuxName = TerminalSessionManager.shared.tmuxSessionName(for: selectedID) {
                    Button("Kill tmux Session “\(tmuxName)”", role: .destructive) {
                        utilityAreaViewModel.killTmuxSession(name: tmuxName)
                    }
                }
            }
        }
        .alert("New tmux session", isPresented: $isShowingNewTmux) {
            TextField("Session name", text: $newTmuxName)
            Button("Create") {
                utilityAreaViewModel.addTmuxSession(name: newTmuxName, rootURL: workspace.fileURL)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Create and attach a new tmux session.")
        }
        .onChange(of: utilityAreaViewModel.terminals) { _, newValue in
            if newValue.isEmpty {
                utilityAreaViewModel.addTerminal(rootURL: workspace.fileURL)
            }
        }
        .onAppear {
            utilityAreaViewModel.reconcileTmuxSessions(rootURL: workspace.fileURL)
        }
        .paneToolbar {
            PaneToolbarSection {
                if utilityAreaViewModel.isTmuxAvailable {
                    Menu {
                        Button("New Named tmux Session…") {
                            newTmuxName = ""
                            isShowingNewTmux = true
                        }
                        Divider()
                        Button("New Plain Terminal") {
                            utilityAreaViewModel.addTerminal(rootURL: workspace.fileURL)
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("New tmux session")
                } else {
                    Button {
                        utilityAreaViewModel.addTerminal(rootURL: workspace.fileURL)
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                Button {
                    utilityAreaViewModel.removeTerminals(utilityAreaViewModel.selectedTerminals)
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(utilityAreaViewModel.terminals.count <= 1)
                .opacity(utilityAreaViewModel.terminals.count <= 1 ? 0.5 : 1)
            }
            Spacer()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminals")
        .accessibilityIdentifier("terminalsList")
    }
}

#Preview {
    UtilityAreaTerminalSidebar()
}
