import Foundation
import AppKit

/// Detects which macOS Space a window is on using private CGS APIs
enum SpaceDetector {
    /// Get space numbers for Claude instances by matching their TTYs to iTerm2 windows
    static func getSpaceNumbers(for instances: [ClaudeInstance]) -> [String: Int] {
        var result: [String: Int] = [:]

        // Check if CGS APIs are available
        guard CGSFunctions.isAvailable else {
            return result
        }

        // Get iTerm2 window -> TTY mapping via AppleScript
        guard let windowTtyMap = getITermWindowTtyMap() else {
            return result
        }

        // Get space ID to user-visible index mapping
        guard let spaceIdToIndex = getSpaceIdToIndexMap() else {
            return result
        }

        // Match instances to spaces via TTY -> window -> space
        for instance in instances {
            guard let tty = instance.tty,
                  let windowId = windowTtyMap[tty],
                  let spaceId = getSpaceIdForWindow(CGWindowID(windowId)),
                  let spaceNum = spaceIdToIndex[spaceId] else {
                continue
            }
            result[instance.id] = spaceNum
        }

        return result
    }

    // MARK: - Private

    private static func getITermWindowTtyMap() -> [String: Int]? {
        let script = """
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
            """

        guard let appleScript = NSAppleScript(source: script) else {
            return nil
        }

        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)

        if error != nil {
            return nil
        }

        guard let output = result.stringValue else {
            return nil
        }

        // Parse "windowId:tty" lines
        var map: [String: Int] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":")
            if parts.count >= 2,
               let windowId = Int(parts[0]) {
                // TTY comes as /dev/ttysXXX, join remaining parts in case path has colons
                let tty = parts[1...].joined(separator: ":")
                map[tty] = windowId
            }
        }

        return map
    }

    private static func getSpaceIdToIndexMap() -> [Int: Int]? {
        guard let conn = CGSFunctions.getConnection(),
              let copySpacesFn = CGSFunctions.copyManagedDisplaySpaces,
              let displaySpaces = copySpacesFn(conn) as? [[String: Any]],
              let firstDisplay = displaySpaces.first,
              let spaces = firstDisplay["Spaces"] as? [[String: Any]] else {
            return nil
        }

        var map: [Int: Int] = [:]
        for (index, space) in spaces.enumerated() {
            if let spaceId = space["ManagedSpaceID"] as? Int {
                map[spaceId] = index + 1  // 1-indexed for user display
            }
        }

        return map
    }

    private static func getSpaceIdForWindow(_ windowId: CGWindowID) -> Int? {
        guard let conn = CGSFunctions.getConnection(),
              let copySpacesForWindowsFn = CGSFunctions.copySpacesForWindows else {
            return nil
        }

        let windowIds = [windowId] as CFArray
        guard let spaceIds = copySpacesForWindowsFn(conn, 0x7, windowIds) as? [Int],
              let spaceId = spaceIds.first else {
            return nil
        }

        return spaceId
    }
}

// MARK: - Private CGS API (loaded dynamically)

private typealias CGSConnectionID = UInt32

private enum CGSFunctions {
    static let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)

    static let mainConnectionID: (@convention(c) () -> CGSConnectionID)? = {
        guard let handle = handle, let sym = dlsym(handle, "CGSMainConnectionID") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) () -> CGSConnectionID).self)
    }()

    static let copyManagedDisplaySpaces: (@convention(c) (CGSConnectionID) -> CFArray?)? = {
        guard let handle = handle, let sym = dlsym(handle, "CGSCopyManagedDisplaySpaces") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (CGSConnectionID) -> CFArray?).self)
    }()

    static let copySpacesForWindows: (@convention(c) (CGSConnectionID, Int, CFArray) -> CFArray?)? = {
        guard let handle = handle, let sym = dlsym(handle, "CGSCopySpacesForWindows") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (CGSConnectionID, Int, CFArray) -> CFArray?).self)
    }()

    static var isAvailable: Bool {
        return mainConnectionID != nil && copyManagedDisplaySpaces != nil && copySpacesForWindows != nil
    }

    static func getConnection() -> CGSConnectionID? {
        guard let fn = mainConnectionID else { return nil }
        let conn = fn()
        return conn != 0 ? conn : nil
    }
}
