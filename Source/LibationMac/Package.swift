// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LibationMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LibationMac",
            path: "Sources/LibationMac",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)
