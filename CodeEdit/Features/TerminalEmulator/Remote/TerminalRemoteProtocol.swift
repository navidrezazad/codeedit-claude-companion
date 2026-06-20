//
//  TerminalRemoteProtocol.swift
//  CodeEdit
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

        init(
            type: ServerMessageType,
            version: Int? = nil,
            authenticated: Bool? = nil,
            sessions: [Session]? = nil,
            sessionID: UUID? = nil,
            data: Data? = nil,
            path: String? = nil,
            files: [FileItem]? = nil,
            markdown: MarkdownDocument? = nil,
            markdownStream: MarkdownStreamDocument? = nil,
            projectedOutput: ProjectedOutput? = nil,
            message: String? = nil,
            port: UInt16? = nil,
            addresses: [String]? = nil,
            publicAddress: String? = nil,
            defaultPath: String? = nil
        ) {
            self.type = type
            self.version = version
            self.authenticated = authenticated
            self.sessions = sessions
            self.sessionID = sessionID
            self.data = data
            self.path = path
            self.files = files
            self.markdown = markdown
            self.markdownStream = markdownStream
            self.projectedOutput = projectedOutput
            self.message = message
            self.port = port
            self.addresses = addresses
            self.publicAddress = publicAddress
            self.defaultPath = defaultPath
        }
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

        init(
            sequence: Int,
            screenMode: ScreenMode? = nil,
            columns: Int? = nil,
            terminalRows: Int? = nil,
            rows: [ProjectedRow]
        ) {
            self.sequence = sequence
            self.screenMode = screenMode
            self.columns = columns
            self.terminalRows = terminalRows
            self.rows = rows
        }
    }

    struct ProjectedRow: Codable, Equatable {
        let row: Int
        let text: String

        init(row: Int, text: String) {
            self.row = row
            self.text = text
        }
    }

    struct Session: Codable, Identifiable, Equatable {
        let id: UUID
        let title: String
        let currentDirectory: String?
        let shell: String?
        let isRunning: Bool
        let columns: Int?
        let rows: Int?

        init(
            id: UUID,
            title: String,
            currentDirectory: String?,
            shell: String?,
            isRunning: Bool,
            columns: Int? = nil,
            rows: Int? = nil
        ) {
            self.id = id
            self.title = title
            self.currentDirectory = currentDirectory
            self.shell = shell
            self.isRunning = isRunning
            self.columns = columns
            self.rows = rows
        }
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

        init(
            name: String,
            path: String,
            isDirectory: Bool,
            isMarkdown: Bool,
            byteCount: Int64?
        ) {
            self.name = name
            self.path = path
            self.isDirectory = isDirectory
            self.isMarkdown = isMarkdown
            self.byteCount = byteCount
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

        init(
            streamID: UUID,
            sessionID: UUID,
            path: String,
            name: String,
            markdown: String,
            isActive: Bool
        ) {
            self.streamID = streamID
            self.sessionID = sessionID
            self.path = path
            self.name = name
            self.markdown = markdown
            self.isActive = isActive
        }
    }
}
