// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NiceSemaphore",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Piece 1: which Claude Code sessions exist and what they're doing.
        .target(
            name: "NiceSemaphoreSessions",
            path: "Sources/NiceSemaphoreSessions"
        ),
        // Piece 2: which macOS Space each session is on. Depends on piece 1.
        .target(
            name: "NiceSemaphoreSpaces",
            dependencies: ["NiceSemaphoreSessions"],
            path: "Sources/NiceSemaphoreSpaces"
        ),
        // Menu bar UI. Reads both pieces, owns no data.
        .executableTarget(
            name: "NiceSemaphore",
            dependencies: ["NiceSemaphoreSessions", "NiceSemaphoreSpaces"],
            path: "Sources/NiceSemaphore"
        ),
        .testTarget(
            name: "NiceSemaphoreSessionsTests",
            dependencies: ["NiceSemaphoreSessions"],
            path: "Tests/NiceSemaphoreSessionsTests"
        ),
        .testTarget(
            name: "NiceSemaphoreSpacesTests",
            dependencies: ["NiceSemaphoreSpaces"],
            path: "Tests/NiceSemaphoreSpacesTests"
        ),
    ]
)
