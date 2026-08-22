// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SendToReMarkable",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SendToReMarkable",
            path: "Sources/SendToReMarkable",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
