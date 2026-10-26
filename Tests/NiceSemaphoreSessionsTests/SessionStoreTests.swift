import XCTest
@testable import NiceSemaphoreSessions

final class SessionStoreTests: XCTestCase {
    private var root: URL!
    private var paths: SemaphorePaths!
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = SemaphorePaths(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore(alive: Set<Int> = []) -> SessionStore {
        SessionStore(paths: paths, isProcessAlive: { alive.contains($0) }, now: { self.fixedNow })
    }

    private func writeState(_ json: String) throws {
        try FileManager.default.createDirectory(at: paths.sessionsDirectory, withIntermediateDirectories: true)
        try json.write(to: paths.sessionsState, atomically: true, encoding: .utf8)
    }

    private func rawSessions() throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: paths.sessionsState)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["sessions"] as? [String: [String: Any]])
    }

    // Format written by hooks/nice-semaphore-status.sh
    private let hookState = """
        {"v":1,"sessions":{
          "alive":{"status":"working","project":"/tmp/a","lastUpdate":"2026-10-26T10:00:00Z","pid":100,"terminalPid":1,"tty":"/dev/ttys001","pendingQuestion":true},
          "dead":{"status":"idle","project":"/tmp/b","lastUpdate":"2026-10-26T11:00:00Z","pid":200,"terminalPid":0,"tty":"","pendingQuestion":false}
        }}
        """

    // MARK: - Paths

    func testPathsUseEnvironmentOverride() {
        let resolved = SemaphorePaths.resolve(environment: ["NICE_SEMAPHORE_HOME": "/x/y"], home: URL(fileURLWithPath: "/home/me"))
        XCTAssertEqual(resolved.sessionsState.path, "/x/y/sessions/state.json")
        XCTAssertEqual(resolved.spacesLog.path, "/x/y/spaces/log.jsonl")
    }

    func testPathsDefaultToApplicationSupport() {
        let resolved = SemaphorePaths.resolve(environment: [:], home: URL(fileURLWithPath: "/home/me"))
        XCTAssertEqual(resolved.sessionsLog.path, "/home/me/Library/Application Support/NiceSemaphore/sessions/log.jsonl")
        XCTAssertEqual(SemaphorePaths.legacyStatusFile(home: URL(fileURLWithPath: "/home/me")).path, "/home/me/.claude/nice-semaphore-status.json")
    }

    // MARK: - Loading

    func testLoadSessionsDecodesHookFormat() throws {
        try writeState(hookState)

        let sessions = try XCTUnwrap(makeStore().loadSessions())

        XCTAssertEqual(sessions.map(\.id), ["dead", "alive"])  // most recent first
        XCTAssertEqual(sessions[1].status, .working)
        XCTAssertEqual(sessions[1].pid, 100)
        XCTAssertEqual(sessions[1].tty, "/dev/ttys001")
        XCTAssertNil(sessions[0].tty, "empty TTY means unknown")
    }

    func testLoadSessionsReturnsNilForMissingOrCorruptFile() throws {
        XCTAssertNil(makeStore().loadSessions())
        try writeState("not json")
        XCTAssertNil(makeStore().loadSessions())
    }

    func testPrepareCreatesEmptyState() throws {
        makeStore().prepare()
        XCTAssertEqual(makeStore().loadSessions(), [])
    }

    func testPrepareKeepsExistingState() throws {
        try writeState(hookState)
        makeStore().prepare()
        XCTAssertEqual(makeStore().loadSessions()?.count, 2)
    }

    // MARK: - Reaping

    func testReapRemovesDeadSessionsAndPreservesOtherFields() throws {
        try writeState(hookState)

        let reaped = makeStore(alive: [100]).reapDeadSessions()

        XCTAssertEqual(reaped, ["dead"])
        let sessions = try rawSessions()
        XCTAssertEqual(Array(sessions.keys), ["alive"])
        XCTAssertEqual(sessions["alive"]?["pendingQuestion"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.sessionsLock.path), "lock released")
    }

    func testReapLogsReapedEvent() throws {
        try writeState(hookState)
        let store = makeStore(alive: [100])

        store.reapDeadSessions()

        let records = store.log.records(as: SessionLogRecord.self)
        XCTAssertEqual(records, [
            SessionLogRecord(ts: fixedNow, sessionId: "dead", event: "reaped", status: nil, prevStatus: "idle", cwd: "/tmp/b", pid: 200, tty: nil)
        ])
    }

    func testReapWithNothingDeadLeavesFileUntouched() throws {
        try writeState(hookState)
        let before = try Data(contentsOf: paths.sessionsState)

        XCTAssertEqual(makeStore(alive: [100, 200]).reapDeadSessions(), [])

        XCTAssertEqual(try Data(contentsOf: paths.sessionsState), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.sessionsLog.path))
    }

    // MARK: - Legacy import

    private func writeLegacy(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
            {"instances":{
              "old-alive":{"status":"idle","project":"/tmp/old","lastUpdate":"2026-10-26T09:00:00Z","pid":300,"terminalPid":1,"tty":"/dev/ttys003"},
              "old-dead":{"status":"idle","project":"/tmp/gone","lastUpdate":"2026-10-26T09:00:00Z","pid":400,"terminalPid":1,"tty":"/dev/ttys004"},
              "alive":{"status":"idle","project":"/tmp/stale","lastUpdate":"2026-10-26T09:00:00Z","pid":100,"terminalPid":1,"tty":"/dev/ttys001"}
            }}
            """.write(to: url, atomically: true, encoding: .utf8)
    }

    func testImportLegacyCopiesLiveSessionsAndDeletesLegacyFile() throws {
        try writeState(hookState)
        let legacy = root.appendingPathComponent(".claude/nice-semaphore-status.json")
        try writeLegacy(at: legacy)
        let store = makeStore(alive: [100, 200, 300])

        let imported = store.importLegacyStatusFile(at: legacy)

        XCTAssertEqual(imported, ["old-alive"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        let sessions = try rawSessions()
        XCTAssertEqual(Set(sessions.keys), ["alive", "dead", "old-alive"])
        XCTAssertEqual(sessions["alive"]?["project"] as? String, "/tmp/a", "current state wins")
        XCTAssertEqual(store.log.records(as: SessionLogRecord.self).map(\.event), ["imported"])
    }

    func testImportLegacyWithoutCurrentStateCreatesIt() throws {
        let legacy = root.appendingPathComponent(".claude/nice-semaphore-status.json")
        try writeLegacy(at: legacy)

        let imported = makeStore(alive: [300]).importLegacyStatusFile(at: legacy)

        XCTAssertEqual(imported, ["old-alive"])
        XCTAssertEqual(makeStore().loadSessions()?.map(\.id), ["old-alive"])
    }

    func testImportLegacyWithoutLegacyFileDoesNothing() throws {
        XCTAssertEqual(makeStore().importLegacyStatusFile(at: root.appendingPathComponent("missing.json")), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.sessionsState.path))
    }

    // MARK: - Hook contract

    /// Runs the real hook script and checks the store reads what it writes.
    func testStoreReadsStateWrittenByHookScript() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/jq") else {
            throw XCTSkip("hook script requires /usr/bin/jq")
        }
        let hook = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("hooks/nice-semaphore-status.sh")

        func runHook(_ json: String) throws {
            let process = Process()
            process.executableURL = hook
            process.environment = ["NICE_SEMAPHORE_HOME": root.path, "PATH": "/usr/bin:/bin"]
            let input = Pipe()
            process.standardInput = input
            try process.run()
            input.fileHandleForWriting.write(Data(json.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }

        try runHook(#"{"session_id":"s1","cwd":"/tmp/project","hook_event_name":"SessionStart"}"#)
        try runHook(#"{"session_id":"s1","cwd":"/tmp/project","hook_event_name":"UserPromptSubmit"}"#)

        // The hook's parent (this test process) is the "claude" pid, so the session is alive
        let store = SessionStore(paths: paths)
        XCTAssertEqual(store.reapDeadSessions(), [])
        let sessions = try XCTUnwrap(store.loadSessions())
        XCTAssertEqual(sessions.map(\.id), ["s1"])
        XCTAssertEqual(sessions[0].status, .working)
        XCTAssertEqual(sessions[0].pid, Int(ProcessInfo.processInfo.processIdentifier))

        let records = store.log.records(as: SessionLogRecord.self)
        XCTAssertEqual(records.map(\.event), ["SessionStart", "UserPromptSubmit"])
        XCTAssertEqual(records.last?.prevStatus, "idle")
    }
}
