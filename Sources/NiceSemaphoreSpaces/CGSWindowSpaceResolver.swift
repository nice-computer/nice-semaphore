#if os(macOS)
import Foundation
import CoreGraphics

/// Detects which macOS Space a window is on using private CGS APIs
public struct CGSWindowSpaceResolver: WindowSpaceResolver {
    public init() {}

    public func locations(ofWindows windowIds: Set<UInt32>) -> [UInt32: SpaceLocation]? {
        // Check if CGS APIs are available
        guard CGSFunctions.isAvailable,
              let conn = CGSFunctions.getConnection(),
              let spacesById = Self.spaces(conn: conn) else {
            return nil
        }

        var result: [UInt32: SpaceLocation] = [:]
        for windowId in windowIds {
            if let spaceId = Self.spaceId(ofWindow: windowId, conn: conn),
               let location = spacesById[spaceId] {
                result[windowId] = location
            }
        }
        return result
    }

    // MARK: - Private

    /// Every Space on every display, numbered 1… in display order.
    private static func spaces(conn: CGSConnectionID) -> [Int: SpaceLocation]? {
        guard let copySpacesFn = CGSFunctions.copyManagedDisplaySpaces,
              let displaySpaces = copySpacesFn(conn)?.takeRetainedValue() as? [[String: Any]] else {
            return nil
        }

        var map: [Int: SpaceLocation] = [:]
        var index = 0
        for display in displaySpaces {
            let displayId = display["Display Identifier"] as? String
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                index += 1  // 1-indexed for user display
                if let spaceId = space["ManagedSpaceID"] as? Int {
                    map[spaceId] = SpaceLocation(spaceId: spaceId, spaceIndex: index, displayId: displayId)
                }
            }
        }
        return map
    }

    private static func spaceId(ofWindow windowId: UInt32, conn: CGSConnectionID) -> Int? {
        guard let copySpacesForWindowsFn = CGSFunctions.copySpacesForWindows else {
            return nil
        }

        let windowIds = [windowId] as CFArray
        guard let spaceIds = copySpacesForWindowsFn(conn, 0x7, windowIds)?.takeRetainedValue() as? [Int] else {
            return nil
        }
        return spaceIds.first
    }
}

// MARK: - Private CGS API (loaded dynamically)

private typealias CGSConnectionID = UInt32

// The CGSCopy* functions follow the Create rule, so results are taken as retained.
private enum CGSFunctions {
    static let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)

    static let mainConnectionID: (@convention(c) () -> CGSConnectionID)? = {
        guard let handle = handle, let sym = dlsym(handle, "CGSMainConnectionID") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) () -> CGSConnectionID).self)
    }()

    static let copyManagedDisplaySpaces: (@convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?)? = {
        guard let handle = handle, let sym = dlsym(handle, "CGSCopyManagedDisplaySpaces") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?).self)
    }()

    static let copySpacesForWindows: (@convention(c) (CGSConnectionID, Int, CFArray) -> Unmanaged<CFArray>?)? = {
        guard let handle = handle, let sym = dlsym(handle, "CGSCopySpacesForWindows") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (CGSConnectionID, Int, CFArray) -> Unmanaged<CFArray>?).self)
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
#endif
