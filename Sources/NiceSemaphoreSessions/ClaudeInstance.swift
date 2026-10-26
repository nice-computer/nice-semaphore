import Foundation

/// Represents a running Claude Code instance
public struct ClaudeInstance: Identifiable, Codable, Equatable, Sendable {
    public let id: String  // session_id
    public var status: Status
    public var project: String
    public var lastUpdate: Date
    public var pid: Int?         // Process ID of Claude instance
    public var terminalPid: Int? // Process ID of the terminal (for focus detection)
    public var tty: String?      // TTY path for foreground detection

    public enum Status: String, Codable, Sendable {
        case working   // Claude is processing
        case waiting   // Claude finished, awaiting user input
        case idle      // No activity for a while (optional future use)
    }

    public init(id: String, status: Status, project: String, lastUpdate: Date, pid: Int? = nil, terminalPid: Int? = nil, tty: String? = nil) {
        self.id = id
        self.status = status
        self.project = project
        self.lastUpdate = lastUpdate
        self.pid = pid
        self.terminalPid = terminalPid
        self.tty = tty
    }

    /// Returns the shortened project name (last path component)
    public var shortProjectName: String {
        return (project as NSString).lastPathComponent
    }

    /// Returns a user-friendly display path (with ~ for home directory)
    public var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if project.hasPrefix(home) {
            return "~" + project.dropFirst(home.count)
        }
        return project
    }
}

/// The structure of `sessions/state.json`
struct SessionsStateFile: Codable {
    var v: Int?
    var sessions: [String: SessionData]

    struct SessionData: Codable {
        var status: ClaudeInstance.Status
        var project: String?
        var lastUpdate: Date
        var pid: Int?
        var terminalPid: Int?
        var tty: String?
    }

    /// Convert to array of ClaudeInstance, skipping entries missing required fields
    func toInstances() -> [ClaudeInstance] {
        return sessions.compactMap { (id, data) in
            guard let project = data.project else { return nil }
            return ClaudeInstance(
                id: id,
                status: data.status,
                project: project,
                lastUpdate: data.lastUpdate,
                pid: data.pid,
                terminalPid: data.terminalPid,
                tty: data.tty.flatMap { $0.isEmpty ? nil : $0 }
            )
        }.sorted { $0.lastUpdate > $1.lastUpdate }
    }
}

/// One line of `sessions/log.jsonl`. Most records are written by the hook script; the app adds
/// `reaped` (process died without SessionEnd) and `imported` (migrated from the legacy status file).
public struct SessionLogRecord: Codable, Equatable, Sendable {
    public var v: Int
    public var ts: Date
    public var sessionId: String
    /// Hook event name (`SessionStart`, `Stop`, …), `reaped` or `imported`.
    public var event: String
    public var status: String?
    public var prevStatus: String?
    public var cwd: String?
    public var pid: Int?
    public var tty: String?
    public var tool: String?

    public init(ts: Date, sessionId: String, event: String, status: String? = nil, prevStatus: String? = nil, cwd: String? = nil, pid: Int? = nil, tty: String? = nil, tool: String? = nil) {
        self.v = 1
        self.ts = ts
        self.sessionId = sessionId
        self.event = event
        self.status = status
        self.prevStatus = prevStatus
        self.cwd = cwd
        self.pid = pid
        self.tty = tty
        self.tool = tool
    }
}
