import XCTest

@testable import SwiftPodsCore

final class NativeSwiftPackageCompileSettingsTests: XCTestCase {
    private func fixture(dependencies: [[String: Any]]? = nil) throws -> (URL, NativePBX, NativeSwiftPackageGraph) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("Resolved")
        let include = cache.appendingPathComponent("checkouts/SDK/Sources/Core/Public")
        let helper = cache.appendingPathComponent("checkouts/SDK/Sources/Helper/include")
        try FileManager.default.createDirectory(at: include, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        try Data("module Core { header \"Core.h\" export * }\n".utf8).write(to: include.appendingPathComponent("module.modulemap"))
        try Data("int core(void);\n".utf8).write(to: include.appendingPathComponent("Core.h"))
        try Data("int helper(void);\n".utf8).write(to: helper.appendingPathComponent("Helper.h"))
        try jsonData(["version": 7, "object": ["dependencies": [[
            "packageRef": ["identity": "sdk", "location": "https://example.invalid/sdk.git"],
            "state": ["name": "sourceControlCheckout"], "subpath": "SDK",
        ]], "artifacts": []]]).write(to: cache.appendingPathComponent("workspace-state.json"))
        let user = try NativePBX(root.appendingPathComponent("App.xcodeproj/project.pbxproj"))
        let maps = NativeSwiftPackageModuleMaps(directory: root.appendingPathComponent("Support"))
        let graph = try NativeSwiftPackageGraph(directory: cache, environment: [:], moduleMaps: maps) { _ in
            ["products": [["name": "SDK", "targets": ["Core"]]], "targets": [
                ["name": "Core", "type": "regular", "publicHeadersPath": "Public", "dependencies": dependencies ?? [
                    ["target": ["Helper", ["platformNames": ["macos"]]]],
                ]],
                ["name": "Helper", "type": "regular", "dependencies": []],
            ]]
        }
        return (root, user, graph)
    }

    private func declaration() throws -> NativeSwiftPackageDeclaration {
        try NativeSwiftPackageDeclaration([
            "git": "https://example.invalid/sdk.git", "exact": "1.0.0", "products": ["SDK"], "link": false,
        ])
    }

    func testHeadersAndMapsFollowConditionalTransitiveTargetsAndStayCompilerOnly() throws {
        let (_, user, graph) = try fixture()
        let mac = try NativeSwiftPackageCompileSettings.interface(
            [declaration()], graph: graph,
            destination: .init(sdk: "macosx", platform: "osx", variant: "device", architecture: "arm64"), user: user)
        XCTAssertEqual(mac.headers.count, 2)
        XCTAssertEqual(mac.maps.count, 2)
        XCTAssertTrue(mac.maps.contains { $0.hasSuffix("Core/Public/module.modulemap") })
        XCTAssertFalse(mac.maps.contains { $0.contains("GENERATED_MODULEMAP_DIR") })
        XCTAssertEqual(graph.moduleMaps.files.count, 1)
        let generated = try XCTUnwrap(graph.moduleMaps.files.values.first)
        XCTAssertTrue(String(decoding: generated, as: UTF8.self).contains("umbrella header \"../Resolved/checkouts/SDK/Sources/Helper/include/Helper.h\""))
        let ios = try NativeSwiftPackageCompileSettings.interface(
            [declaration()], graph: graph,
            destination: .init(sdk: "iphonesimulator", platform: "ios", variant: "simulator", architecture: "arm64"), user: user)
        XCTAssertEqual(ios.headers.count, 1)
        XCTAssertEqual(ios.maps.count, 1)
        XCTAssertTrue(ios.frameworks.isEmpty)
    }

    func testExportsPreserveFlagsAndDoNotAddAnyLinkerOrArchiveInput() throws {
        let (root, user, graph) = try fixture()
        let sdk = root.appendingPathComponent("SDK.sdk")
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        try jsonData(["CanonicalName": "macosx.fixture", "SupportedTargets": ["macosx": ["Archs": ["arm64", "x86_64"]]]])
            .write(to: sdk.appendingPathComponent("SDKSettings.json"))
        var settings: [String: Any] = [
            "OTHER_CFLAGS": ["$(inherited)", "-DUSER=1"], "OTHER_CPLUSPLUSFLAGS": ["-DCPP=1"],
            "HEADER_SEARCH_PATHS": ["$(inherited)", "User"], "OTHER_LDFLAGS": "-all_load",
        ]
        try NativeSwiftPackageCompileSettings.apply(
            [declaration()], graph: graph, platform: "osx", user: user,
            sdkContext: NativeSDKContext(locate: { _, _ in sdk }), settings: &settings)
        XCTAssertEqual(settings["OTHER_LDFLAGS"] as? String, "-all_load")
        XCTAssertNil(settings["LIBRARY_SEARCH_PATHS"])
        XCTAssertNil(settings["OTHER_LIBTOOLFLAGS"])
        XCTAssertEqual(settings["OTHER_CFLAGS"] as? [String], ["$(inherited)", "-DUSER=1", "$(SWIFTPODS_SPM_CFLAGS)"])
        XCTAssertEqual(settings["OTHER_CPLUSPLUSFLAGS"] as? [String], ["-DCPP=1", "$(SWIFTPODS_SPM_CFLAGS)"])
        XCTAssertTrue(nativeStrings(settings["SWIFTPODS_SPM_HEADERS"]).allSatisfy { $0.contains("$(SRCROOT)") })
        XCTAssertFalse(settings.keys.contains { $0.contains("[arch=") })
    }

    func testRemovingTheLastPackagePreservesSubsequentUserFlagEdits() throws {
        for list: Any in [["$(inherited)", "-DUSER=1"], "$(inherited) -DUSER=1"] {
            let original: [String: Any] = ["OTHER_CFLAGS": list]
            let written: [String: Any] = ["OTHER_CFLAGS": nativeStrings(list) + ["$(SWIFTPODS_SPM_CFLAGS)"]]
            let record = try NativeIntegrationSettings.record(before: original, after: written)
            let current: [String: Any] = ["OTHER_CFLAGS": nativeStrings(written["OTHER_CFLAGS"]) + ["-DNEW=2"]]
            let restored = try NativeIntegrationSettings.restore(current, record: record)
            XCTAssertEqual(restored["OTHER_CFLAGS"] as? [String], nativeStrings(list) + ["-DNEW=2"])
            XCTAssertEqual(try NativeIntegrationSettings.restore(written, record: record)["OTHER_CFLAGS"] as? String, list as? String)
        }
    }

    func testGeneratedMapsAreStableAndObsoleteMapsAreRemovedWithoutDeletingUserFiles() throws {
        let (root, _, graph) = try fixture()
        let maps = graph.moduleMaps
        let headers = graph.directory.appendingPathComponent("checkouts/SDK/Sources/Helper/include")
        let first = try maps.generated(name: "Helper", headers: headers, identity: "helper")
        try maps.save()
        let bytes = try Data(contentsOf: first)
        let second = NativeSwiftPackageModuleMaps(directory: maps.directory)
        XCTAssertEqual(try second.generated(name: "Helper", headers: headers, identity: "helper"), first)
        try second.save()
        XCTAssertEqual(try Data(contentsOf: first), bytes)
        let manual = maps.directory.appendingPathComponent("user.modulemap")
        try Data("user".utf8).write(to: manual)
        try NativeSwiftPackageModuleMaps(directory: maps.directory).save()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manual.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testModuleNamesMatchSwiftPMIncludingUnicodeAndLeadingDigits() {
        for (name, expected) in [
            ("A-B", "A_B"), ("9SDK", "_SDK"), ("Étage", "Étage"), ("ΣSDK", "ΣSDK"),
            ("中文", "中文"), ("😀SDK", "_SDK"), ("١SDK", "_SDK"),
        ] {
            XCTAssertEqual(NativeSwiftPackageModuleMaps.moduleName(name), expected)
        }
    }

    func testSingleTargetSourceRootsAndNestedUmbrellaHeadersMatchSwiftPMLayout() throws {
        let (root, user, _) = try fixture()
        let cache = root.appendingPathComponent("Resolved")
        let package = cache.appendingPathComponent("checkouts/SDK")
        let headers = package.appendingPathComponent("src/Public/Only_Core")
        try FileManager.default.createDirectory(at: headers, withIntermediateDirectories: true)
        try Data("int value(void);\n".utf8).write(to: headers.appendingPathComponent("Only_Core.h"))
        try FileManager.default.removeItem(at: package.appendingPathComponent("Sources"))
        let maps = NativeSwiftPackageModuleMaps(directory: root.appendingPathComponent("Nested Maps"))
        let graph = try NativeSwiftPackageGraph(directory: cache, environment: [:], moduleMaps: maps) { _ in
            ["products": [["name": "SDK", "targets": ["Only-Core"]]], "targets": [
                ["name": "Only-Core", "publicHeadersPath": "Public", "type": "regular"],
            ]]
        }
        let exported = try NativeSwiftPackageCompileSettings.interface([declaration()], graph: graph,
            destination: .init(sdk: "macosx", platform: "osx", variant: "device", architecture: "arm64"), user: user)
        XCTAssertEqual(exported.headers.count, 1)
        XCTAssertTrue(String(decoding: try XCTUnwrap(maps.files.values.first), as: UTF8.self).contains("module Only_Core"))
        XCTAssertTrue(String(decoding: try XCTUnwrap(maps.files.values.first), as: UTF8.self).contains("Public/Only_Core/Only_Core.h"))
    }

    func testMacroImplementationsAndTheirHostDependenciesDoNotExportCompilerInterfaces() throws {
        let (_, user, previous) = try fixture()
        let package = previous.directory.appendingPathComponent("checkouts/SDK")
        for name in ["SwiftAPI", "Implementation"] {
            let sources = package.appendingPathComponent("Sources/" + name)
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            try Data("// Swift source\n".utf8).write(to: sources.appendingPathComponent("Source.swift"))
        }
        let support = package.appendingPathComponent("Sources/CompilerSupport/include")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("int compiler_support(void);\n".utf8).write(to: support.appendingPathComponent("CompilerSupport.h"))
        let graph = try NativeSwiftPackageGraph(
            directory: previous.directory, environment: [:], moduleMaps: previous.moduleMaps
        ) { _ in
            ["products": [["name": "SDK", "targets": ["Core", "SwiftAPI"]]], "targets": [
                ["name": "Core", "type": "regular", "publicHeadersPath": "Public"],
                ["name": "SwiftAPI", "type": "regular", "dependencies": [["target": ["Implementation", NSNull()]]]],
                [
                    "name": "Implementation", "type": "macro",
                    "dependencies": [["target": ["CompilerSupport", NSNull()]]],
                ],
                ["name": "CompilerSupport", "type": "regular"],
            ]]
        }
        let exported = try NativeSwiftPackageCompileSettings.interface(
            [declaration()], graph: graph,
            destination: .init(sdk: "macosx", platform: "osx", variant: "device", architecture: "arm64"), user: user)
        XCTAssertEqual(
            exported.headers, [user.buildSettingPath(package.appendingPathComponent("Sources/Core/Public"))])
        XCTAssertEqual(exported.maps, [
            user.buildSettingPath(package.appendingPathComponent("Sources/Core/Public/module.modulemap")),
            "$(GENERATED_MODULEMAP_DIR)/SwiftAPI.modulemap",
        ])
        XCTAssertTrue(graph.moduleMaps.files.isEmpty)
    }

    func testSystemLibraryUsesItsOwnModuleMapInEachSupportedSourceDirectory() throws {
        let (_, user, previous) = try fixture()
        let package = previous.directory.appendingPathComponent("checkouts/SDK")
        let legacy = package.appendingPathComponent("module.modulemap")
        try Data("module Legacy { export * }\n".utf8).write(to: legacy)
        for base in ["Sources", "Source", "src", "srcs"] {
            let sources = package.appendingPathComponent(base + "/CSystem")
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            let map = sources.appendingPathComponent("module.modulemap")
            try Data("module CSystem [system] { header \"/sdk/include/sqlite3.h\" export * }\n".utf8).write(to: map)
            let graph = try NativeSwiftPackageGraph(
                directory: previous.directory, environment: [:], moduleMaps: previous.moduleMaps
            ) { _ in
                ["products": [["name": "SDK", "targets": ["CSystem"]]],
                    "targets": [["name": "CSystem", "type": "system"]]]
            }
            let exported = try NativeSwiftPackageCompileSettings.interface(
                [declaration()], graph: graph,
                destination: .init(sdk: "macosx", platform: "osx", variant: "device", architecture: "arm64"), user: user)
            XCTAssertEqual(exported.headers, [user.buildSettingPath(sources)])
            XCTAssertEqual(exported.maps, [user.buildSettingPath(map)])
            XCTAssertTrue(graph.moduleMaps.files.isEmpty)
            try FileManager.default.removeItem(at: sources)
        }
    }

    func testSystemLibraryKeepsExplicitPathsAndLegacyRootLayouts() throws {
        let (_, _, graph) = try fixture()
        let package = try graph.package("https://example.invalid/sdk.git")
        XCTAssertEqual(
            try graph.targetDirectory(["name": "Legacy", "type": "system"], package: package), package.directory)
        XCTAssertEqual(
            try graph.targetDirectory(["name": "Custom", "type": "system", "path": "Bindings"], package: package),
            package.directory.appendingPathComponent("Bindings"))
    }

    func testResolutionPinsCanBeRecoveredInsideAndOutsideThePodfileDirectory() throws {
        let (root, _, _) = try fixture()
        let project = root.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let pins = [project.appendingPathComponent("Local.xcworkspace"), root.appendingPathComponent("External.xcworkspace")]
            .map { $0.appendingPathComponent("xcshareddata/swiftpm/Package.resolved") }
        for path in pins {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("original pins".utf8).write(to: path)
        }
        let state = ProjectState(directory: project)
        try state.acquire()
        try state.begin(command: ["install"], profile: "test")
        for path in pins {
            try state.registerProject(path)
            try Data("new pins".utf8).write(to: path)
        }
        _ = try state.finish(result: HostResult(status: 1, events: pins.map {
            ["kind": "managed_write", "path": $0.path]
        }), command: ["install"], profile: "test")
        _ = try state.recover()
        for path in pins { XCTAssertEqual(try Data(contentsOf: path), Data("original pins".utf8)) }
    }

    func testUnsupportedTraitAndModuleAliasInterfacesFailInsteadOfExportingTheWrongHeaders() throws {
        for (dependency, code): ([String: Any], String) in [
            (["target": ["Helper", ["traits": ["Enabled"]]]], "SP-SPM-CONDITION"),
            (["product": ["Remote", "repo", ["Original": "Alias"], NSNull()]], "SP-SPM-ALIASES"),
        ] {
            let (_, user, graph) = try fixture(dependencies: [dependency])
            XCTAssertThrowsError(try NativeSwiftPackageCompileSettings.interface(
                [declaration()], graph: graph,
                destination: .init(sdk: "macosx", platform: "osx", variant: "device", architecture: "arm64"), user: user)
            ) { XCTAssertEqual(($0 as? Diagnostic)?.code, code) }
        }
    }

    func testUserSettingsInTheReservedNamespaceAreNotOverwritten() throws {
        let (_, user, graph) = try fixture()
        var settings: [String: Any] = ["SWIFTPODS_SPM_HEADERS": "user data", "OTHER_CFLAGS": "-DUSER=1"]
        let before = try jsonData(settings)
        XCTAssertThrowsError(try NativeSwiftPackageCompileSettings.apply(
            [declaration()], graph: graph, platform: "osx", user: user,
            sdkContext: NativeSDKContext(locate: { _, _ in nil }), settings: &settings)
        ) { XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-SPM-CONFLICT") }
        XCTAssertEqual(try jsonData(settings), before)
    }

    func testResolvedInterfaceCacheIgnoresDisplayNamesButTracksRevisions() throws {
        let (_, _, graph) = try fixture()
        let file = graph.directory.appendingPathComponent("workspace-state.json")
        let original = try graph.resolutionFingerprint()
        var state = try readObject(file)
        var object = try XCTUnwrap(state["object"] as? [String: Any])
        var dependencies = try XCTUnwrap(object["dependencies"] as? [[String: Any]])
        var reference = try XCTUnwrap(dependencies[0]["packageRef"] as? [String: Any])
        reference["name"] = "Different display name for the same repository"
        dependencies[0]["packageRef"] = reference
        object["dependencies"] = dependencies
        state["object"] = object
        try jsonData(state).write(to: file)
        XCTAssertEqual(try graph.resolutionFingerprint(), original)
        dependencies[0]["state"] = ["name": "sourceControlCheckout", "checkoutState": ["revision": "new revision"]]
        object["dependencies"] = dependencies
        state["object"] = object
        try jsonData(state).write(to: file)
        XCTAssertNotEqual(try graph.resolutionFingerprint(), original)
    }
}
