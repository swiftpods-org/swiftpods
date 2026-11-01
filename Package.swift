// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftPods",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "swiftpods", targets: ["swiftpods"])],
    targets: [
        .systemLibrary(name: "CLibArchive"),
        .target(name: "SwiftPodsManifest"),
        .target(name: "SwiftPodsSecurity"),
        .target(name: "SwiftPodsXcode", dependencies: ["SwiftPodsSecurity"]),
        .target(
            name: "SwiftPodsKit",
            dependencies: ["CLibArchive", "SwiftPodsManifest", "SwiftPodsSecurity", "SwiftPodsXcode"]),
        .executableTarget(name: "swiftpods", dependencies: ["SwiftPodsKit", "SwiftPodsManifest"]),
        .target(name: "SwiftPodsTestSupport", path: "Tests/SwiftPodsTestSupport"),
        .testTarget(name: "SwiftPodsManifestTests", dependencies: ["SwiftPodsManifest"]),
        .testTarget(
            name: "SwiftPodsXcodeTests",
            dependencies: ["SwiftPodsSecurity", "SwiftPodsXcode", "SwiftPodsTestSupport"]),
        .testTarget(
            name: "SwiftPodsKitTests",
            dependencies: ["SwiftPodsKit", "SwiftPodsSecurity", "SwiftPodsTestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)
