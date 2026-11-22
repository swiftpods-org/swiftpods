// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftPods",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "swiftpods", targets: ["swiftpods"])],
    targets: [
        .systemLibrary(name: "CLibArchive"),
        .target(name: "SwiftPodsManifest"),
        .target(name: "SwiftPodsXcode"),
        .target(name: "SwiftPodsKit", dependencies: ["CLibArchive", "SwiftPodsManifest", "SwiftPodsXcode"]),
        .executableTarget(name: "swiftpods", dependencies: ["SwiftPodsKit", "SwiftPodsManifest"]),
        .target(name: "SwiftPodsTestSupport", path: "Tests/SwiftPodsTestSupport"),
        .testTarget(name: "SwiftPodsManifestTests", dependencies: ["SwiftPodsManifest"]),
        .testTarget(
            name: "SwiftPodsXcodeTests",
            dependencies: ["SwiftPodsXcode", "SwiftPodsTestSupport"]),
        .testTarget(
            name: "SwiftPodsKitTests",
            dependencies: ["SwiftPodsKit", "SwiftPodsTestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)
