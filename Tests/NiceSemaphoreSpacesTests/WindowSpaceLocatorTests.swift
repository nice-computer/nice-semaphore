import XCTest
import NiceSemaphoreSessions
@testable import NiceSemaphoreSpaces

private struct FakeTerminal: TerminalWindowResolver {
    var windows: [String: UInt32]?
    func windowIds(forTTYs ttys: Set<String>) -> [String: UInt32]? {
        windows?.filter { ttys.contains($0.key) }
    }
}

private final class FakeSpaces: WindowSpaceResolver {
    var locations: [UInt32: SpaceLocation]?
    var queried: Set<UInt32>?
    init(_ locations: [UInt32: SpaceLocation]?) { self.locations = locations }
    func locations(ofWindows windowIds: Set<UInt32>) -> [UInt32: SpaceLocation]? {
        queried = windowIds
        return locations?.filter { windowIds.contains($0.key) }
    }
}

final class WindowSpaceLocatorTests: XCTestCase {
    private func session(_ id: String, tty: String?) -> ClaudeInstance {
        ClaudeInstance(id: id, status: .idle, project: "/tmp", lastUpdate: Date(), tty: tty)
    }

    private let here = SpaceLocation(spaceId: 5, spaceIndex: 2, displayId: "D")

    func testMapsSessionsThroughTTYAndWindow() {
        let spaces = FakeSpaces([42: here])
        let locator = WindowSpaceLocator(terminals: [FakeTerminal(windows: ["/dev/ttys001": 42, "/dev/ttys009": 99])], spaces: spaces)

        let result = locator.locate([session("a", tty: "/dev/ttys001"), session("b", tty: "/dev/ttys002"), session("c", tty: nil)])

        XCTAssertEqual(result, ["a": here])
        XCTAssertEqual(spaces.queried, [42], "only windows hosting sessions are queried")
    }

    func testMergesMultipleTerminals() {
        let locator = WindowSpaceLocator(
            terminals: [FakeTerminal(windows: ["/dev/ttys001": 1]), FakeTerminal(windows: ["/dev/ttys002": 2])],
            spaces: FakeSpaces([1: here, 2: here])
        )

        XCTAssertEqual(locator.locate([session("a", tty: "/dev/ttys001"), session("b", tty: "/dev/ttys002")])?.keys.sorted(), ["a", "b"])
    }

    func testFailsWhenNoTerminalAnswers() {
        let locator = WindowSpaceLocator(terminals: [FakeTerminal(windows: nil)], spaces: FakeSpaces([:]))

        XCTAssertNil(locator.locate([session("a", tty: "/dev/ttys001")]))
    }

    func testFailsWhenSpacesCannotBeQueried() {
        let locator = WindowSpaceLocator(terminals: [FakeTerminal(windows: ["/dev/ttys001": 1])], spaces: FakeSpaces(nil))

        XCTAssertNil(locator.locate([session("a", tty: "/dev/ttys001")]))
    }

    func testNoSessionsWithTTYsLocatesNothing() {
        let spaces = FakeSpaces(nil)
        let locator = WindowSpaceLocator(terminals: [FakeTerminal(windows: nil)], spaces: spaces)

        XCTAssertEqual(locator.locate([session("a", tty: nil)]), [:])
        XCTAssertNil(spaces.queried)
    }
}
