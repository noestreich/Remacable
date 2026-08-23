// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Remacable",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Remacable",
            path: "Sources/Remacable",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "RemacableTests", dependencies: ["Remacable"])
    ]
)
