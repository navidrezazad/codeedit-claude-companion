//
//  TerminalRemoteProtocol+CodeEdit.swift
//  CodeEdit
//
//  Created by Claude on 6/12/26.
//

extension TerminalRemoteProtocol.Session {
    init(_ descriptor: TerminalSessionDescriptor) {
        self.init(
            id: descriptor.id,
            title: descriptor.title,
            currentDirectory: descriptor.currentDirectory?.path,
            shell: descriptor.shell?.rawValue,
            isRunning: descriptor.isRunning,
            columns: descriptor.columns,
            rows: descriptor.rows,
            tmuxName: descriptor.tmuxName
        )
    }
}
