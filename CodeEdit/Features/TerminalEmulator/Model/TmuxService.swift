//
//  TmuxService.swift
//  CodeEdit
//
//  Created by Claude on 7/6/26.
//

import Foundation
import CryptoKit

/// Metadata for a single tmux session, parsed from `tmux list-sessions`.
struct TmuxSessionInfo: Equatable {
    let name: String
    let windows: Int
    let attached: Bool
    let currentPath: String?
}

/// Thin wrapper over the `tmux` CLI. tmux is the session store for the app: sessions are
/// enumerated, created, and killed here, and terminals attach to them via `attachCommand`.
///
/// The rest of the app is `UUID`-keyed, while tmux sessions are identified by name, so this
/// service also maps names to **stable** UUIDs (derived deterministically from the name) — the
/// same tmux session therefore keeps the same id across app launches, which lets per-session
/// state (like Markdown streams) stay associated with it.
///
/// If tmux is not installed, `isAvailable` is `false` and callers fall back to a plain shell.
final class TmuxService {
    static let shared = TmuxService()

    private init() {}

    /// The resolved `tmux` executable, or `nil` when tmux is not installed.
    private(set) lazy var executableURL: URL? = Self.locateTmux()

    /// Tracks whether mouse mode has already been enabled on the server this run.
    private var didEnableMouse = false

    /// Whether tmux is installed and usable. When `false`, the app falls back to plain shells.
    var isAvailable: Bool { executableURL != nil }

    // MARK: - Name ↔ UUID identity

    /// A stable UUID for a tmux session name. Deterministic, so the same name always maps to the
    /// same id (across launches), keeping per-session state attached to the right session.
    func id(forSessionNamed name: String) -> UUID {
        Self.deterministicID(for: name)
    }

    /// Resolves an id (produced by `id(forSessionNamed:)`) back to a live tmux session name by
    /// scanning the current sessions. Returns `nil` if no live session matches.
    func sessionName(forID id: UUID) -> String? {
        listSessions().first { Self.deterministicID(for: $0.name) == id }?.name
    }

    // MARK: - Session commands

    /// Enumerates the live tmux sessions. Returns an empty array when tmux is unavailable or the
    /// server has no sessions.
    func listSessions() -> [TmuxSessionInfo] {
        guard let output = run([
            "list-sessions",
            "-F",
            "#{session_name}\t#{session_windows}\t#{session_attached}\t#{pane_current_path}"
        ]) else {
            return []
        }

        return output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { Self.parseSession(String($0)) }
    }

    /// Creates a new detached tmux session. Returns `false` if tmux is unavailable or the command
    /// failed (e.g. the name already exists).
    @discardableResult
    func createSession(name: String, currentDirectory: String? = nil) -> Bool {
        var arguments = ["new-session", "-d", "-s", name]
        if let currentDirectory, !currentDirectory.isEmpty {
            arguments.append(contentsOf: ["-c", currentDirectory])
        }
        return run(arguments) != nil
    }

    /// Kills a tmux session by name.
    @discardableResult
    func killSession(name: String) -> Bool {
        run(["kill-session", "-t", name]) != nil
    }

    /// Enables tmux mouse mode server-wide (once) so the trackpad scrolls session history (via copy
    /// mode) and selects text. tmux runs on the alternate screen, so without this the host terminal
    /// can't scroll. Safe to call repeatedly; only the first success sticks. Requires the server to be
    /// up (a session to exist), so callers invoke it once a session is present.
    @discardableResult
    func enableMouseModeOnce() -> Bool {
        guard executableURL != nil, !didEnableMouse else {
            return didEnableMouse
        }
        if run(["set-option", "-g", "mouse", "on"]) != nil {
            didEnableMouse = true
        }
        return didEnableMouse
    }

    /// The executable + arguments a PTY should run to attach to (or create) the named session.
    /// `new-session -A -s NAME` attaches if the session exists and creates it otherwise.
    func attachCommand(forSessionNamed name: String, currentDirectory: String?) -> (URL, [String])? {
        guard let executableURL else {
            return nil
        }

        var arguments = ["new-session", "-A", "-s", name]
        if let currentDirectory, !currentDirectory.isEmpty {
            arguments.append(contentsOf: ["-c", currentDirectory])
        }
        return (executableURL, arguments)
    }

    // MARK: - Process helpers

    @discardableResult
    private func run(_ arguments: [String]) -> String? {
        guard let executableURL else {
            return nil
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let standardOutput = Pipe()
        process.standardOutput = standardOutput
        process.standardError = Pipe()

        do {
            try process.run()
            let data = standardOutput.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return nil
            }
            return String(bytes: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func parseSession(_ line: String) -> TmuxSessionInfo? {
        let parts = line.components(separatedBy: "\t")
        guard parts.count >= 3, !parts[0].isEmpty else {
            return nil
        }

        let path = parts.count >= 4 && !parts[3].isEmpty ? parts[3] : nil
        return TmuxSessionInfo(
            name: parts[0],
            windows: Int(parts[1]) ?? 1,
            attached: (Int(parts[2]) ?? 0) > 0,
            currentPath: path
        )
    }

    private static func locateTmux() -> URL? {
        let fileManager = FileManager.default
        let configuredPath = ProcessInfo.processInfo.environment["CODEEDITV2_TMUX_PATH"]
        let candidates = [
            configuredPath,
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux"
        ].compactMap { $0 }

        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// A deterministic, name-based (version-3-style) UUID so a tmux session name always resolves
    /// to the same id.
    private static func deterministicID(for name: String) -> UUID {
        let seed = "codeeditv2.tmux.session:" + name
        let digest = Insecure.MD5.hash(data: Data(seed.utf8))
        var bytes = Array(digest) // MD5 is exactly 16 bytes
        bytes[6] = (bytes[6] & 0x0F) | 0x30 // version 3
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return bytes.withUnsafeBufferPointer { buffer in
            NSUUID(uuidBytes: buffer.baseAddress) as UUID
        }
    }
}
