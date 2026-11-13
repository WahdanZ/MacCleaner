// swift-tools-version: 6.0
// MacCleanerKit: the app's local package (see docs/architecture/ARCHITECTURE_V2.md).
// MacCleanerCore holds pure rules and models: Foundation (and CryptoKit for the plan digest) only, no file system
// access. MacCleanerPlatform does the file operations; MacCleanerFeatures holds the cleanup executor. Swift 6
// language mode throughout.
import PackageDescription

let package = Package(
    name: "MacCleanerKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacCleanerCore", targets: ["MacCleanerCore"]),
        .library(name: "MacCleanerPlatform", targets: ["MacCleanerPlatform"]),
        .library(name: "MacCleanerFeatures", targets: ["MacCleanerFeatures"]),
    ],
    targets: [
        .target(name: "MacCleanerCore"),
        .target(name: "MacCleanerPlatform", dependencies: ["MacCleanerCore"]),
        .target(name: "MacCleanerFeatures", dependencies: ["MacCleanerCore", "MacCleanerPlatform"]),
        .testTarget(name: "MacCleanerCoreTests", dependencies: ["MacCleanerCore"]),
        .testTarget(name: "MacCleanerPlatformTests", dependencies: ["MacCleanerCore", "MacCleanerPlatform"]),
        .testTarget(name: "MacCleanerFeaturesTests",
                    dependencies: ["MacCleanerCore", "MacCleanerPlatform", "MacCleanerFeatures"]),
    ]
)
