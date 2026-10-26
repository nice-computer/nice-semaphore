import Foundation
import NiceSemaphoreSessions

/// Tracks which Space each session is on, persisting the current assignments to
/// `spaces/state.json` and every change to `spaces/log.jsonl`.
///
/// A session's identity on a Space is the stable `spaceId`. If only its `spaceIndex` or display
/// changes (Spaces were reordered), the assignment is updated without an enter/leave event.
public final class SpaceTracker {
    public private(set) var assignments: [String: SpaceAssignment] = [:]
    public let paths: SemaphorePaths
    public let log: JSONLLog
    private let locator: SpaceLocator
    private let now: () -> Date
    private var started = false

    public init(paths: SemaphorePaths, locator: SpaceLocator, now: @escaping () -> Date = Date.init) {
        self.paths = paths
        self.log = JSONLLog(url: paths.spacesLog)
        self.locator = locator
        self.now = now
    }

    /// Loads the assignments saved by the previous run and logs `tracker_start`. The next
    /// `update` logs `leave` for sessions that ended or moved while the app wasn't running.
    public func start() {
        guard !started else { return }
        started = true
        if let data = FileManager.default.contents(atPath: paths.spacesState.path),
           let file = try? JSONLLog.makeDecoder().decode(SpacesStateFile.self, from: data) {
            assignments = file.sessions
        }
        let timestamp = now()
        try? log.append(SpaceLogRecord(ts: timestamp, event: .trackerStart), now: timestamp)
    }

    /// Logs `tracker_stop`. Assignments stay in the state file for the next `start`.
    public func stop() {
        guard started else { return }
        started = false
        let timestamp = now()
        try? log.append(SpaceLogRecord(ts: timestamp, event: .trackerStop), now: timestamp)
    }

    /// Locates the given (currently running) sessions and records any changes.
    /// Returns true if the assignments changed.
    @discardableResult
    public func update(sessions: [ClaudeInstance]) -> Bool {
        guard let located = locator.locate(sessions) else { return false }

        let cwds = Dictionary(sessions.map { ($0.id, $0.project) }, uniquingKeysWith: { first, _ in first })
        let timestamp = now()
        let (next, events) = Self.reconcile(previous: assignments, located: located, cwds: cwds, at: timestamp)
        guard next != assignments else { return false }

        for event in events {
            try? log.append(event, now: timestamp)
        }
        assignments = next
        persist(at: timestamp)
        return true
    }

    /// Computes the next assignments and the enter/leave events that lead to them.
    static func reconcile(
        previous: [String: SpaceAssignment],
        located: [String: SpaceLocation],
        cwds: [String: String],
        at timestamp: Date
    ) -> (assignments: [String: SpaceAssignment], events: [SpaceLogRecord]) {
        var next: [String: SpaceAssignment] = [:]
        var events: [SpaceLogRecord] = []

        for (id, old) in previous.sorted(by: { $0.key < $1.key }) where located[id]?.spaceId != old.spaceId {
            events.append(SpaceLogRecord(event: .leave, sessionId: id, assignment: old, at: timestamp))
        }

        for (id, location) in located.sorted(by: { $0.key < $1.key }) {
            if var current = previous[id], current.spaceId == location.spaceId {
                current.spaceIndex = location.spaceIndex
                current.displayId = location.displayId
                current.cwd = cwds[id] ?? current.cwd
                next[id] = current
            } else {
                let assignment = SpaceAssignment(location: location, since: timestamp, cwd: cwds[id])
                next[id] = assignment
                events.append(SpaceLogRecord(event: .enter, sessionId: id, assignment: assignment, at: timestamp))
            }
        }

        return (next, events)
    }

    private func persist(at timestamp: Date) {
        let file = SpacesStateFile(updated: timestamp, sessions: assignments)
        let encoder = JSONLLog.makeEncoder()
        encoder.outputFormatting.insert(.prettyPrinted)
        guard let data = try? encoder.encode(file) else { return }
        try? FileManager.default.createDirectory(at: paths.spacesDirectory, withIntermediateDirectories: true)
        try? data.write(to: paths.spacesState, options: .atomic)
    }
}
