import Foundation

/// Reads and maintains the session state written by the hook script.
///
/// The hook owns `sessions/state.json` and `sessions/log.jsonl`; this store only reads them, plus
/// two writes the hook can't do itself: removing sessions whose process died without a
/// `SessionEnd` event, and migrating the legacy status file. Both take the hook's lock and
/// rewrite the state as raw JSON so fields this store doesn't model are preserved.
public final class SessionStore {
    public let paths: SemaphorePaths
    public let log: JSONLLog
    private let lock: DirectoryLock
    private let isProcessAlive: (Int) -> Bool
    private let now: () -> Date

    public init(
        paths: SemaphorePaths,
        isProcessAlive: @escaping (Int) -> Bool = SessionStore.processExists,
        now: @escaping () -> Date = Date.init
    ) {
        self.paths = paths
        self.log = JSONLLog(url: paths.sessionsLog)
        self.lock = DirectoryLock(url: paths.sessionsLock)
        self.isProcessAlive = isProcessAlive
        self.now = now
    }

    public static func processExists(_ pid: Int) -> Bool {
        // kill with signal 0 checks if process exists without sending a signal
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    /// Creates the sessions directory and an empty state file if they don't exist.
    public func prepare() {
        try? FileManager.default.createDirectory(at: paths.sessionsDirectory, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: paths.sessionsState.path) else { return }
        lock.withLock {
            if !FileManager.default.fileExists(atPath: paths.sessionsState.path) {
                writeRawState(Self.emptyState)
            }
        }
    }

    /// Current sessions, most recently updated first, or nil if the state file can't be read.
    public func loadSessions() -> [ClaudeInstance]? {
        guard let data = FileManager.default.contents(atPath: paths.sessionsState.path),
              let file = try? JSONLLog.makeDecoder().decode(SessionsStateFile.self, from: data) else {
            return nil
        }
        return file.toInstances()
    }

    /// Removes sessions whose process is gone (SessionEnd doesn't fire on crashes or kills) and
    /// logs a `reaped` event for each. Returns the removed session IDs.
    @discardableResult
    public func reapDeadSessions() -> [String] {
        lock.withLock {
            guard var root = readRawState(), var sessions = root["sessions"] as? [String: Any] else {
                return []
            }

            var reaped: [(id: String, entry: [String: Any])] = []
            for (id, value) in sessions {
                guard let entry = value as? [String: Any],
                      let pid = Self.int(entry["pid"]), pid > 0,
                      !isProcessAlive(pid) else {
                    continue
                }
                sessions.removeValue(forKey: id)
                reaped.append((id, entry))
            }
            guard !reaped.isEmpty else { return [] }

            root["sessions"] = sessions
            writeRawState(root)

            let timestamp = now()
            for (id, entry) in reaped.sorted(by: { $0.id < $1.id }) {
                try? log.append(Self.record(for: id, entry: entry, event: "reaped", status: nil, prevStatus: entry["status"] as? String, at: timestamp), now: timestamp)
            }
            return reaped.map(\.id).sorted()
        }
    }

    /// Moves live sessions from the legacy `~/.claude/nice-semaphore-status.json` into the
    /// current state file, logs an `imported` event for each, and deletes the legacy file.
    /// Sessions already in the current state file win. Returns the imported session IDs.
    @discardableResult
    public func importLegacyStatusFile(at legacyURL: URL) -> [String] {
        guard let data = FileManager.default.contents(atPath: legacyURL.path) else { return [] }
        defer {
            try? FileManager.default.removeItem(at: legacyURL)
            // Lock directory used by the legacy hook
            rmdir(legacyURL.deletingPathExtension().appendingPathExtension("lock").path)
        }
        guard let legacy = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let instances = legacy["instances"] as? [String: Any] else {
            return []
        }

        return lock.withLock {
            var root = readRawState() ?? Self.emptyState
            var sessions = root["sessions"] as? [String: Any] ?? [:]

            var imported: [(id: String, entry: [String: Any])] = []
            for (id, value) in instances {
                guard sessions[id] == nil,
                      let entry = value as? [String: Any],
                      let pid = Self.int(entry["pid"]), pid > 0,
                      isProcessAlive(pid) else {
                    continue
                }
                sessions[id] = entry
                imported.append((id, entry))
            }
            guard !imported.isEmpty else { return [] }

            root["sessions"] = sessions
            writeRawState(root)

            let timestamp = now()
            for (id, entry) in imported.sorted(by: { $0.id < $1.id }) {
                try? log.append(Self.record(for: id, entry: entry, event: "imported", status: entry["status"] as? String, prevStatus: nil, at: timestamp), now: timestamp)
            }
            return imported.map(\.id).sorted()
        }
    }

    // MARK: - Private

    private static var emptyState: [String: Any] { ["v": 1, "sessions": [String: Any]()] }

    private func readRawState() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: paths.sessionsState.path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["sessions"] is [String: Any] else {
            return nil
        }
        return root
    }

    private func writeRawState(_ root: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: paths.sessionsState, options: .atomic)
    }

    private static func record(for id: String, entry: [String: Any], event: String, status: String?, prevStatus: String?, at timestamp: Date) -> SessionLogRecord {
        let tty = entry["tty"] as? String
        return SessionLogRecord(
            ts: timestamp,
            sessionId: id,
            event: event,
            status: status,
            prevStatus: prevStatus,
            cwd: entry["project"] as? String,
            pid: int(entry["pid"]),
            tty: tty?.isEmpty == true ? nil : tty
        )
    }

    private static func int(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        return (value as? NSNumber)?.intValue
    }
}
