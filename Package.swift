// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "KaraokeMaker",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "KaraokeMaker"),
        .testTarget(name: "KaraokeMakerTests", dependencies: ["KaraokeMaker"]),
    ],
    swiftLanguageModes: [.v5]
)
