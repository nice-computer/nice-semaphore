#if os(macOS)
import AppKit

/// Maps TTYs to iTerm2 window IDs via AppleScript. iTerm2's window `id` is the CGWindowID.
public final class ITermWindowResolver: TerminalWindowResolver {
    public static let bundleIdentifier = "com.googlecode.iterm2"

    // AppleScript is slow, so the map is cached
    private let cacheInterval: TimeInterval
    private var cachedMap: [String: UInt32]?
    private var cachedTTYs: Set<String> = []
    private var lastRefresh: Date?
    private var script: NSAppleScript?

    public init(cacheInterval: TimeInterval = 1.0) {
        self.cacheInterval = cacheInterval
    }

    public func windowIds(forTTYs ttys: Set<String>) -> [String: UInt32]? {
        // Don't let the AppleScript `tell` launch iTerm2
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty else {
            cachedMap = nil
            return [:]
        }

        // Refresh if: no cache, the set of sessions changed, or cache expired
        let now = Date()
        let needsRefresh = cachedMap == nil
            || ttys != cachedTTYs
            || lastRefresh.map { now.timeIntervalSince($0) >= cacheInterval } ?? true

        if needsRefresh {
            cachedMap = queryWindowTtyMap()
            cachedTTYs = ttys
            lastRefresh = now
        }

        return cachedMap?.filter { ttys.contains($0.key) }
    }

    private func queryWindowTtyMap() -> [String: UInt32]? {
        if script == nil {
            script = NSAppleScript(source: """
                set output to ""
                tell application "iTerm2"
                    set windowList to every window
                    repeat with w in windowList
                        set windowId to id of w
                        set tabList to every tab of w
                        repeat with t in tabList
                            set sessionList to every session of t
                            repeat with s in sessionList
                                set output to output & windowId & ":" & (tty of s) & linefeed
                            end repeat
                        end repeat
                    end repeat
                end tell
                return output
                """)
        }

        guard let appleScript = script else {
            return nil
        }

        return autoreleasepool {
            var error: NSDictionary?
            let result = appleScript.executeAndReturnError(&error)

            if error != nil {
                return nil
            }

            // An empty string (no windows) comes back as nil
            return Self.parse(result.stringValue ?? "")
        }
    }

    /// Parses "windowId:tty" lines.
    static func parse(_ output: String) -> [String: UInt32] {
        var map: [String: UInt32] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":")
            if parts.count >= 2,
               let windowId = UInt32(parts[0]) {
                // TTY comes as /dev/ttysXXX, join remaining parts in case path has colons
                let tty = parts[1...].joined(separator: ":")
                map[tty] = windowId
            }
        }
        return map
    }
}

extension WindowSpaceLocator {
    /// iTerm2 windows located with the CGS Spaces API.
    public static func system() -> WindowSpaceLocator {
        WindowSpaceLocator(terminals: [ITermWindowResolver()], spaces: CGSWindowSpaceResolver())
    }
}
#endif
