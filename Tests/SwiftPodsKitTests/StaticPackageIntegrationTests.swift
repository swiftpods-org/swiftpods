import Foundation
@testable import SwiftPodsKit
import SwiftPodsTestSupport
import SwiftPodsXcode
import XCTest

final class StaticPackageIntegrationTests: XCTestCase {
    private let packageFiles = [
        "Modules/SharedSDK/Package.swift": """
            // swift-tools-version: 5.9
            import PackageDescription
            let package = Package(name: "SharedSDK", platforms: [.iOS(.v15)],
                products: [.library(name: "SharedSDK", targets: ["SDKBridge"])],
                dependencies: [.package(path: "../CSupport")],
                targets: [.target(name: "SDKBridge", dependencies: ["SDKInternal", .product(name: "CInterop", package: "CSupport")]),
                          .target(name: "SDKInternal")])
            """,
        "Modules/CSupport/Package.swift": """
            // swift-tools-version: 5.9
            import PackageDescription
            let package = Package(name: "CSupport", platforms: [.iOS(.v15)],
                products: [.library(name: "CInterop", targets: ["SDKC"])],
                targets: [.target(name: "SDKC", dependencies: ["SDKBase"]), .target(name: "SDKBase")])
            """,
        "Modules/SharedSDK/Sources/SDKBridge/Bridge.swift": """
            import Foundation
            import SDKInternal
            import SDKC
            @objc(SPSharedBridge) public final class SharedBridge: NSObject {
                @objc public static func value() -> Int32 { InternalBridge.value() + sdk_value() }
            }
            """,
        "Modules/SharedSDK/Sources/SDKInternal/Internal.swift": """
            import Foundation
            @objc(SPInternalBridge) public final class InternalBridge: NSObject {
                @objc public static func value() -> Int32 { 7 }
            }
            """,
        "Modules/CSupport/Sources/SDKC/include/SDKC.h": "#ifdef __cplusplus\nextern \"C\" {\n#endif\nint sdk_value(void);\n#ifdef __cplusplus\n}\n#endif\n",
        "Modules/CSupport/Sources/SDKC/include/module.modulemap": "module SDKC {\n  umbrella header \"SDKC.h\"\n  export *\n}\n",
        "Modules/CSupport/Sources/SDKC/value.c": "#include \"SDKC.h\"\n#include <SDKBase/SDKBase.h>\nint sdk_value(void) { return sdk_base(); }\n",
        "Modules/CSupport/Sources/SDKBase/include/SDKBase/SDKBase.h": "#ifdef __cplusplus\nextern \"C\" {\n#endif\nint sdk_base(void);\n#ifdef __cplusplus\n}\n#endif\n",
        "Modules/CSupport/Sources/SDKBase/base.c": "#include <SDKBase/SDKBase.h>\nint sdk_base(void) { return 11; }\n",
        "plugin.swift": """
            import SDKBridge
            import SDKInternal
            import SDKC
            @_cdecl("plugin_one") public func pluginOne() -> Int32 {
                SharedBridge.value() + InternalBridge.value() + sdk_value()
            }
            """,
        "plugin.m": """
            @import Foundation;
            @import SDKBridge;
            @import SDKInternal;
            @import SDKC;
            #import <SDKBridge-Swift.h>
            #include "SDKC.h"
            #include <SDKBase/SDKBase.h>
            int plugin_two(void) { return [SPSharedBridge value] + [SPInternalBridge value] + sdk_value(); }
            """,
        "plugin.mm": """
            @import Foundation;
            @import SDKBridge;
            @import SDKInternal;
            @import SDKC;
            #include "SDKC.h"
            extern "C" int plugin_three(void) { return [SPSharedBridge value] + [SPInternalBridge value] + sdk_value(); }
            """,
        "main.swift": """
            import AppIntents
            import SDKBridge
            @_silgen_name("plugin_one") func one() -> Int32
            @_silgen_name("plugin_two") func two() -> Int32
            @_silgen_name("plugin_three") func three() -> Int32
            print(one() + two() + three() + SharedBridge.value())
            """,
    ]

    private func podfile(link: Bool = false, product: String = "SharedSDK") -> String {
        "platform :ios, '15.0'\n" + ["App", "Plugin", "PluginTwo"].map { name in
            "target '\(name)' do\n  spm 'SharedSDK', path: 'Modules/SharedSDK', products: ['\(product)'], link: \(name == "App" || link)\nend\n"
        }.joined()
    }

    private func fixture() throws -> URL {
        let directory = try Fixtures.directory(podfile: podfile(), files: packageFiles)
        var project = try XcodeProject(path: directory.appendingPathComponent("App.xcodeproj"))
        let app = project.nativeTargets.first { $0.name == "App" }!.id
        let plugin = project.nativeTargets.first { $0.name == "Plugin" }!.id
        let second = project.nativeTargets.first { $0.name == "AppTests" }!.id
        var secondTarget = project[second]!
        secondTarget["name"] = "PluginTwo"
        secondTarget["productName"] = "PluginTwo"
        secondTarget["productType"] = "com.apple.product-type.library.static"
        let secondProduct = secondTarget.string("productReference")!
        project[secondProduct] = ["isa": "PBXFileReference", "explicitFileType": "archive.ar", "path": "libPluginTwo.a", "sourceTree": "BUILT_PRODUCTS_DIR"]
        project[second] = secondTarget
        let frameworks = project[app]!.strings("buildPhases").first { project[$0]?.isa == "PBXFrameworksBuildPhase" }!
        for target in [plugin, second] {
            let product = project[target]!.string("productReference")!
            let dependency = project.put("fixture:dependency:" + target, ["isa": "PBXTargetDependency", "target": .string(target)])
            project.append(dependency, to: "dependencies", of: app)
            let link = project.put("fixture:link:" + target, ["isa": "PBXBuildFile", "fileRef": .string(product)])
            project.append(link, to: "files", of: frameworks)
            var files: [PBXValue] = []
            for source in target == plugin ? ["plugin.swift"] : ["plugin.m", "plugin.mm"] {
                let type = source.hasSuffix(".swift") ? "sourcecode.swift" : (source.hasSuffix(".mm") ? "sourcecode.cpp.objcpp" : "sourcecode.c.objc")
                let reference = project.put("fixture:source:" + source, ["isa": "PBXFileReference", "path": .string(source), "lastKnownFileType": .string(type), "sourceTree": "SOURCE_ROOT"])
                project.append(reference, to: "children", of: project.project.string("mainGroup")!)
                files.append(.string(project.put("fixture:file:" + source, ["isa": "PBXBuildFile", "fileRef": .string(reference)])))
            }
            let phase = project.put("fixture:sources:" + target, ["isa": "PBXSourcesBuildPhase", "buildActionMask": "2147483647", "files": .array(files), "runOnlyForDeploymentPostprocessing": "0"])
            project.append(phase, to: "buildPhases", of: target)
        }
        for target in project.nativeTargets {
            for (name, id) in project.configurations(of: target.id) {
                var settings = project[id]!["buildSettings"]?.dictionary ?? [:]
                let common: PBXObject = [
                    "PRODUCT_NAME": "$(TARGET_NAME)", "SWIFT_VERSION": "5.0", "CODE_SIGNING_ALLOWED": "NO",
                    "IPHONEOS_DEPLOYMENT_TARGET": "15.0", "CLANG_ENABLE_MODULES": "YES",
                    "OTHER_CPLUSPLUSFLAGS": "$(inherited) -fmodules -fcxx-modules",
                    "GCC_TREAT_WARNINGS_AS_ERRORS": "YES", "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
                    "ENABLE_USER_SCRIPT_SANDBOXING": "YES", "SWIFT_OPTIMIZATION_LEVEL": .string(name == "Release" ? "-O" : "-Onone"),
                ]
                settings.merge(common) { _, value in value }
                if target.id == app {
                    settings["GENERATE_INFOPLIST_FILE"] = "YES"
                    settings["PRODUCT_BUNDLE_IDENTIFIER"] = "org.swiftpods.static-packages"
                    settings["OTHER_LDFLAGS"] = "$(inherited) -ObjC"
                }
                project[id]!["buildSettings"] = .dictionary(settings)
            }
        }
        _ = try project.save()
        return directory
    }

    private func assertBuildDependencies(_ directory: URL, linked: Bool, product: String = "SharedSDK", file: StaticString = #filePath, line: UInt = #line) throws {
        let project = try XcodeProject(path: directory.appendingPathComponent("App.xcodeproj"))
        for target in project.nativeTargets where target.name != "App" {
            let object = project[target.id]!
            let linkedNames = object.strings("packageProductDependencies").compactMap { project[$0]?.string("productName") }
            XCTAssertEqual(linkedNames.contains(product), linked, file: file, line: line)
            let builtNames = object.strings("dependencies").compactMap { project[$0]?.string("productRef") }
                .compactMap { project[$0]?.string("productName") }
            XCTAssertEqual(builtNames.filter { $0 == product }.count, linked ? 0 : 1, file: file, line: line)
        }
        // Every reference generated for a compile-only product has an owner and participates in cleanup.
        let owned = try ProjectIntegration.ownedIdentifiers(project)
        for (id, object) in project.objects where object.isa == "PBXTargetDependency" && object.string("productRef") != nil {
            XCTAssertTrue(owned.contains(id), file: file, line: line)
            XCTAssertTrue(owned.contains(object.string("productRef")!), file: file, line: line)
        }
    }

    func testBuildOnlyProductMigrationUpdateRemovalAndDeintegration() throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("App.xcodeproj/project.pbxproj")
        let original = try Data(contentsOf: file)
        let installer = Installer(directory: directory, cache: directory.appendingPathComponent(".cache"))
        for link in [true, false, true, false] {
            try podfile(link: link).write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
            _ = try installer.install(InstallOptions())
            try assertBuildDependencies(directory, linked: link)
            var snapshot = try Data(contentsOf: file)
            if !link {
                let expected = try XcodeProject(path: directory.appendingPathComponent("App.xcodeproj")).objects
                // SwiftPods 0.3.11's link:false left this product in packageProductDependencies without
                // a Frameworks build file. Upgrade that exact relationship in place.
                var legacy = try XcodeProject(path: directory.appendingPathComponent("App.xcodeproj"))
                for target in legacy.nativeTargets where target.name != "App" {
                    let dependency = try XCTUnwrap(legacy[target.id]!.strings("dependencies").first {
                        guard let product = legacy[$0]?.string("productRef") else { return false }
                        return legacy[product]?.string("productName") == "SharedSDK"
                    })
                    let product = try XCTUnwrap(legacy[dependency]?.string("productRef"))
                    legacy.remove(dependency)
                    legacy.append(product, to: "packageProductDependencies", of: target.id)
                }
                _ = try legacy.save()
                _ = try installer.install(InstallOptions())
                try assertBuildDependencies(directory, linked: false)
                XCTAssertEqual(try XcodeProject(path: directory.appendingPathComponent("App.xcodeproj")).objects, expected)
                snapshot = try Data(contentsOf: file)
            }
            XCTAssertEqual(try installer.install(InstallOptions()).projects.flatMap(\.changes), [])
            XCTAssertEqual(try Data(contentsOf: file), snapshot)
        }
        try podfile(product: "RenamedSDK").write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        _ = try installer.install(InstallOptions())
        try assertBuildDependencies(directory, linked: false, product: "RenamedSDK")
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("productName = SharedSDK;"))
        try "target 'App' do\nend\ntarget 'Plugin' do\nend\ntarget 'PluginTwo' do\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        _ = try installer.install(InstallOptions())
        let removed = try XcodeProject(path: directory.appendingPathComponent("App.xcodeproj"))
        XCTAssertFalse(removed.objects.values.contains { $0.string("productName") == "RenamedSDK" })
        XCTAssertFalse(removed.objects.values.contains { $0.string("path") == "Modules/SharedSDK" })
        _ = try installer.deintegrate()
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("SwiftPods").path))
    }

    func testXcodeBuildsTwoStaticPluginsWithoutArchivingTheirSharedSDK() throws {
        guard ProcessInfo.processInfo.environment["SWIFTPODS_E2E"] == "1" else { throw XCTSkip("Set SWIFTPODS_E2E=1 to build with Xcode") }
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectFile = directory.appendingPathComponent("App.xcodeproj/project.pbxproj")
        let original = try Data(contentsOf: projectFile)
        let installer = Installer(directory: directory, cache: directory.appendingPathComponent(".cache"))
        _ = try installer.install(InstallOptions())
        let runner = ProcessRunner()
        // Keep build metadata inside the checkout to exercise sandbox access beyond the system temporary directory.
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let derived = packageRoot.appendingPathComponent(".build/static-package-integration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: derived) }
        func build(_ configuration: String, _ platform: String, sdk: Bool = true, scheme: String = "App") throws {
            let log: String
            do {
                log = try runner.run("/usr/bin/xcrun", ["xcodebuild", "build", "-project", "App.xcodeproj", "-scheme", scheme,
                    "-configuration", configuration, "-destination", "generic/platform=\(platform)", "-derivedDataPath", derived.path, "ARCHS=arm64"], in: directory)
            } catch let error as SwiftPodsError {
                if let output = error.commandFailure?.output { print(String(decoding: output, as: UTF8.self)) }
                throw error
            }
            XCTAssertTrue(log.contains("** BUILD SUCCEEDED **"), log)
            XCTAssertFalse(log.contains("warning:"), log)
            let products = derived.appendingPathComponent("Build/Products/\(configuration)-\(platform == "iOS" ? "iphoneos" : "iphonesimulator")")
            for plugin in scheme == "App" ? ["Plugin", "PluginTwo"] : [scheme] {
                let archive = products.appendingPathComponent("lib\(plugin).a")
                let members = try runner.run("/usr/bin/xcrun", ["ar", "-t", archive.path], in: nil)
                print("Archive \(configuration) \(platform) \(plugin): \(members.split(separator: "\n").joined(separator: ", "))")
                XCTAssertFalse(members.split(separator: "\n").contains { $0.hasPrefix("SDK") }, members)
                let definitions = try runner.run("/usr/bin/xcrun", ["nm", "-gU", archive.path], in: nil)
                XCTAssertFalse(definitions.contains("_OBJC_CLASS_$_SPSharedBridge"), definitions)
                XCTAssertFalse(definitions.contains("_OBJC_CLASS_$_SPInternalBridge"), definitions)
            }
            guard scheme == "App" else { return }
            let debugLibrary = products.appendingPathComponent("App.app/App.debug.dylib")
            let executable = FileManager.default.fileExists(atPath: debugLibrary.path) ? debugLibrary : products.appendingPathComponent("App.app/App")
            let definitions = try runner.run("/usr/bin/xcrun", ["nm", "-gU", executable.path], in: nil)
            for symbol in ["_OBJC_CLASS_$_SPSharedBridge", "_OBJC_CLASS_$_SPInternalBridge", "_sdk_value", "_sdk_base"] {
                XCTAssertEqual(definitions.split(separator: "\n").filter { $0.hasSuffix(" " + symbol) }.count, sdk ? 1 : 0, definitions)
            }
            print("Linked \(configuration) \(platform), SDK definitions expected: \(sdk ? 1 : 0)")
        }
        // Start with the Objective-C/Objective-C++ plugin alone: the app cannot supply its module build order.
        try build("Release", "iOS Simulator", scheme: "PluginTwo")
        for (configuration, platform) in [("Debug", "iOS Simulator"), ("Release", "iOS Simulator"), ("Release", "iOS")] {
            try build(configuration, platform)
            XCTAssertEqual(try installer.install(InstallOptions()).projects.flatMap(\.changes), [])
        }
        // Change both the selected product and a transitive module without cleaning DerivedData.
        let package = directory.appendingPathComponent("Modules/SharedSDK")
        try FileManager.default.moveItem(at: package.appendingPathComponent("Sources/SDKInternal"),
            to: package.appendingPathComponent("Sources/SDKNext"))
        let cSupport = directory.appendingPathComponent("Modules/CSupport")
        try FileManager.default.moveItem(at: cSupport.appendingPathComponent("Sources/SDKC/include"),
            to: cSupport.appendingPathComponent("Sources/SDKC/PublicHeaders"))
        let cManifest = cSupport.appendingPathComponent("Package.swift")
        try String(contentsOf: cManifest, encoding: .utf8).replacingOccurrences(
            of: ".target(name: \"SDKC\", dependencies: [\"SDKBase\"])",
            with: ".target(name: \"SDKC\", dependencies: [\"SDKBase\"], publicHeadersPath: \"PublicHeaders\")")
            .write(to: cManifest, atomically: true, encoding: .utf8)
        for path in ["Modules/SharedSDK/Package.swift", "Modules/SharedSDK/Sources/SDKBridge/Bridge.swift", "plugin.swift", "plugin.m", "plugin.mm"] {
            let url = directory.appendingPathComponent(path)
            var text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "SDKInternal", with: "SDKNext")
            if path.hasSuffix("Package.swift") {
                text = text.replacingOccurrences(of: ".library(name: \"SharedSDK\"", with: ".library(name: \"SharedSDKUpdated\"")
            }
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try podfile(product: "SharedSDKUpdated").write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        _ = try installer.install(InstallOptions())
        try assertBuildDependencies(directory, linked: false, product: "SharedSDKUpdated")
        XCTAssertEqual(try installer.install(InstallOptions()).projects.flatMap(\.changes), [])
        try build("Release", "iOS Simulator")
        for target in ["Plugin", "PluginTwo"] {
            let map = try String(contentsOf: derived.appendingPathComponent(
                "Build/Intermediates.noindex/App.build/Release-iphonesimulator/\(target).build/DerivedSources/SwiftPodsPackageModules/module.modulemap"), encoding: .utf8)
            XCTAssertTrue(map.contains("SDKNext"), map)
            XCTAssertFalse(map.contains("SDKInternal"), map)
        }
        // Removing an SDK from one consumer must preserve the other consumer and the final application's link.
        try "@_cdecl(\"plugin_one\") public func pluginOne() -> Int32 { 1 }\n"
            .write(to: directory.appendingPathComponent("plugin.swift"), atomically: true, encoding: .utf8)
        let partial = podfile(product: "SharedSDKUpdated").replacingOccurrences(
            of: "target 'Plugin' do\n  spm 'SharedSDK', path: 'Modules/SharedSDK', products: ['SharedSDKUpdated'], link: false\nend",
            with: "target 'Plugin' do\nend")
        try partial.write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        _ = try installer.install(InstallOptions())
        try build("Release", "iOS Simulator")
        // Remove it everywhere and rebuild against the same product and module caches.
        for (path, text) in [
            "main.swift": "import AppIntents\n@_silgen_name(\"plugin_one\") func one() -> Int32\n@_silgen_name(\"plugin_two\") func two() -> Int32\n@_silgen_name(\"plugin_three\") func three() -> Int32\nprint(one() + two() + three())\n",
            "plugin.m": "int plugin_two(void) { return 2; }\n",
            "plugin.mm": "extern \"C\" int plugin_three(void) { return 3; }\n",
            "Podfile": "target 'App' do\nend\ntarget 'Plugin' do\nend\ntarget 'PluginTwo' do\nend\n",
        ] {
            try text.write(to: directory.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        _ = try installer.install(InstallOptions())
        XCTAssertEqual(try installer.install(InstallOptions()).projects.flatMap(\.changes), [])
        try build("Release", "iOS Simulator", sdk: false)
        _ = try installer.deintegrate()
        XCTAssertEqual(try Data(contentsOf: projectFile), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("SwiftPods").path))
        try build("Release", "iOS Simulator", sdk: false)
    }

    func testModuleBridgeUsesTheCurrentClosureAndSourceModuleMaps() throws {
        let directory = try Fixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        func write(_ path: String, _ text: String) throws -> URL {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let source = try write("bridge.swift", PackageModuleBridge.source)
        let originalMap = try write("Custom SDK/include/module.modulemap", "module SDKC { umbrella header \"SDKC.h\" export * }\n")
        _ = try write("Custom SDK/include/SDKC.h", "int value(void);\n")
        _ = try write("Maps/SDKC.modulemap", "module SDKC { header \"obsolete.h\" }\n")
        _ = try write("Maps/SDKBridge.modulemap", "module SDKBridge { header \"SDKBridge-Swift.h\" export * }\n")
        _ = try write("Maps/RemovedSDK.modulemap", "module RemovedSDK {}\n")
        _ = try write("Maps/Metadata.modulemap", "module Metadata {}\n")
        let publicHeader = try write("Generated SDK/Public/SDK_Base/SDKBase.h", "int sdk_base(void);\n")
        let publicRoot = publicHeader.deletingLastPathComponent().deletingLastPathComponent()
        _ = try write("Maps/SDK-Base.modulemap", "module SDK_Base { umbrella header \"\(publicHeader.path)\" export * }\n")
        let generatedRecord: [String: Any] = ["guid": "PACKAGE-TARGET:SDK-Base", "buildConfigurations": [[
            "buildSettings": ["PRODUCT_MODULE_NAME": "SDK_Base", "MODULEMAP_PATH": "$(GENERATED_MODULEMAP_DIR)/SDK-Base.modulemap"],
            "impartedBuildProperties": ["buildSettings": ["HEADER_SEARCH_PATHS": [publicRoot.path, "$(inherited)"]]],
        ]]]
        _ = try write("Cache/target/TARGET-generated-json", String(decoding: try JSONSerialization.data(withJSONObject: generatedRecord), as: UTF8.self))
        let record: [String: Any] = ["guid": "PACKAGE-TARGET:SDKC", "buildConfigurations": [["buildSettings": ["PRODUCT_MODULE_NAME": "SDKC", "MODULEMAP_FILE": originalMap.path]]]]
        let recordURL = try write("Cache/target/TARGET-test-json", String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordURL.path))
        let current = try write("static.txt", "/Products/SDKBridge.appintents/Metadata.appintents/extract.actionsdata\n/Products/SDKC.appintents/Metadata.appintents/extract.actionsdata\n/Products/SDK_Base.appintents/Metadata.appintents/extract.actionsdata\n")
        let dynamic = try write("dynamic.txt", "")
        let runner = ProcessRunner()
        let executable = directory.appendingPathComponent("bridge")
        _ = try runner.run("/usr/bin/xcrun", ["--sdk", "macosx", "swiftc", "-warnings-as-errors", source.path, "-o", executable.path], in: directory)
        let output = directory.appendingPathComponent("Output")
        func run() throws {
            _ = try runner.run(executable.path, [directory.appendingPathComponent("Maps").path, output.path,
                current.path, dynamic.path, directory.appendingPathComponent("Cache").path], in: nil)
        }
        try run()
        let map = try String(contentsOf: output.appendingPathComponent("module.modulemap"), encoding: .utf8)
        XCTAssertTrue(map.contains(originalMap.path), map)
        XCTAssertTrue(map.contains("SDKBridge"), map)
        XCTAssertTrue(map.contains("SDK-Base.modulemap"), map)
        XCTAssertFalse(map.contains("RemovedSDK"), map)
        XCTAssertFalse(map.contains("extern module Metadata"), map)
        let flags = try String(contentsOf: output.appendingPathComponent("clang.rsp"), encoding: .utf8)
        XCTAssertTrue(flags.contains("Custom SDK/include"), flags)
        XCTAssertTrue(flags.contains("-I\"\(publicRoot.path)\""), flags)
        try "/Products/SDKBridge.appintents/Metadata.appintents/extract.actionsdata\n"
            .write(to: current, atomically: true, encoding: .utf8)
        try run()
        XCTAssertFalse(try String(contentsOf: output.appendingPathComponent("module.modulemap"), encoding: .utf8).contains("SDKC"))
        XCTAssertFalse(try String(contentsOf: output.appendingPathComponent("clang.rsp"), encoding: .utf8).contains("Custom SDK"))
    }
}
