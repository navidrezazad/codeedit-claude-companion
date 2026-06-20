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

    /// Default terminal foreground/background colors (packed 0xRRGGBB) shared by both sides so the
    /// iPhone renders the same dark-terminal look the Mac assumes when resolving `inverse` styling.
    static let defaultForegroundRGB = 0x00E5_E5E5
    static let defaultBackgroundRGB = 0x0019_1919

    /// Bit positions for `ProjectedSpan.style`, shared by the Mac projector and the iOS renderer.
    enum SpanStyle {
        static let bold = 1 << 0
        static let italic = 1 << 1
        static let underline = 1 << 2
        static let strikethrough = 1 << 3
        static let dim = 1 << 4
    }

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
        /// Styled runs for this row. `nil` means the whole row uses the default color/style (the
        /// common case), in which case the renderer falls back to `text` and no extra bytes are sent.
        let spans: [ProjectedSpan]?
    }

    /// A run of equally-styled characters within a `ProjectedRow`. Colors are packed `0xRRGGBB`
    /// integers (`nil` = terminal default); `style` is an `OR` of `SpanStyle` bits (`nil` = none).
    /// Keys are intentionally terse to keep the streamed JSON small.
    struct ProjectedSpan: Codable, Equatable {
        let text: String
        let foreground: Int?
        let background: Int?
        let style: Int?

        enum CodingKeys: String, CodingKey {
            case text = "t"
            case foreground = "f"
            case background = "b"
            case style = "s"
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
