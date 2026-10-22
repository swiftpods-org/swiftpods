import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeLinkerManifestTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testCommandUsesDiscoveredProjectAndExplicitOverrideWins() throws {
        let root = try directory()
        XCTAssertEqual(try NativeCommandRequest(["install"], project: root).project, root.resolvingSymlinksInPath())
        let selected = root.appendingPathComponent("Selected")
        XCTAssertEqual(
            try NativeCommandRequest(["install", "--project-directory", selected.path], project: root).project,
            selected.resolvingSymlinksInPath())
    }

    func testManifestPriorityUsesFilesAndIncludesRubyAlias() throws {
        let root = try directory()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("CocoaPods.podfile.yaml"), withIntermediateDirectories: true)
        for name in NativePodfilePath.names.dropFirst().reversed() {
            try Data().write(to: root.appendingPathComponent(name))
            XCTAssertEqual(NativePodfilePath.find(in: root)?.lastPathComponent, name)
        }
        XCTAssertEqual(StaticInspection(directory: root).report(bundle: nil)["mode"] as? String, "static")
    }

    func testOnlyResolvedVersionsEnforceProfileWithoutSilentlyDowngrading() throws {
        let old = try NativeSpec(data: ["name": "Kit", "version": "1.0"])
        let future = try NativeSpec(data: ["name": "Kit", "version": "2.0", "cocoapods_version": ">= 9.0"])
        let resolver = NativeResolver(candidates: { _ in [future, old] })
        let pinned = try NativeDependency(["name": "Kit", "requirements": ["= 1.0"]])
        XCTAssertEqual(try resolver.resolve([pinned]).specs["Kit"]?.version.description, "1.0")
        XCTAssertThrowsError(try resolver.resolve([NativeDependency(["name": "Kit"])])) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-SPEC-PROFILE")
        }
    }

    func testUppercaseObjectiveCPlusPlusUsesBothARCPatternOutcomes() throws {
        let root = try directory()
        let source = root.appendingPathComponent("Legacy.M")
        try Data().write(to: source)
        for (pattern, flag) in [("Legacy.M", "-fobjc-arc"), ("Other/*.m", "-fno-objc-arc")] {
            let rules = try NativeFileRules(["requires_arc": [pattern]], root: root, files: [source])
            XCTAssertEqual(rules.sourceSettings(source)["COMPILER_FLAGS"] as? String, flag)
        }
    }

    func testStaticConsumerLinkerRequirementsRespectEnabledRoots() throws {
        let root = try directory()
        let spec = try NativeSpec(
            data: [
                "name": "Kit", "version": "1.0", "libraries": ["sqlite3", "c++"],
                "frameworks": ["Security"], "weak_frameworks": ["Security", "StoreKit"],
            ], directory: root)
        let dependency = try NativeDependency(["name": "Kit"], platform: "osx", deployment: "13.0")
        let engine = try NativeXcode(
            project: root,
            manifest: [
                "targets": [
                    [
                        "name": "Demo", "platform": ["name": "osx", "deployment_target": "13.0"],
                        "dependencies": [["name": "Kit"]],
                    ]
                ]
            ], resolution: NativeResolution(specs: ["Kit": spec], requests: [dependency]), integrateUserProjects: false)
        XCTAssertEqual(
            try engine.consumerLinkerFlags(
                ["Kit"], platform: "osx", sources: [root.appendingPathComponent("main.mm")], settings: [:]),
            ["-ObjC", "-lsqlite3", "-framework", "\"Security\"", "-weak_framework", "\"StoreKit\""])
        XCTAssertTrue(try engine.consumerLinkerFlags([], platform: "osx", sources: [], settings: [:]).isEmpty)
        let existing = try engine.consumerLinkerFlags(
            ["Kit"], platform: "osx", sources: [], settings: ["OTHER_LDFLAGS": "$(inherited) -ObjC -lsqlite3"])
        XCTAssertFalse(existing.contains("-ObjC"))
        XCTAssertFalse(existing.contains("-lsqlite3"))
    }

    func testLinkerUsesExplicitSourceTypesBeforeKnownTypesAndExtensions() throws {
        let root = try directory()
        let engine = try NativeXcode(
            project: root, manifest: [:], resolution: NativeResolution(specs: [:], requests: []),
            integrateUserProjects: false)
        let graph = engine.graph
        graph.objects["TARGET"] = ["buildPhases": ["SOURCES", "RESOURCES"]]
        graph.objects["SOURCES"] = ["isa": "PBXSourcesBuildPhase", "files": ["BUILD"]]
        graph.objects["BUILD"] = ["fileRef": "FILE"]
        graph.objects["RESOURCES"] = ["isa": "PBXResourcesBuildPhase", "files": ["RESOURCE"]]
        graph.objects["RESOURCE"] = ["fileRef": "UNCOMPILED"]
        graph.objects["UNCOMPILED"] = ["path": "Unused.cpp"]
        let cases: [([String: String], Bool)] = [
            (["path": "main.mm"], true),
            (["path": "main.mm", "explicitFileType": "sourcecode.c.objc"], false),
            (["path": "main.mm", "lastKnownFileType": "sourcecode.c.objc"], false),
            (["path": "main.m", "lastKnownFileType": "sourcecode.cpp.objcpp"], true),
            (["path": "main.c", "explicitFileType": "sourcecode.cpp.cpp"], true),
            (
                [
                    "path": "main.mm", "lastKnownFileType": "sourcecode.cpp.objcpp",
                    "explicitFileType": "sourcecode.c.objc",
                ], false
            ),
            (
                [
                    "path": "main.m", "lastKnownFileType": "sourcecode.c.objc",
                    "explicitFileType": "sourcecode.cpp.objcpp",
                ], true
            ),
            (["path": "main.c"], false),
        ]
        for (source, expected) in cases {
            graph.objects["FILE"] = source
            let hasCXXSources = engine.linkerHasCXXSources("TARGET", graph: graph)
            XCTAssertEqual(hasCXXSources, expected, "\(source)")
            XCTAssertEqual(
                NativeBuildSettings.libraryFlags(
                    ["c++"], sources: [], settings: [:], linkingWithClang: true, hasCXXSources: hasCXXSources),
                expected ? [] : ["-lc++"], "\(source)")
        }
        graph.objects["SOURCES"]?["files"] = [] as [String]
        XCTAssertFalse(engine.linkerHasCXXSources("TARGET", graph: graph))
    }

    func testExcludedSourcesDoNotSupplyAnImplicitCXXRuntime() throws {
        let root = try directory()
        let engine = try NativeXcode(
            project: root, manifest: [:], resolution: NativeResolution(specs: [:], requests: []),
            integrateUserProjects: false)
        let graph = engine.graph
        graph.objects["TARGET"] = ["buildPhases": ["SOURCES"]]
        graph.objects["SOURCES"] = ["isa": "PBXSourcesBuildPhase", "files": ["BUILD"]]
        graph.objects["BUILD"] = ["fileRef": "FILE"]
        graph.objects["GROUP"] = ["path": "Sources", "children": ["FILE"], "sourceTree": "<group>"]
        graph.objects["FILE"] = ["path": "main file.mm", "sourceTree": "<group>"]
        let source = graph.sourceRoot.appendingPathComponent("Sources/main file.mm")
        let cases: [([String: Any], Bool)] = [
            ([:], true),
            (["EXCLUDED_SOURCE_FILE_NAMES": "*.mm"], false),
            (["EXCLUDED_SOURCE_FILE_NAMES": "*.cpp"], true),
            (["EXCLUDED_SOURCE_FILE_NAMES": "\"main file.mm\" other.c"], false),
            (["EXCLUDED_SOURCE_FILE_NAMES": "main\\ file.mm"], false),
            (["EXCLUDED_SOURCE_FILE_NAMES": "Sources/*.mm"], false),
            (["EXCLUDED_SOURCE_FILE_NAMES": NativeBuildSetting.quoted(source.path)], false),
            (["EXCLUDED_SOURCE_FILE_NAMES": ["other.c", "\"main file.mm\""]], false),
            (["EXCLUDED_SOURCE_FILE_NAMES": "*.mm", "INCLUDED_SOURCE_FILE_NAMES": "\"main file.mm\""], true),
            (["EXCLUDED_SOURCE_FILE_NAMES": "*.mm", "INCLUDED_SOURCE_FILE_NAMES": "other.mm"], false),
            (["INCLUDED_SOURCE_FILE_NAMES": "other.mm"], true),
        ]
        for (settings, expected) in cases {
            XCTAssertEqual(
                engine.linkerHasCXXSources("TARGET", graph: graph, settings: settings), expected, "\(settings)")
        }
        graph.objects["SOURCES"]?["files"] = ["BUILD", "SECOND"]
        graph.objects["SECOND"] = ["fileRef": "OTHER"]
        graph.objects["OTHER"] = ["path": "active.cpp", "sourceTree": "SOURCE_ROOT"]
        XCTAssertTrue(
            engine.linkerHasCXXSources("TARGET", graph: graph, settings: ["EXCLUDED_SOURCE_FILE_NAMES": "*.mm"]))
    }

    func testForcedCompilerLanguageOverridesFileMetadataButDoesNotAffectSwift() throws {
        let root = try directory()
        let engine = try NativeXcode(
            project: root, manifest: [:], resolution: NativeResolution(specs: [:], requests: []),
            integrateUserProjects: false)
        let graph = engine.graph
        graph.objects["TARGET"] = ["buildPhases": ["SOURCES"]]
        graph.objects["SOURCES"] = ["isa": "PBXSourcesBuildPhase", "files": ["BUILD"]]
        graph.objects["BUILD"] = ["fileRef": "FILE"]
        graph.objects["FILE"] = ["path": "main.mm", "explicitFileType": "sourcecode.cpp.objcpp"]
        XCTAssertFalse(
            engine.linkerHasCXXSources(
                "TARGET", graph: graph, settings: ["GCC_INPUT_FILETYPE": "sourcecode.c.objc"]))
        XCTAssertTrue(
            engine.linkerHasCXXSources(
                "TARGET", graph: graph, settings: ["GCC_INPUT_FILETYPE": "automatic"]))
        graph.objects["FILE"] = ["path": "main.m", "explicitFileType": "sourcecode.c.objc"]
        XCTAssertTrue(
            engine.linkerHasCXXSources(
                "TARGET", graph: graph, settings: ["GCC_INPUT_FILETYPE": "sourcecode.cpp.objcpp"]))
        graph.objects["FILE"] = ["path": "main.swift", "lastKnownFileType": "sourcecode.swift"]
        XCTAssertFalse(
            engine.linkerHasCXXSources(
                "TARGET", graph: graph, settings: ["GCC_INPUT_FILETYPE": "sourcecode.cpp.cpp"]))
    }

    func testPlatformFilteredSourcesDoNotSupplyAnImplicitCXXRuntime() throws {
        let root = try directory()
        let engine = try NativeXcode(
            project: root, manifest: [:], resolution: NativeResolution(specs: [:], requests: []),
            integrateUserProjects: false)
        let graph = engine.graph
        graph.objects["TARGET"] = ["buildPhases": ["SOURCES"]]
        graph.objects["SOURCES"] = ["isa": "PBXSourcesBuildPhase", "files": ["BUILD"]]
        graph.objects["FILE"] = ["path": "main.mm"]
        let customSDK = root.appendingPathComponent("Custom.sdk")
        try FileManager.default.createDirectory(at: customSDK, withIntermediateDirectories: true)
        try jsonData(["CanonicalName": "iphoneos.fixture"]).write(to: customSDK.appendingPathComponent("SDKSettings.json"))
        for key in ["platformFilter", "platformFilters"] {
            graph.objects["BUILD"] = ["fileRef": "FILE", key: key == "platformFilter" ? "ios" : ["ios"]]
            for (sdk, catalyst, expected) in [
                ("macosx", "NO", false), ("iphoneos", "NO", true), ("iphonesimulator", "NO", true),
                (customSDK.path, "NO", true),
                ("macosx", "YES", false),
            ] {
                XCTAssertEqual(
                    engine.linkerHasCXXSources(
                        "TARGET", graph: graph, settings: ["SDKROOT": sdk, "IS_MACCATALYST": catalyst]), expected)
            }
        }
        graph.objects["BUILD"] = ["fileRef": "FILE", "platformFilters": ["macos", "maccatalyst"]]
        for catalyst in ["NO", "YES"] {
            XCTAssertTrue(engine.linkerHasCXXSources(
                "TARGET", graph: graph, settings: ["SDKROOT": "macosx", "IS_MACCATALYST": catalyst]))
        }
    }

    func testUnicodeSpacesAreLiteralCharactersInSourceExclusionLists() {
        let root = URL(fileURLWithPath: "/SDK")
        for separator in ["\u{00a0}", "\u{2003}", "\u{2028}", "\u{2029}"] {
            let name = "main" + separator + "optional.mm"
            let source = root.appendingPathComponent(name)
            for pattern in [name, NativeBuildSetting.quoted(name)] {
                XCTAssertTrue(NativeBuildSettings.sourceIsExcluded(
                    source, relativeTo: root, settings: ["EXCLUDED_SOURCE_FILE_NAMES": pattern]))
                XCTAssertFalse(NativeBuildSettings.sourceIsExcluded(
                    source, relativeTo: root,
                    settings: ["EXCLUDED_SOURCE_FILE_NAMES": "*.mm", "INCLUDED_SOURCE_FILE_NAMES": pattern]))
            }
        }
    }

    func testLinkerFlagsRemainConditionalForEachBuildArchitecture() throws {
        let root = try directory()
        let sdk = root.appendingPathComponent("Fixture.sdk")
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        try jsonData([
            "CanonicalName": "macosx.fixture",
            "SupportedTargets": ["macosx": ["Archs": ["arm64", "x86_64"]]],
        ]).write(to: sdk.appendingPathComponent("SDKSettings.json"))
        let engine = try NativeXcode(
            project: root, manifest: [:], resolution: NativeResolution(specs: [:], requests: []),
            integrateUserProjects: false)
        let graph = engine.graph
        graph.objects["TARGET"] = ["name": "App", "buildPhases": ["SOURCES"]]
        XCTAssertEqual(
            engine.linkerSDKContext.architectures("Fixture.sdk", target: "macosx", relativeTo: root),
            ["arm64", "x86_64"])
        graph.objects["SOURCES"] = ["isa": "PBXSourcesBuildPhase", "files": ["BUILD"]]
        graph.objects["BUILD"] = ["fileRef": "FILE"]
        graph.objects["FILE"] = ["path": "main.mm"]
        var settings: [String: Any] = [
            "SDKROOT": sdk.path, "EXCLUDED_SOURCE_FILE_NAMES[arch=arm64]": "main.mm",
        ]
        let configuration: [String: Any] = ["name": "Debug", "buildSettings": settings]
        let flags = try engine.configuredLinkerFlags(
            configuration, target: "TARGET", graph: graph, platform: "osx", settings: &settings
        ) { values, scope, forced in
            NativeBuildSettings.libraryFlags(
                ["c++"], sources: [], settings: values, linkingWithClang: true,
                hasCXXSources: forced ?? engine.linkerHasCXXSources("TARGET", graph: graph, settings: values, scope: scope))
        }
        XCTAssertEqual(flags, ["$(SWIFTPODS_LINKER_FLAGS)"])
        settings["OTHER_LDFLAGS"] = flags
        for (arch, expected) in [("arm64", "-lc++"), ("x86_64", "")] {
            let scope = try NativeBuildSettings.resolvedScopes(
                ["name": "Debug", "buildSettings": settings], graph: graph, targetName: "App",
                buildOverrides: ["SDKROOT": sdk.path, "CURRENT_ARCH": arch]).targetScope
            XCTAssertEqual(try scope.expandedValue("OTHER_LDFLAGS"), expected)
        }
    }

    func testWhyRetainsPlatformDependentEdgesAndMarksAmbiguousLegacyRecords() throws {
        let ios = ["name": "ios", "deployment_target": "15.0"]
        let mac = ["name": "osx", "deployment_target": "13.0"]
        var specs: [[String: Any]] = [
            ["name": "Kit", "platform": ios, "dependencies": [["name": "IOSHelper", "requirement": ">= 0"]]],
            ["name": "Kit", "platform": mac, "dependencies": [["name": "MacHelper", "requirement": ">= 0"]]],
            ["name": "IOSHelper", "platform": ios, "dependencies": []],
            ["name": "MacHelper", "platform": mac, "dependencies": []],
        ]
        let targets: [[String: Any]] = [
            ["name": "IOSApp", "platform": ios, "dependencies": [["name": "Kit"]]],
            ["name": "MacApp", "platform": mac, "dependencies": [["name": "Kit"]]],
        ]
        for (query, target) in [("IOSHelper", "IOSApp"), ("MacHelper", "MacApp")] {
            let result = try DependencyGraph.why(query, report: ["specs": specs, "targets": targets])
            let chains = try XCTUnwrap(result["dependency_chains"] as? [[String: Any]])
            XCTAssertEqual(chains.count, 1)
            XCTAssertEqual(chains.first?["target"] as? String, target)
        }
        specs = specs.map { $0.filter { $0.key != "platform" } }
        let legacy = try DependencyGraph.why("IOSHelper", report: ["specs": specs, "targets": targets])
        XCTAssertEqual(legacy["chains_status"] as? String, "legacy_report_requires_reinstall")
        XCTAssertTrue((legacy["dependency_chains"] as? [[String: Any]])?.isEmpty == true)
    }

    func testForgettingMissingProjectPreservesOtherOwnedProjects() {
        let removed = "/Apps/Old.xcodeproj/project.pbxproj"
        let kept = "/Apps/Current.xcodeproj/project.pbxproj"
        let settings: [String: Any] = [
            removed + ":CONFIG": ["written": ["PODS_ROOT": "/Pods"]], kept + ":CONFIG": [:],
            "_base_configurations": [removed + ":CONFIG": "A", kept + ":CONFIG": "B"],
            "_swift_packages": [removed: ["objects": [:]], kept: ["objects": [:]]],
            "_project_attributes": [removed: [:], kept: [:]], "_products": ["PRODUCT"],
        ]
        let cleaned = NativeIntegrationSettings.removingProject(removed, from: settings)
        XCTAssertEqual(NativeIntegrationSettings.projectPaths(cleaned), [kept])
        XCTAssertEqual(cleaned["_products"] as? [String], ["PRODUCT"])
        XCTAssertEqual((cleaned["_base_configurations"] as? [String: String])?[kept + ":CONFIG"], "B")
    }
}
