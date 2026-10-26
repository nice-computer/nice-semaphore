import Foundation
import NiceSemaphoreSessions

/// Finds the Space each session's terminal window is on.
public protocol SpaceLocator {
    /// Location of every session that could be located, keyed by session ID. Returns nil when
    /// locating failed as a whole (e.g. the terminal didn't answer), so callers keep what they had.
    func locate(_ sessions: [ClaudeInstance]) -> [String: SpaceLocation]?
}

/// Terminal-specific step: which window hosts each TTY.
public protocol TerminalWindowResolver {
    /// Window ID (CGWindowID) for each of the given TTYs this terminal hosts. Returns an empty
    /// map when the terminal isn't running, and nil when it couldn't be queried.
    func windowIds(forTTYs ttys: Set<String>) -> [String: UInt32]?
}

/// macOS step: which Space each window is on.
public protocol WindowSpaceResolver {
    /// Location of each window that is on a Space. Returns nil when Spaces can't be queried.
    func locations(ofWindows windowIds: Set<UInt32>) -> [UInt32: SpaceLocation]?
}

/// Session → TTY → terminal window → Space.
public struct WindowSpaceLocator: SpaceLocator {
    public var terminals: [TerminalWindowResolver]
    public var spaces: WindowSpaceResolver

    public init(terminals: [TerminalWindowResolver], spaces: WindowSpaceResolver) {
        self.terminals = terminals
        self.spaces = spaces
    }

    public func locate(_ sessions: [ClaudeInstance]) -> [String: SpaceLocation]? {
        let ttys = Set(sessions.compactMap(\.tty))
        guard !ttys.isEmpty else { return [:] }

        var windowByTTY: [String: UInt32] = [:]
        var anyAnswered = false
        for terminal in terminals {
            guard let windows = terminal.windowIds(forTTYs: ttys) else { continue }
            anyAnswered = true
            windowByTTY.merge(windows) { first, _ in first }
        }
        guard anyAnswered else { return nil }
        guard !windowByTTY.isEmpty else { return [:] }

        guard let locationByWindow = spaces.locations(ofWindows: Set(windowByTTY.values)) else {
            return nil
        }

        var result: [String: SpaceLocation] = [:]
        for session in sessions {
            guard let tty = session.tty,
                  let windowId = windowByTTY[tty],
                  let location = locationByWindow[windowId] else {
                continue
            }
            result[session.id] = location
        }
        return result
    }
}
