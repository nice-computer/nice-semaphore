import XCTest
import NiceSemaphoreSessions
@testable import NiceSemaphoreSpaces

private final class FakeLocator: SpaceLocator {
    var result: [String: SpaceLocation]? = [:]
    func locate(_ sessions: [ClaudeInstance]) -> [String: SpaceLocation]? {
        result
    }
}

final class SpaceTrackerTests: XCTestCase {
    private var root: URL!
    private var paths: SemaphorePaths!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private let locator = FakeLocator()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        paths = SemaphorePaths(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeTracker() -> SpaceTracker {
        SpaceTracker(paths: paths, locator: locator, now: { self.clock })
    }

    private func session(_ id: String, project: String = "/tmp/p") -> ClaudeInstance {
        ClaudeInstance(id: id, status: .idle, project: project, lastUpdate: clock, pid: 1, tty: "/dev/tty-\(id)")
    }

    private func events(_ tracker: SpaceTracker) -> [String] {
        tracker.log.records(as: SpaceLogRecord.self).map { record in
            [record.event.rawValue, record.sessionId, record.spaceId.map(String.init)].compactMap { $0 }.joined(separator: ":")
        }
    }

    private let space1 = SpaceLocation(spaceId: 11, spaceIndex: 1, displayId: "D")
    private let space2 = SpaceLocation(spaceId: 22, spaceIndex: 2, displayId: "D")

    // MARK: - Tracking

    func testFirstSightingLogsEnter() {
        let tracker = makeTracker()
        tracker.start()
        locator.result = ["a": space1]

        XCTAssertTrue(tracker.update(sessions: [session("a", project: "/tmp/a")]))

        XCTAssertEqual(tracker.assignments["a"], SpaceAssignment(location: space1, since: clock, cwd: "/tmp/a"))
        XCTAssertEqual(events(tracker), ["tracker_start", "enter:a:11"])
    }

    func testUnchangedLocationLogsNothing() {
        let tracker = makeTracker()
        locator.result = ["a": space1]
        tracker.update(sessions: [session("a")])

        clock += 60
        XCTAssertFalse(tracker.update(sessions: [session("a")]))

        XCTAssertEqual(tracker.assignments["a"]?.since, clock - 60)
        XCTAssertEqual(events(tracker), ["enter:a:11"])
    }

    func testMovingToAnotherSpaceLogsLeaveThenEnter() {
        let tracker = makeTracker()
        locator.result = ["a": space1]
        tracker.update(sessions: [session("a")])

        clock += 60
        locator.result = ["a": space2]
        tracker.update(sessions: [session("a")])

        XCTAssertEqual(tracker.assignments["a"]?.spaceId, 22)
        XCTAssertEqual(tracker.assignments["a"]?.since, clock)
        XCTAssertEqual(events(tracker), ["enter:a:11", "leave:a:11", "enter:a:22"])
    }

    func testReorderingSpacesUpdatesIndexWithoutEvents() {
        let tracker = makeTracker()
        locator.result = ["a": space1]
        tracker.update(sessions: [session("a")])

        locator.result = ["a": SpaceLocation(spaceId: 11, spaceIndex: 3, displayId: "D")]
        XCTAssertTrue(tracker.update(sessions: [session("a")]))

        XCTAssertEqual(tracker.assignments["a"]?.spaceIndex, 3)
        XCTAssertEqual(events(tracker), ["enter:a:11"])
    }

    func testEndedSessionLogsLeave() {
        let tracker = makeTracker()
        locator.result = ["a": space1, "b": space2]
        tracker.update(sessions: [session("a"), session("b")])

        locator.result = ["b": space2]
        tracker.update(sessions: [session("b")])

        XCTAssertNil(tracker.assignments["a"])
        XCTAssertEqual(events(tracker), ["enter:a:11", "enter:b:22", "leave:a:11"])
    }

    func testFailedLocateKeepsAssignments() {
        let tracker = makeTracker()
        locator.result = ["a": space1]
        tracker.update(sessions: [session("a")])

        locator.result = nil
        XCTAssertFalse(tracker.update(sessions: [session("a")]))

        XCTAssertEqual(tracker.assignments["a"]?.spaceId, 11)
        XCTAssertEqual(events(tracker), ["enter:a:11"])
    }

    // MARK: - Persistence

    func testStatePersistsAcrossRestartAndClosesSessionsThatEnded() throws {
        let first = makeTracker()
        first.start()
        locator.result = ["a": space1, "b": space2]
        first.update(sessions: [session("a"), session("b")])
        first.stop()

        let stateText = try String(contentsOf: paths.spacesState, encoding: .utf8)
        XCTAssertTrue(stateText.contains("\"spaceId\" : 11"), stateText)

        // "a" ended while the app wasn't running
        clock += 3600
        let second = makeTracker()
        second.start()
        XCTAssertEqual(second.assignments.count, 2)
        locator.result = ["b": space2]
        second.update(sessions: [session("b")])

        XCTAssertEqual(second.assignments["b"]?.since, clock - 3600, "b stayed put across the restart")
        XCTAssertEqual(events(second), [
            "tracker_start", "enter:a:11", "enter:b:22", "tracker_stop",
            "tracker_start", "leave:a:11",
        ])
    }

    func testStartAndStopAreIdempotent() {
        let tracker = makeTracker()
        tracker.start()
        tracker.start()
        tracker.stop()
        tracker.stop()

        XCTAssertEqual(events(tracker), ["tracker_start", "tracker_stop"])
    }

    func testLogRecordsCarryFullLocation() throws {
        let tracker = makeTracker()
        locator.result = ["a": space1]
        tracker.update(sessions: [session("a", project: "/tmp/a")])

        let record = try XCTUnwrap(tracker.log.records(as: SpaceLogRecord.self).first)
        XCTAssertEqual(record, SpaceLogRecord(ts: clock, event: .enter, sessionId: "a", spaceId: 11, spaceIndex: 1, displayId: "D", cwd: "/tmp/a"))
        XCTAssertEqual(record.v, 1)
    }
}
