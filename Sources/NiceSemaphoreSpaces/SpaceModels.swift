import Foundation

/// Where a window is: which Space, and on which display.
public struct SpaceLocation: Codable, Equatable, Sendable {
    /// Stable Space identifier (CGS `ManagedSpaceID`). Survives reordering Spaces.
    public var spaceId: Int
    /// 1-based position across all displays, as shown in the menu bar. Shifts when Spaces are
    /// added, removed or reordered, so use `spaceId` to follow a Space over time.
    public var spaceIndex: Int
    /// Identifier (UUID) of the display hosting the Space.
    public var displayId: String?

    public init(spaceId: Int, spaceIndex: Int, displayId: String? = nil) {
        self.spaceId = spaceId
        self.spaceIndex = spaceIndex
        self.displayId = displayId
    }
}

/// A session's current Space, as stored in `spaces/state.json`.
public struct SpaceAssignment: Codable, Equatable, Sendable {
    public var spaceId: Int
    public var spaceIndex: Int
    public var displayId: String?
    /// When the session was first seen on this Space.
    public var since: Date
    public var cwd: String?

    public init(location: SpaceLocation, since: Date, cwd: String?) {
        self.spaceId = location.spaceId
        self.spaceIndex = location.spaceIndex
        self.displayId = location.displayId
        self.since = since
        self.cwd = cwd
    }
}

/// The structure of `spaces/state.json`
struct SpacesStateFile: Codable {
    var v: Int = 1
    var updated: Date
    var sessions: [String: SpaceAssignment]
}

/// One line of `spaces/log.jsonl`.
public struct SpaceLogRecord: Codable, Equatable, Sendable {
    public enum Event: String, Codable, Sendable {
        /// The session was first seen on this Space.
        case enter
        /// The session moved to another Space, ended, or could no longer be located.
        case leave
        /// The app started tracking. Time since the previous `tracker_stop` wasn't observed.
        case trackerStart = "tracker_start"
        /// The app stopped tracking (quit).
        case trackerStop = "tracker_stop"
    }

    public var v: Int
    public var ts: Date
    public var event: Event
    public var sessionId: String?
    public var spaceId: Int?
    public var spaceIndex: Int?
    public var displayId: String?
    public var cwd: String?

    public init(ts: Date, event: Event, sessionId: String? = nil, spaceId: Int? = nil, spaceIndex: Int? = nil, displayId: String? = nil, cwd: String? = nil) {
        self.v = 1
        self.ts = ts
        self.event = event
        self.sessionId = sessionId
        self.spaceId = spaceId
        self.spaceIndex = spaceIndex
        self.displayId = displayId
        self.cwd = cwd
    }

    init(event: Event, sessionId: String, assignment: SpaceAssignment, at ts: Date) {
        self.init(ts: ts, event: event, sessionId: sessionId, spaceId: assignment.spaceId, spaceIndex: assignment.spaceIndex, displayId: assignment.displayId, cwd: assignment.cwd)
    }
}
