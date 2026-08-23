// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Remacable",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Remacable",
            path: "Sources/Remacable",
            resources: [.process("Localization")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "RemacableTests", dependencies: ["Remacable"])
    ]
)
