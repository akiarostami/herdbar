// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Herdbar",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "HerdbarCore"),
        .executableTarget(name: "Herdbar", dependencies: ["HerdbarCore"]),
        .testTarget(name: "HerdbarCoreTests", dependencies: ["HerdbarCore"]),
    ],
    swiftLanguageModes: [.v5]
)
