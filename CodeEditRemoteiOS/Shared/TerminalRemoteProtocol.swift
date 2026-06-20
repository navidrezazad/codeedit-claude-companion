//
//  TerminalRemoteProtocol.swift
//  CodeEditRemoteiOS
//
//  Created by Claude on 6/12/26.
//

import Foundation

enum TerminalRemoteProtocol {
    static let version = 1
    static let serviceType = "_codeeditv2-term._tcp"

    enum ClientMessageType: String, Codable {
        case authenticate
        case list
        case attach
        case detach
        case input
        case resize
        case browseFiles
        case readMarkdown
        case startMarkdownStream
        case stopMarkdownStream
        case triggerMarkdownStreamUpdate
        case rewriteMarkdownStream
    }

    enum ServerMessageType: String, Codable {
        case hello
        case authenticated
        case sessions
        case input
        case output
        case fileList
        case markdown
        case markdownStream
        case error
    }

    struct ClientMessage: Codable {
        let type: ClientMessageType
        let token: String?
        let sessionID: UUID?
        let data: Data?
        let includeRecent: Bool?
        let path: String?
        let prompt: String?
        let streamID: UUID?
        let columns: Int?
        let rows: Int?

        init(
            type: ClientMessageType,
            token: String? = nil,
            sessionID: UUID? = nil,
            data: Data? = nil,
            includeRecent: Bool? = nil,
            path: String? = nil,
            prompt: String? = nil,
            streamID: UUID? = nil,
            columns: Int? = nil,
            rows: Int? = nil
        ) {
            self.type = type
            self.token = token
            self.sessionID = sessionID
            self.data = data
            self.includeRecent = includeRecent
            self.path = path
            self.prompt = prompt
            self.streamID = streamID
            self.columns = columns
            self.rows = rows
        }
    }

    struct ServerMessage: Codable {
        let type: ServerMessageType
        let version: Int?
        let authenticated: Bool?
        let sessions: [Session]?
        let sessionID: UUID?
        let data: Data?
        let path: String?
        let files: [FileItem]?
        let markdown: MarkdownDocument?
        let markdownStream: MarkdownStreamDocument?
        let projectedOutput: ProjectedOutput?
        let message: String?
        let port: UInt16?
        let addresses: [String]?
        let publicAddress: String?
        let defaultPath: String?
    }

    enum ScreenMode: String, Codable, Equatable {
        case main
        case alternate
    }

    struct ProjectedOutput: Codable, Equatable {
        let sequence: Int
        let screenMode: ScreenMode?
        let columns: Int?
        let terminalRows: Int?
        let rows: [ProjectedRow]
    }

    struct ProjectedRow: Codable, Equatable {
        let row: Int
        let text: String
    }

    struct Session: Codable, Identifiable, Equatable {
        let id: UUID
        let title: String
        let currentDirectory: String?
        let shell: String?
        let isRunning: Bool
        let columns: Int?
        let rows: Int?
    }

    struct FileItem: Codable, Identifiable, Equatable {
        let name: String
        let path: String
        let isDirectory: Bool
        let isMarkdown: Bool
        let byteCount: Int64?

        var id: String {
            path
        }
    }

    struct MarkdownDocument: Codable, Equatable {
        let path: String
        let name: String
        let markdown: String
    }

    struct MarkdownStreamDocument: Codable, Equatable {
        let streamID: UUID
        let sessionID: UUID
        let path: String
        let name: String
        let markdown: String
        let isActive: Bool
    }
}
