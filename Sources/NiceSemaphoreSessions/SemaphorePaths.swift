import Foundation

/// Filesystem layout shared by the hook script, the session store and the space tracker.
///
///     <root>/sessions/state.json   current Claude Code sessions (written by the hook)
///     <root>/sessions/log.jsonl    session event log (hook + reaper)
///     <root>/spaces/state.json     current session → Space assignments (written by the app)
///     <root>/spaces/log.jsonl      Space enter/leave log (written by the app)
///
/// The root is `$NICE_SEMAPHORE_HOME`, or `~/Library/Application Support/NiceSemaphore`.
/// Keep in sync with `hooks/nice-semaphore-status.sh`.
public struct SemaphorePaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> SemaphorePaths {
        if let custom = environment["NICE_SEMAPHORE_HOME"], !custom.isEmpty {
            return SemaphorePaths(root: URL(fileURLWithPath: custom, isDirectory: true))
        }
        return SemaphorePaths(root: home.appendingPathComponent("Library/Application Support/NiceSemaphore", isDirectory: true))
    }

    public var sessionsDirectory: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    public var sessionsState: URL { sessionsDirectory.appendingPathComponent("state.json") }
    public var sessionsLog: URL { sessionsDirectory.appendingPathComponent("log.jsonl") }
    public var sessionsLock: URL { sessionsDirectory.appendingPathComponent(".lock", isDirectory: true) }

    public var spacesDirectory: URL { root.appendingPathComponent("spaces", isDirectory: true) }
    public var spacesState: URL { spacesDirectory.appendingPathComponent("state.json") }
    public var spacesLog: URL { spacesDirectory.appendingPathComponent("log.jsonl") }

    /// Status file used before sessions moved under the semaphore root (plugin < 0.2).
    public static func legacyStatusFile(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".claude/nice-semaphore-status.json")
    }
}
