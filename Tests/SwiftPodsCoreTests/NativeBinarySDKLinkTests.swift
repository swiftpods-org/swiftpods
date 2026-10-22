import XCTest

@testable import SwiftPodsCore

final class NativeBinarySDKLinkTests: XCTestCase {
    private func fixture(format: String, mode: String, own: Bool) throws -> NativeXcode {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Wrapper.c")
        try Data("extern int sdk(void);\nint wrapper(void) { return sdk(); }\n".utf8).write(to: source)
        let sdkSource = root.appendingPathComponent("SDK.c")
        try Data("int sdk(void) { return 7; }\n".utf8).write(to: sdkSource)
        let object = root.appendingPathComponent("SDK.o")
        try command("/usr/bin/xcrun", ["clang", "-Werror", "-c", sdkSource.path, "-o", object.path])
        let archive = root.appendingPathComponent("libSDK.a")
        try command("/usr/bin/ar", ["rcs", archive.path, object.path])
        let framework = format.contains("framework") && format != "xcframework-library"
        var library = framework ? "SDK.framework" : "libSDK.a"
        if framework {
            let directory = root.appendingPathComponent(library)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: archive, to: directory.appendingPathComponent("SDK"))
        }
        if format.hasPrefix("xcframework") {
            let container = root.appendingPathComponent("SDK.xcframework")
            let slice = container.appendingPathComponent("macos")
            try FileManager.default.createDirectory(at: slice, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: root.appendingPathComponent(library), to: slice.appendingPathComponent(library))
            #if arch(arm64)
                let architecture = "arm64"
            #else
                let architecture = "x86_64"
            #endif
            let info: [String: Any] = [
                "XCFrameworkFormatVersion": "1.0",
                "AvailableLibraries": [
                    [
                        "LibraryIdentifier": "macos", "LibraryPath": library,
                        "SupportedPlatform": "macos", "SupportedArchitectures": [architecture],
                    ]
                ],
            ]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: container.appendingPathComponent("Info.plist"))
            library = "SDK.xcframework"
        }
        let attribute = framework ? "vendored_frameworks" : "vendored_libraries"
        let binary = try NativeSpec(data: ["name": "Binary", "version": "1.0", attribute: library], directory: root)
        var values: [String: Any] = ["name": "Wrapper", "version": "1.0", "source_files": "Wrapper.c"]
        if own { values[attribute] = library } else { values["dependencies"] = ["Binary": [] as [String]] }
        let wrapper = try NativeSpec(data: values, directory: root)
        return try NativeXcode(
            project: root,
            manifest: [
                "targets": [
                    [
                        "name": "App", "platform": ["name": "osx", "deployment_target": "13.0"],
                        "frameworks": mode, "dependencies": [["name": "Wrapper"]],
                    ]
                ]
            ], resolution: NativeResolution(specs: ["Wrapper": wrapper, "Binary": binary], requests: []),
            integrateUserProjects: false)
    }

    func testDynamicWrappersLoadEveryObjectFromTheirOwnAndTransitiveStaticSDKs() throws {
        for format in ["archive", "framework", "xcframework-library", "xcframework-framework"] {
            for own in [false, true] {
                let engine = try fixture(format: format, mode: "dynamic", own: own)
                try engine.generate()
                let variant = try XCTUnwrap(engine.variantPlan?.variants["Wrapper:osx"])
                engine.selectVariant(variant)
                let sdk = try XCTUnwrap(engine.vendorSDKs[own ? "Wrapper:osx" : "Binary:osx"]?.first)
                let source = engine.consumerSDKPath(sdk)
                let path =
                    (sdk.isXCFramework
                        ? "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/" + source.relative
                        : source.setting) + (sdk.isFramework ? "/SDK" : "")
                let settings = try linkerSettings(engine, variant: variant)
                let flags = nativeStrings(settings["OTHER_LDFLAGS"]).joined(separator: " ")
                XCTAssertTrue(flags.contains("-force_load " + NativeBuildSetting.quoted(path)), format)
                XCTAssertTrue(try engine.consumerVendorSDKs(["Wrapper", "Binary"], platform: "osx").isEmpty)
            }
        }
    }

    func testStaticWrappersLeaveTheirSDKForTheFinalLink() throws {
        let engine = try fixture(format: "archive", mode: "static", own: false)
        try engine.generate()
        let variant = try XCTUnwrap(engine.variantPlan?.variants["Wrapper:osx"])
        engine.selectVariant(variant)
        let settings = try linkerSettings(engine, variant: variant)
        XCTAssertFalse(nativeStrings(settings["OTHER_LDFLAGS"]).joined(separator: " ").contains("-force_load"))
        XCTAssertEqual(try engine.consumerVendorSDKs(["Wrapper", "Binary"], platform: "osx").count, 1)
    }

    func testAbsorbedSDKsFollowTheDynamicWrappersSelectedDependencyVariant() throws {
        let original = try fixture(format: "archive", mode: "dynamic", own: false)
        let root = original.project
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("libSDK.a"),
            to: root.appendingPathComponent("libExtra.a"))
        let binary = try NativeSpec(
            data: [
                "name": "Binary", "version": "1.0",
                "subspecs": [
                    ["name": "Core", "vendored_libraries": "libSDK.a"],
                    ["name": "Extra", "vendored_libraries": "libExtra.a"],
                ],
            ], directory: root)
        let wrapper = try NativeSpec(
            data: [
                "name": "Wrapper", "version": "1.0", "source_files": "Wrapper.c",
                "dependencies": ["Binary/Core": [] as [String]],
            ], directory: root)
        let main: [String: Any] = [
            "name": "App", "frameworks": "dynamic",
            "platform": ["name": "osx", "deployment_target": "13.0"],
            "dependencies": [["name": "Wrapper"], ["name": "Binary/Extra"]],
        ]
        var small = main
        small["name"] = "Small"
        small["dependencies"] = [["name": "Binary/Core"]]
        let engine = try NativeXcode(
            project: root, manifest: ["targets": [main, small]],
            resolution: NativeResolution(specs: ["Wrapper": wrapper, "Binary": binary], requests: []),
            integrateUserProjects: false)
        try engine.generate()
        engine.selectConsumer(main)
        let roots = try XCTUnwrap(engine.configuredDependencyRoots(main)["Debug"])
        XCTAssertEqual(try engine.consumerVendorSDKs(roots, platform: "osx").map(\.productName), ["libExtra.a"])
    }

    private func linkerSettings(_ engine: NativeXcode, variant: NativePodVariant) throws -> [String: Any] {
        let config = try XCTUnwrap(engine.configurations[variant.label]?["Debug"])
        let reference = try XCTUnwrap(engine.graph.objects[config]?["baseConfigurationReference"] as? String)
        let path = try XCTUnwrap(engine.graph.objects[reference]?["path"] as? String)
        var inputs = Set<String>()
        return try NativeBuildSettings.xcconfig(URL(fileURLWithPath: path), inputs: &inputs)
    }
}
