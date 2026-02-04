// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NiceSemaphore",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "NiceSemaphore",
            path: "Sources/NiceSemaphore"
        )
    ]
)
