// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftPods",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "swiftpods", targets: ["swiftpods"])],
    targets: [
        .target(
            name: "ProcessSupport", exclude: ["ArchiveHeaders/LICENSE.txt", "ArchiveHeaders/PROVENANCE.json"],
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("archive.2"), .linkedFramework("CoreFoundation")]),
        .target(name: "SwiftPodsCore", dependencies: ["ProcessSupport"]),
        .executableTarget(name: "swiftpods", dependencies: ["SwiftPodsCore"]),
        .testTarget(name: "SwiftPodsCoreTests", dependencies: ["SwiftPodsCore"]),
    ],
    swiftLanguageModes: [.v5]
)
