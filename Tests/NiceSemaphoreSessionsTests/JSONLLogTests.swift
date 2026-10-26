import XCTest
@testable import NiceSemaphoreSessions

final class JSONLLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private struct Record: Codable, Equatable {
        var n: Int
    }

    func testAppendsOneLinePerRecordAndCreatesDirectory() throws {
        let log = JSONLLog(url: directory.appendingPathComponent("log.jsonl"))

        try log.append(Record(n: 1))
        try log.append(Record(n: 2))

        XCTAssertEqual(try String(contentsOf: log.url, encoding: .utf8), "{\"n\":1}\n{\"n\":2}\n")
        XCTAssertEqual(log.records(as: Record.self), [Record(n: 1), Record(n: 2)])
    }

    func testSkipsUndecodableLines() throws {
        let log = JSONLLog(url: directory.appendingPathComponent("log.jsonl"))
        try log.append(Record(n: 1))
        let handle = try FileHandle(forWritingTo: log.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("garbage\n".utf8))
        try handle.close()
        try log.append(Record(n: 2))

        XCTAssertEqual(log.records(as: Record.self), [Record(n: 1), Record(n: 2)])
    }

    func testRotatesWhenSizeLimitReached() throws {
        let log = JSONLLog(url: directory.appendingPathComponent("log.jsonl"), maxBytes: 1)
        let now = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15T08:00:00Z

        try log.append(Record(n: 1), now: now)
        try log.append(Record(n: 2), now: now)

        XCTAssertEqual(log.records(as: Record.self), [Record(n: 2)])
        let rotated = JSONLLog(url: directory.appendingPathComponent("log-20270115T080000Z.jsonl"))
        XCTAssertEqual(rotated.records(as: Record.self), [Record(n: 1)])
    }

    func testDatesUseSecondPrecisionISO8601LikeTheHook() throws {
        struct Stamped: Codable { var ts: Date }
        let log = JSONLLog(url: directory.appendingPathComponent("log.jsonl"))

        try log.append(Stamped(ts: Date(timeIntervalSince1970: 1_800_000_000)))

        XCTAssertEqual(try String(contentsOf: log.url, encoding: .utf8), "{\"ts\":\"2027-01-15T08:00:00Z\"}\n")
    }
}
