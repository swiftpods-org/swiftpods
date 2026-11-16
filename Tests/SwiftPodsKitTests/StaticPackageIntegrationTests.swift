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

    private func fixture(customProducts: Bool = false) throws -> URL {
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
                    if customProducts {
                        // Unsigned builds cannot re-sign frameworks after stripping them during embedding.
                        settings["COPY_PHASE_STRIP"] = "NO"
                        // Keep the Release executable's symbol table for the archive duplicate-symbol checks.
                        settings["STRIP_INSTALLED_PRODUCT"] = "NO"
                        // The application's own static libraries use custom locations. Archive installs
                        // SKIP_INSTALL products in UninstalledProducts regardless of CONFIGURATION_BUILD_DIR.
                        settings["FIXTURE_PLUGIN_LIBRARY_PATHS_NO"] = .string(["Plugin", "PluginTwo"].map {
                            "\"$(PROJECT_DIR)/Plugin Products/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/\($0)\""
                        }.joined(separator: " "))
                        settings["FIXTURE_PLUGIN_LIBRARY_PATHS_YES"] = "\"$(OBJROOT)/UninstalledProducts/$(PLATFORM_NAME)\""
                        settings["LIBRARY_SEARCH_PATHS"] = "$(inherited) $(FIXTURE_PLUGIN_LIBRARY_PATHS_$(DEPLOYMENT_LOCATION))"
                    }
                } else if customProducts {
                    settings["CONFIGURATION_BUILD_DIR"] = "$(PROJECT_DIR)/Plugin Products/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)/$(TARGET_NAME)"
                    settings["SKIP_INSTALL"] = "YES"
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

    private func addFrameworkSDKs(to directory: URL) throws {
        let runner = ProcessRunner()
        // Build a local static Swift XCFramework, including its Objective-C API, without network dependencies.
        let source = directory.appendingPathComponent("Binary.swift")
        try "import Foundation\n@objc(SPBinaryBridge) public final class BinaryBridge: NSObject { @objc public static func value() -> Int32 { 13 } }\n"
            .write(to: source, atomically: true, encoding: .utf8)
        var frameworks: [String] = []
        for (sdk, triple) in [("iphoneos", "arm64-apple-ios15.0"), ("iphonesimulator", "arm64-apple-ios15.0-simulator")] {
            let framework = directory.appendingPathComponent("BinaryBuild/\(sdk)/SDKBinary.framework")
            let headers = framework.appendingPathComponent("Headers")
            let modules = framework.appendingPathComponent("Modules")
            try FileManager.default.createDirectory(at: headers, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: modules.appendingPathComponent("SDKBinary.swiftmodule"), withIntermediateDirectories: true)
            let sdkPath = try runner.run("/usr/bin/xcrun", ["--sdk", sdk, "--show-sdk-path"], in: nil).trimmingCharacters(in: .whitespacesAndNewlines)
            let moduleTriple = sdk == "iphoneos" ? "arm64-apple-ios" : "arm64-apple-ios-simulator"
            _ = try runner.run("/usr/bin/xcrun", ["--sdk", sdk, "swiftc", "-warnings-as-errors", "-sdk", sdkPath,
                "-target", triple, "-swift-version", "5", "-parse-as-library", "-emit-library", "-static", "-emit-module", "-module-name", "SDKBinary",
                "-enable-library-evolution", "-emit-module-interface-path", modules.appendingPathComponent("SDKBinary.swiftmodule/\(moduleTriple).swiftinterface").path,
                "-emit-module-path", modules.appendingPathComponent("SDKBinary.swiftmodule/\(moduleTriple).swiftmodule").path,
                "-emit-objc-header-path", headers.appendingPathComponent("SDKBinary-Swift.h").path,
                source.path, "-o", framework.appendingPathComponent("SDKBinary").path], in: directory)
            try "framework module SDKBinary { header \"SDKBinary-Swift.h\" export * }\n"
                .write(to: modules.appendingPathComponent("module.modulemap"), atomically: true, encoding: .utf8)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.swiftpods.sdk-binary",
                "CFBundleExecutable": "SDKBinary", "CFBundleName": "SDKBinary", "CFBundlePackageType": "FMWK"], format: .xml, options: 0)
                .write(to: framework.appendingPathComponent("Info.plist"))
            frameworks += ["-framework", framework.path]
        }
        _ = try runner.run("/usr/bin/xcrun", ["xcodebuild", "-create-xcframework"] + frameworks + ["-output",
            directory.appendingPathComponent("Modules/SharedSDK/SDKBinary.xcframework").path], in: directory)
        let manifest = directory.appendingPathComponent("Modules/SharedSDK/Package.swift")
        try String(contentsOf: manifest, encoding: .utf8)
            .replacingOccurrences(of: "[\"SDKInternal\", .product", with: "[\"SDKBinary\", \"SDKInternal\", .product")
            .replacingOccurrences(of: ".library(name: \"SharedSDK\", targets: [\"SDKBridge\"])",
                with: ".library(name: \"SharedSDK\", targets: [\"SDKBridge\"]), .library(name: \"SDKDynamic\", type: .dynamic, targets: [\"SDKDynamic\"])")
            .replacingOccurrences(of: ".target(name: \"SDKInternal\")",
                with: ".target(name: \"SDKInternal\"), .binaryTarget(name: \"SDKBinary\", path: \"SDKBinary.xcframework\"), .target(name: \"SDKDynamic\")")
            .write(to: manifest, atomically: true, encoding: .utf8)
        let dynamic = directory.appendingPathComponent("Modules/SharedSDK/Sources/SDKDynamic/Dynamic.swift")
        try FileManager.default.createDirectory(at: dynamic.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "import Foundation\n@objc(SPDynamicBridge) public final class DynamicBridge: NSObject { @objc public static func value() -> Int32 { 17 } }\n"
            .write(to: dynamic, atomically: true, encoding: .utf8)
        try podfile().replacingOccurrences(of: "['SharedSDK']", with: "['SharedSDK', 'SDKDynamic']")
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let consumer = directory.appendingPathComponent("plugin.m")
        try String(contentsOf: consumer, encoding: .utf8)
            .replacingOccurrences(of: "@import SDKBridge;", with: "@import SDKBridge;\n@import SDKBinary;\n@import SDKDynamic;")
            .replacingOccurrences(of: "return [SPSharedBridge value]", with: "return [SPBinaryBridge value] + [SPDynamicBridge value] + [SPSharedBridge value]")
            .write(to: consumer, atomically: true, encoding: .utf8)
    }

    private func embedDynamicSDK(in directory: URL) throws -> Set<String> {
        // A regular Copy Files phase embeds the dynamic product. All compiler search paths
        // still come exclusively from SwiftPods, with no Podfile path overrides.
        var project = try XcodeProject(path: directory.appendingPathComponent("App.xcodeproj"))
        let app = try XCTUnwrap(project.nativeTargets.first { $0.name == "App" })
        let product = try XCTUnwrap(project[app.id]!.strings("packageProductDependencies").first {
            project[$0]?.string("productName") == "SDKDynamic"
        })
        let file = project.put("fixture:embed-dynamic-framework", ["isa": "PBXBuildFile", "productRef": .string(product),
            "settings": ["ATTRIBUTES": ["RemoveHeadersOnCopy"]]])
        let phase = project.put("fixture:embed-dynamic-frameworks", ["isa": "PBXCopyFilesBuildPhase", "buildActionMask": "2147483647",
            "dstPath": "", "dstSubfolderSpec": "10", "files": .array([.string(file)]), "name": "Embed SDKDynamic", "runOnlyForDeploymentPostprocessing": "0"])
        project.append(phase, to: "buildPhases", of: app.id)
        _ = try project.save()
        return [file, phase]
    }

    func testXcodeArchivesWithCustomPluginProductsAndSpacedPaths() throws {
        guard ProcessInfo.processInfo.environment["SWIFTPODS_E2E"] == "1" else { throw XCTSkip("Set SWIFTPODS_E2E=1 to build with Xcode") }
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = packageRoot.appendingPathComponent(".build/archive-package-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Project With Spaces", isDirectory: true)
        try FileManager.default.moveItem(at: fixture(customProducts: true), to: directory)
        let derived = root.appendingPathComponent("Derived Data With Spaces", isDirectory: true)
        let original = try XcodeProject(path: directory.appendingPathComponent("App.xcodeproj")).objects
        try addFrameworkSDKs(to: directory)
        let installer = Installer(directory: directory, cache: directory.appendingPathComponent(".cache"))
        _ = try installer.install(InstallOptions())
        let embeddedFramework = try embedDynamicSDK(in: directory)
        _ = try installer.install(InstallOptions())
        XCTAssertEqual(try installer.install(InstallOptions()).projects.flatMap(\.changes), [])
        try assertBuildDependencies(directory, linked: false)
        try assertBuildDependencies(directory, linked: false, product: "SDKDynamic")
        let runner = ProcessRunner()
        var publicHeaders = "Modules/CSupport/Sources/SDKC/include"
        func build(_ action: String, _ configuration: String, _ platform: String, sdk: Bool = true) throws {
            let platformName = platform == "iOS" ? "iphoneos" : "iphonesimulator"
            let configurationName = configuration + "-" + platformName
            let archive = derived.appendingPathComponent(configurationName + ".xcarchive")
            let log: String
            do {
                // SwiftPM's test host can export a macOS SDKROOT; Xcode must select the target SDK.
                log = try runner.run("/usr/bin/env", ["-u", "SDKROOT", "/usr/bin/xcrun", "xcodebuild", action,
                    "-sdk", platformName, "-project", "App.xcodeproj", "-scheme", "App",
                    "-configuration", configuration, "-destination", "generic/platform=\(platform)", "-derivedDataPath", derived.path,
                    "-archivePath", archive.path, "ARCHS=arm64"], in: directory)
            } catch let error as SwiftPodsError {
                if let output = error.commandFailure?.output { print(String(decoding: output, as: UTF8.self)) }
                throw error
            }
            XCTAssertTrue(log.contains("** \(action.uppercased()) SUCCEEDED **"), log)
            XCTAssertFalse(log.contains("warning:"), log)
            if sdk { XCTAssertTrue(log.contains("/usr/bin/sandbox-exec"), log) }
            let intermediates = derived.appendingPathComponent("Build/Intermediates.noindex")
            let objectRoot = action == "archive"
                ? intermediates.appendingPathComponent("ArchiveIntermediates/App/IntermediateBuildFilesPath") : intermediates
            for plugin in ["Plugin", "PluginTwo"] {
                let library = action == "archive"
                    ? objectRoot.appendingPathComponent("UninstalledProducts/\(platformName)/lib\(plugin).a")
                    : directory.appendingPathComponent("Plugin Products/\(configurationName)/\(plugin)/lib\(plugin).a")
                let members = try runner.run("/usr/bin/xcrun", ["ar", "-t", library.path], in: nil)
                let objects = members.split(separator: "\n").filter { $0.hasSuffix(".o") }
                XCTAssertFalse(objects.isEmpty, members)
                XCTAssertTrue(objects.allSatisfy { $0.lowercased().hasPrefix("plugin") }, members)
                let definitions = try runner.run("/usr/bin/xcrun", ["nm", "-gU", library.path], in: nil)
                for name in ["SPSharedBridge", "SPInternalBridge", "SPBinaryBridge", "SPDynamicBridge"] {
                    XCTAssertFalse(definitions.contains("_OBJC_CLASS_$_" + name), definitions)
                }
                if sdk {
                    let flags = try String(contentsOf: objectRoot.appendingPathComponent(
                        "App.build/\(configurationName)/\(plugin).build/DerivedSources/SwiftPodsPackageModules/clang.rsp"), encoding: .utf8)
                    XCTAssertTrue(flags.contains(directory.appendingPathComponent(publicHeaders).path), flags)
                    if publicHeaders.hasSuffix("Public Headers") {
                        XCTAssertFalse(flags.contains(directory.appendingPathComponent("Modules/CSupport/Sources/SDKC/include").path), flags)
                    }
                }
                print("\(action) \(configurationName) \(plugin): \(objects.joined(separator: ", "))")
            }
            let app = action == "archive" ? archive.appendingPathComponent("Products/Applications/App.app")
                : derived.appendingPathComponent("Build/Products/\(configurationName)/App.app")
            let debugLibrary = app.appendingPathComponent("App.debug.dylib")
            let executable = FileManager.default.fileExists(atPath: debugLibrary.path) ? debugLibrary : app.appendingPathComponent("App")
            let definitions = try runner.run("/usr/bin/xcrun", ["nm", "-gU", executable.path], in: nil)
            for symbol in ["_OBJC_CLASS_$_SPSharedBridge", "_OBJC_CLASS_$_SPInternalBridge", "_OBJC_CLASS_$_SPBinaryBridge", "_sdk_value", "_sdk_base"] {
                XCTAssertEqual(definitions.split(separator: "\n").filter { $0.hasSuffix(" " + symbol) }.count, sdk ? 1 : 0, definitions)
            }
            let libraries = try runner.run("/usr/bin/xcrun", ["otool", "-L", executable.path], in: nil)
            XCTAssertEqual(libraries.split(separator: "\n").filter { $0.contains("@rpath/SDKDynamic.framework/SDKDynamic ") }.count, sdk ? 1 : 0, libraries)
            if sdk {
                let dynamic = try runner.run("/usr/bin/xcrun", ["nm", "-gU", app.appendingPathComponent("Frameworks/SDKDynamic.framework/SDKDynamic").path], in: nil)
                XCTAssertEqual(dynamic.split(separator: "\n").filter { $0.hasSuffix(" _OBJC_CLASS_$_SPDynamicBridge") }.count, 1, dynamic)
            }
            print("\(action) \(configurationName): SDK definitions and dynamic linkage verified (expected \(sdk ? 1 : 0))")
        }
        for (action, configuration, platform) in [
            ("build", "Release", "iOS Simulator"), ("build", "Release", "iOS"),
            ("archive", "Release", "iOS"), ("archive", "Release", "iOS Simulator"), ("build", "Debug", "iOS Simulator"),
            ("build", "Release", "iOS Simulator"), ("archive", "Release", "iOS"),
        ] {
            try build(action, configuration, platform)
            XCTAssertEqual(try installer.install(InstallOptions()).projects.flatMap(\.changes), [])
        }
        // Leave both old package PIF records and archive descriptions in place. Only the live
        // description may select public headers after their location changes.
        let cSupport = directory.appendingPathComponent("Modules/CSupport")
        try FileManager.default.moveItem(at: cSupport.appendingPathComponent("Sources/SDKC/include"),
            to: cSupport.appendingPathComponent("Sources/SDKC/Public Headers"))
        let manifest = cSupport.appendingPathComponent("Package.swift")
        try String(contentsOf: manifest, encoding: .utf8).replacingOccurrences(
            of: ".target(name: \"SDKC\", dependencies: [\"SDKBase\"])",
            with: ".target(name: \"SDKC\", dependencies: [\"SDKBase\"], publicHeadersPath: \"Public Headers\")")
            .write(to: manifest, atomically: true, encoding: .utf8)
        publicHeaders = "Modules/CSupport/Sources/SDKC/Public Headers"
        XCTAssertEqual(try installer.install(InstallOptions()).projects.flatMap(\.changes), [])
        try build("archive", "Release", "iOS")
        try build("build", "Release", "iOS Simulator")
        // Remove integration and rebuild/archive without cleaning any build or module caches.
        var project = try XcodeProject(path: directory.appendingPathComponent("App.xcodeproj"))
        project.remove(embeddedFramework)
        _ = try project.save()
        for (path, text) in [
            "main.swift": "import AppIntents\n@_silgen_name(\"plugin_one\") func one() -> Int32\n@_silgen_name(\"plugin_two\") func two() -> Int32\n@_silgen_name(\"plugin_three\") func three() -> Int32\nprint(one() + two() + three())\n",
            "plugin.swift": "@_cdecl(\"plugin_one\") public func pluginOne() -> Int32 { 1 }\n",
            "plugin.m": "int plugin_two(void) { return 2; }\n",
            "plugin.mm": "extern \"C\" int plugin_three(void) { return 3; }\n",
            "Podfile": "target 'App' do\nend\ntarget 'Plugin' do\nend\ntarget 'PluginTwo' do\nend\n",
        ] {
            try text.write(to: directory.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        _ = try installer.install(InstallOptions())
        XCTAssertEqual(try installer.install(InstallOptions()).projects.flatMap(\.changes), [])
        try build("build", "Release", "iOS Simulator", sdk: false)
        try build("archive", "Release", "iOS", sdk: false)
        _ = try installer.deintegrate()
        XCTAssertEqual(try XcodeProject(path: directory.appendingPathComponent("App.xcodeproj")).objects, original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("SwiftPods").path))
        try build("archive", "Release", "iOS", sdk: false)
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
        _ = try write("Cache/PIFCache/target/TARGET-generated-json", String(decoding: try JSONSerialization.data(withJSONObject: generatedRecord), as: UTF8.self))
        let record: [String: Any] = ["guid": "PACKAGE-TARGET:SDKC", "buildConfigurations": [["buildSettings": ["PRODUCT_MODULE_NAME": "SDKC", "MODULEMAP_FILE": originalMap.path]]]]
        let recordURL = try write("Cache/PIFCache/target/TARGET-test-json", String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordURL.path))
        let signature = String(repeating: "a", count: 32)
        let oldSignature = String(repeating: "b", count: 32)
        _ = try write("Cache/prior-build-descriptions.txt", oldSignature + "\n" + signature + "\n")
        let manifest: [String: Any] = ["commands": ["compile": [
            "args": ["clang", "-I", publicRoot.path],
            "outputs": ["SDKBridge.modulemap", "SDK-Base.modulemap"].map { directory.appendingPathComponent("Maps/" + $0).path },
        ]]]
        _ = try write("Cache/\(signature).xcbuilddata/manifest.json", String(decoding: try JSONSerialization.data(withJSONObject: manifest), as: UTF8.self))
        let flagsURL = try write("Cache/\(signature).xcbuilddata/attachments/flags", "-I'\(originalMap.deletingLastPathComponent().path)'\n")
        // The stale checkout can have identical module-map bytes and still refer to different headers.
        let staleMap = try write("Old SDK/include/module.modulemap", "module SDKC { umbrella header \"SDKC.h\" export * }\n")
        let staleConfiguration: [String: Any] = [
            "buildSettings": ["PRODUCT_MODULE_NAME": "SDKC", "MODULEMAP_FILE": staleMap.path],
            "impartedBuildProperties": ["buildSettings": ["HEADER_SEARCH_PATHS": [staleMap.deletingLastPathComponent().path]]],
        ]
        let staleRecord: [String: Any] = ["guid": "PACKAGE-TARGET:SDKC", "buildConfigurations": [staleConfiguration]]
        _ = try write("Cache/PIFCache/target/TARGET-stale-json", String(decoding: try JSONSerialization.data(withJSONObject: staleRecord), as: UTF8.self))
        _ = try write("Cache/\(oldSignature).xcbuilddata/manifest.json", "{\"commands\":{}}")
        _ = try write("Cache/\(oldSignature).xcbuilddata/attachments/flags", "-I'\(staleMap.deletingLastPathComponent().path)'\n")
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
        XCTAssertFalse(flags.contains("Old SDK"), flags)
        // Archive has a separate live manifest and uses the shared PIF cache above ArchiveIntermediates.
        let intermediates = directory.appendingPathComponent("Archive/Intermediates.noindex")
        let archiveData = intermediates.appendingPathComponent("ArchiveIntermediates/App/IntermediateBuildFilesPath/XCBuildData")
        let sharedData = intermediates.appendingPathComponent("XCBuildData")
        try FileManager.default.createDirectory(at: archiveData.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sharedData, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: directory.appendingPathComponent("Cache"), to: archiveData)
        try FileManager.default.moveItem(at: archiveData.appendingPathComponent("PIFCache"), to: sharedData.appendingPathComponent("PIFCache"))
        _ = try runner.run(executable.path, [directory.appendingPathComponent("Maps").path, output.path,
            current.path, dynamic.path, archiveData.path], in: nil)
        let archiveFlags = try String(contentsOf: output.appendingPathComponent("clang.rsp"), encoding: .utf8)
        XCTAssertTrue(archiveFlags.contains("-I\"\(publicRoot.path)\""), archiveFlags)
        XCTAssertFalse(archiveFlags.contains("Old SDK"), archiveFlags)
        let consumer = try write("consumer.m", "#include <SDK_Base/SDKBase.h>\nint consume(void) { return sdk_base(); }\n")
        _ = try runner.run("/usr/bin/xcrun", ["--sdk", "macosx", "clang", "-fsyntax-only", "-Werror",
            "@" + output.appendingPathComponent("clang.rsp").path, consumer.path], in: nil)
        // An existing archive-local cache must not hide current records in the shared cache.
        let localCache = archiveData.appendingPathComponent("PIFCache/target")
        try FileManager.default.createDirectory(at: localCache, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: staleRecord).write(to: localCache.appendingPathComponent("TARGET-stale-json"))
        _ = try runner.run(executable.path, [directory.appendingPathComponent("Maps").path, output.path,
            current.path, dynamic.path, archiveData.path], in: nil)
        let combinedFlags = try String(contentsOf: output.appendingPathComponent("clang.rsp"), encoding: .utf8)
        XCTAssertTrue(combinedFlags.contains("-I\"\(publicRoot.path)\""), combinedFlags)
        XCTAssertTrue(combinedFlags.contains(originalMap.deletingLastPathComponent().path), combinedFlags)
        XCTAssertFalse(combinedFlags.contains("Old SDK"), combinedFlags)
        // The shared intermediates root need not have Xcode's default Intermediates.noindex name.
        let custom = directory.appendingPathComponent("Custom Intermediates")
        try FileManager.default.copyItem(at: intermediates, to: custom)
        _ = try runner.run(executable.path, [directory.appendingPathComponent("Maps").path, output.path,
            current.path, dynamic.path, custom.appendingPathComponent("ArchiveIntermediates/App/IntermediateBuildFilesPath/XCBuildData").path], in: nil)
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("clang.rsp"), encoding: .utf8), combinedFlags)
        // The current archive description can change while every cached record remains present.
        try (signature + "\n" + oldSignature + "\n")
            .write(to: archiveData.appendingPathComponent("prior-build-descriptions.txt"), atomically: true, encoding: .utf8)
        _ = try runner.run(executable.path, [directory.appendingPathComponent("Maps").path, output.path,
            current.path, dynamic.path, archiveData.path], in: nil)
        let archiveMap = try String(contentsOf: output.appendingPathComponent("module.modulemap"), encoding: .utf8)
        XCTAssertTrue(archiveMap.contains(staleMap.path), archiveMap)
        XCTAssertFalse(archiveMap.contains(originalMap.path), archiveMap)
        // Switch between cached build descriptions without cleaning, regardless of their timestamps.
        try (signature + "\n" + oldSignature + "\n")
            .write(to: directory.appendingPathComponent("Cache/prior-build-descriptions.txt"), atomically: true, encoding: .utf8)
        try run()
        let switched = try String(contentsOf: output.appendingPathComponent("module.modulemap"), encoding: .utf8)
        XCTAssertTrue(switched.contains(staleMap.path), switched)
        XCTAssertFalse(switched.contains(originalMap.path), switched)
        try (oldSignature + "\n" + signature + "\n")
            .write(to: directory.appendingPathComponent("Cache/prior-build-descriptions.txt"), atomically: true, encoding: .utf8)
        // A genuine ambiguity within the live build must still fail with both paths in its diagnostic.
        try "-I'\(originalMap.deletingLastPathComponent().path)' -fmodule-map-file='\(staleMap.path)'\n"
            .write(to: flagsURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try run()) { error in
            let diagnostic = String(describing: error)
            XCTAssertTrue(diagnostic.contains(originalMap.path), diagnostic)
            XCTAssertTrue(diagnostic.contains(staleMap.path), diagnostic)
        }
        try "-I'\(originalMap.deletingLastPathComponent().path)'\n".write(to: flagsURL, atomically: true, encoding: .utf8)
        try "/Products/SDKBridge.appintents/Metadata.appintents/extract.actionsdata\n"
            .write(to: current, atomically: true, encoding: .utf8)
        try run()
        XCTAssertFalse(try String(contentsOf: output.appendingPathComponent("module.modulemap"), encoding: .utf8).contains("SDKC"))
        XCTAssertFalse(try String(contentsOf: output.appendingPathComponent("clang.rsp"), encoding: .utf8).contains("Custom SDK"))
    }
}
