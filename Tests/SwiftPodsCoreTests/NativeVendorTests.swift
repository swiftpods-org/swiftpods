import XCTest

@testable import SwiftPodsCore

final class NativeVendorTests: XCTestCase {
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: path) }
        return path
    }
    private func macho(platform: UInt32, cpu: UInt32 = 0x0100_000c, subtype: UInt32 = 0, kind: UInt32 = 6) -> Data {
        let words: [UInt32] = [
            0xfeed_facf, cpu, subtype, kind, 1, 24, 0, 0, 0x32, 24, platform, 0x000f_0000, 0x001b_0000, 0,
        ]
        return Data(words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } })
    }
    private func plist(_ value: [String: Any], at path: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: path)
    }
    private func xcframework(_ root: URL, entries: [[String: Any]]) throws -> URL {
        let sdk = root.appendingPathComponent("Kit.xcframework")
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        for entry in entries {
            let identifier = entry["LibraryIdentifier"] as! String
            guard !identifier.contains("..") else { continue }
            let payload = sdk.appendingPathComponent(identifier + "/Kit.framework")
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
            let variant = entry["SupportedPlatformVariant"] as? String
            try macho(platform: variant == "simulator" ? 7 : 2).write(to: payload.appendingPathComponent("Kit"))
        }
        try plist(
            ["XCFrameworkFormatVersion": "1.0", "AvailableLibraries": entries],
            at: sdk.appendingPathComponent("Info.plist"))
        return sdk
    }
    private func entry(_ id: String, variant: String? = nil) -> [String: Any] {
        var result: [String: Any] = [
            "LibraryIdentifier": id, "LibraryPath": "Kit.framework", "SupportedPlatform": "ios",
            "SupportedArchitectures": ["arm64"],
        ]
        if let variant { result["SupportedPlatformVariant"] = variant }
        return result
    }

    private func archive(_ object: Data) -> Data {
        let header =
            "object.o/".padding(toLength: 16, withPad: " ", startingAt: 0)
            + "0".padding(toLength: 12, withPad: " ", startingAt: 0)
            + "0".padding(toLength: 6, withPad: " ", startingAt: 0)
            + "0".padding(toLength: 6, withPad: " ", startingAt: 0)
            + "644".padding(toLength: 8, withPad: " ", startingAt: 0)
            + String(object.count).padding(toLength: 10, withPad: " ", startingAt: 0) + "`\n"
        return Data("!<arch>\n".utf8) + Data(header.utf8) + object
    }

    private func universal(_ objects: [(subtype: UInt32, data: Data)]) -> Data {
        var offset = UInt32(8 + 20 * objects.count)
        var words: [UInt32] = [0xcafe_babe, UInt32(objects.count)]
        for object in objects {
            words += [0x0100_000c, object.subtype, offset, UInt32(object.data.count), 0]
            offset += UInt32(object.data.count)
        }
        let header = Data(
            words.flatMap { word in (0..<4).reversed().map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } })
        return objects.reduce(header) { $0 + $1.data }
    }

    func testMetadataMayAdvertiseSubsetOfUniversalBinaryArchitectures() throws {
        let path = try xcframework(directory(), entries: [entry("device")])
        try universal([
            (0, archive(macho(platform: 2, kind: 1))),
            (2, archive(macho(platform: 2, subtype: 2, kind: 1))),
        ]).write(to: path.appendingPathComponent("device/Kit.framework/Kit"))
        let sdk = try NativeVendorSDK(path)
        XCTAssertFalse(sdk.dynamic)
        XCTAssertEqual(sdk.slices.first?.architectures, ["arm64"])
        XCTAssertEqual(
            try sdk.select(platform: "ios", variant: "device", architectures: ["arm64"]).identifier, "device")
        XCTAssertThrowsError(try sdk.select(platform: "ios", variant: "device", architectures: ["arm64e"]))
    }

    func testExtraArchitecturesCannotHideMismatchedPlatforms() throws {
        let path = try xcframework(directory(), entries: [entry("device")])
        try universal([
            (0, archive(macho(platform: 2, kind: 1))),
            (2, archive(macho(platform: 7, subtype: 2, kind: 1))),
        ]).write(to: path.appendingPathComponent("device/Kit.framework/Kit"))
        XCTAssertThrowsError(try NativeVendorSDK(path)) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCFRAMEWORK-BINARY")
        }
    }

    func testArm64SelectionDistinguishesDeviceAndSimulator() throws {
        let path = try xcframework(directory(), entries: [entry("device"), entry("simulator", variant: "simulator")])
        let sdk = try NativeVendorSDK(path)
        XCTAssertEqual(
            try sdk.select(platform: "ios", variant: "device", architectures: ["arm64"]).identifier, "device")
        XCTAssertEqual(
            try sdk.select(platform: "ios", variant: "simulator", architectures: ["arm64"]).identifier, "simulator")
        XCTAssertThrowsError(try sdk.select(platform: "ios", variant: "maccatalyst", architectures: ["arm64"]))
        XCTAssertThrowsError(try sdk.select(platform: "ios", variant: "simulator", architectures: ["x86_64"]))
        XCTAssertThrowsError(try sdk.select(platform: "ios", variant: "device", architectures: []))
        XCTAssertTrue(sdk.dynamic)
        XCTAssertTrue(sdk.supports(platform: "ios"))
        XCTAssertFalse(sdk.supports(platform: "osx"))
    }

    func testBinaryOnlyPodsDoNotShadowTheirVendoredFrameworks() throws {
        for mode in ["static", "dynamic", "library"] {
            let root = try directory()
            _ = try xcframework(root, entries: [entry("device"), entry("simulator", variant: "simulator")])
            for slice in ["device", "simulator"] {
                let headers = root.appendingPathComponent("Kit.xcframework/" + slice + "/Kit.framework/Headers")
                try FileManager.default.createDirectory(at: headers, withIntermediateDirectories: true)
                try Data("void vendor_api(void);\n".utf8).write(to: headers.appendingPathComponent("Kit.h"))
            }
            let spec = try NativeSpec(
                data: [
                    "name": "Kit", "version": "1.0", "vendored_frameworks": "Kit.xcframework",
                    "source_files": "Kit.xcframework/**/*.h",
                ],
                directory: root)
            let dependency = try NativeDependency(["name": "Kit"], platform: "ios", deployment: "15.0")
            let engine = try NativeXcode(
                project: root,
                manifest: [
                    "targets": [
                        [
                            "name": "Demo", "platform": ["name": "ios", "deployment_target": "15.0"],
                            "frameworks": mode, "dependencies": [["name": "Kit"]],
                        ]
                    ]
                ],
                resolution: NativeResolution(specs: ["Kit": spec], requests: [dependency]),
                integrateUserProjects: false)
            try engine.generate()
            let product = try XCTUnwrap(engine.products.first)
            XCTAssertEqual(engine.graph.objects[product]?["path"] as? String, "libKit.a")
            XCTAssertEqual(engine.graph.objects[product]?["explicitFileType"] as? String, "archive.ar")
            let target = try XCTUnwrap(
                engine.graph.objects.values.first {
                    $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == "Kit"
                })
            XCTAssertEqual(target["productType"] as? String, "com.apple.product-type.library.static")
            XCTAssertEqual(engine.vendorSDKs["Kit:ios"]?.first?.productName, "Kit.framework")
        }
    }
    func testPlaceholderArchivesReserveOtherPodsSDKAndTargetNamesBeforeGeneration() throws {
        for other in ["AProvider", "ZProvider"] {
            let root = try directory()
            let object = archive(macho(platform: 1, kind: 1))
            var specs: [String: NativeSpec] = [:]
            for (name, libraries) in [
                ("Vendor", ["libOther.a"]),
                (other, ["libVendor.a", "libVendor-SwiftPods.a"]),
                ("Vendor-SwiftPods-SwiftPods", ["libIndependent.a"]),
            ] {
                let directory = root.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for library in libraries { try object.write(to: directory.appendingPathComponent(library)) }
                specs[name] = try NativeSpec(
                    data: ["name": name, "version": "1.0", "source_files": [], "vendored_libraries": libraries],
                    directory: directory)
            }
            let engine = try NativeXcode(
                project: root,
                manifest: [
                    "targets": [[
                        "name": "Demo", "platform": ["name": "osx", "deployment_target": "13.0"],
                        "dependencies": specs.keys.sorted().map { ["name": $0] }, "frameworks": "dynamic",
                    ]]
                ],
                resolution: NativeResolution(specs: specs, requests: []), integrateUserProjects: false)
            try engine.generate()
            let product = try XCTUnwrap(engine.products.first { engine.productRoots[$0] == "Vendor" })
            XCTAssertEqual(engine.graph.objects[product]?["path"] as? String, "libVendor-SwiftPods-SwiftPods-SwiftPods.a")
        }
    }

    func testMetadataMustMatchBinaryArchitectureAndPlatform() throws {
        let root = try directory()
        var metadata = entry("device")
        metadata["SupportedArchitectures"] = ["x86_64"]
        let path = try xcframework(root, entries: [metadata])
        XCTAssertThrowsError(try NativeVendorSDK(path))
        metadata["SupportedArchitectures"] = ["arm64"]
        metadata["SupportedPlatform"] = "macos"
        try plist(
            ["XCFrameworkFormatVersion": "1.0", "AvailableLibraries": [metadata]],
            at: path.appendingPathComponent("Info.plist"))
        XCTAssertThrowsError(try NativeVendorSDK(path))
    }

    func testStaticTargetsPrepareXCFrameworksWithoutLinkingTheirDependencies() throws {
        for mode in ["library", "static", "dynamic"] {
            let root = try directory()
            let sdk = try xcframework(root, entries: [entry("device")])
            let object = archive(macho(platform: 2, kind: 1))
            try object.write(to: sdk.appendingPathComponent("device/Kit.framework/Kit"))
            let raw = root.appendingPathComponent("Raw.framework")
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
            try object.write(to: raw.appendingPathComponent("Raw"))
            try object.write(to: root.appendingPathComponent("libRaw.a"))
            try Data("int wrapper_value(void) { return 42; }\n".utf8).write(
                to: root.appendingPathComponent("Wrapper.m"))
            let binary = try NativeSpec(
                data: [
                    "name": "BinaryKit", "version": "1.0", "platforms": ["ios": "15.0"],
                    "vendored_frameworks": ["Kit.xcframework", "Raw.framework"],
                    "vendored_libraries": "libRaw.a", "frameworks": "Foundation",
                    "weak_frameworks": "StoreKit",
                    "pod_target_xcconfig": ["EXCLUDED_SOURCE_FILE_NAMES": ["UserExcluded.m"]],
                ], directory: root)
            let wrapper = try NativeSpec(
                data: [
                    "name": "Wrapper", "version": "1.0", "platforms": ["ios": "15.0"],
                    "source_files": "Wrapper.m", "dependencies": ["BinaryKit": []],
                ], directory: root)
            let dependency = try NativeDependency(["name": "Wrapper"], platform: "ios", deployment: "15.0")
            let engine = try NativeXcode(
                project: root,
                manifest: [
                    "targets": [
                        [
                            "name": "Demo", "platform": ["name": "ios", "deployment_target": "15.0"],
                            "frameworks": mode, "dependencies": [["name": "Wrapper"]],
                        ]
                    ]
                ],
                resolution: NativeResolution(specs: ["BinaryKit": binary, "Wrapper": wrapper], requests: [dependency]),
                integrateUserProjects: false)
            try engine.generate()
            for name in ["BinaryKit", "Wrapper"] {
                let target = try XCTUnwrap(
                    engine.graph.objects.values.first {
                        $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == name
                    })
                let phase = try XCTUnwrap(
                    (target["buildPhases"] as? [String])?.compactMap { engine.graph.objects[$0] }.first {
                        $0["isa"] as? String == "PBXFrameworksBuildPhase"
                    })
                let paths = Set(
                    (phase["files"] as? [String] ?? []).compactMap { build -> String? in
                        guard let reference = engine.graph.objects[build]?["fileRef"] as? String else { return nil }
                        return engine.graph.objects[reference]?["path"] as? String
                    })
                if mode == "dynamic" && name == "Wrapper" {
                    XCTAssertTrue(paths.contains(raw.path))
                    XCTAssertTrue(paths.contains { $0.hasSuffix("/libBinaryKit.a") })
                    continue
                }
                XCTAssertEqual(paths, [sdk.path])
                let list = try XCTUnwrap(target["buildConfigurationList"] as? String)
                for config in engine.graph.objects[list]?["buildConfigurations"] as? [String] ?? [] {
                    let settings = try NativeBuildSettings.resolvedScopes(
                        engine.graph.objects[config] ?? [:], graph: engine.graph, targetName: name
                    ).targetScope
                    let exclusions = try XCTUnwrap(settings.expandedValue("EXCLUDED_SOURCE_FILE_NAMES"))
                    XCTAssertTrue(exclusions.contains(sdk.path))
                    if name == "BinaryKit" { XCTAssertTrue(exclusions.contains("UserExcluded.m")) }
                }
            }
        }
    }
    func testRejectsTraversalAndSymlinksOutsideSDK() throws {
        let root = try directory()
        let path = try xcframework(root, entries: [entry("device")])
        let payload = path.appendingPathComponent("device/Kit.framework/Kit")
        let outside = root.appendingPathComponent("outside")
        try macho(platform: 2).write(to: outside)
        try FileManager.default.removeItem(at: payload)
        try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: outside)
        XCTAssertThrowsError(try NativeVendorSDK(path))
        var metadata = entry("device")
        metadata["LibraryPath"] = "../../outside"
        try plist(
            ["XCFrameworkFormatVersion": "1.0", "AvailableLibraries": [metadata]],
            at: path.appendingPathComponent("Info.plist"))
        XCTAssertThrowsError(try NativeVendorSDK(path))
    }
    func testRejectsOverlappingSlicesAndMixedLinkage() throws {
        let path = try xcframework(directory(), entries: [entry("first"), entry("second")])
        XCTAssertThrowsError(try NativeVendorSDK(path))
        let object = macho(platform: 2, kind: 1)
        try archive(object).write(
            to: path.appendingPathComponent("second/Kit.framework/Kit"))
        XCTAssertThrowsError(try NativeVendorSDK(path))
    }
    func testRawSDKAndHistoricalArchitectures() throws {
        let root = try directory()
        let library = root.appendingPathComponent("Kit.dylib")
        try macho(platform: 1).write(to: library)
        let sdk = try NativeVendorSDK(library)
        XCTAssertEqual(sdk.fileType, "compiled.mach-o.dylib")
        XCTAssertEqual(try sdk.select(platform: "osx", variant: "device", architectures: ["arm64"]).library, library)
        for (cpu, subtype, expected): (UInt32, UInt32, String) in [
            (12, 9, "armv7"), (12, 11, "armv7s"), (12, 12, "armv7k"), (0x0200_000c, 0, "arm64_32"),
        ] {
            try macho(platform: 4, cpu: cpu, subtype: subtype).write(to: library)
            XCTAssertEqual(try BinaryInspection.inspect(library).first?.architecture, expected)
        }
        try Data("not a binary".utf8).write(to: library)
        XCTAssertThrowsError(try NativeVendorSDK(library))
    }
}
