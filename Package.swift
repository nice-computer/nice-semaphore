// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NiceToast",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "NiceToast",
            path: "Sources/NiceToast"
        )
    ]
)
