// swift-tools-version: 6.0
// MacCleanerKit: the app's local package (see docs/architecture/ARCHITECTURE_V2.md).
// MacCleanerCore holds pure rules and models: Foundation (and CryptoKit for the plan digest) only, no file system
// access, Swift 6 language mode.
import PackageDescription

let package = Package(
    name: "MacCleanerKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacCleanerCore", targets: ["MacCleanerCore"]),
    ],
    targets: [
        .target(name: "MacCleanerCore"),
        .testTarget(name: "MacCleanerCoreTests", dependencies: ["MacCleanerCore"]),
    ]
)
