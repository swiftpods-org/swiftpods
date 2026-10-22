import XCTest

@testable import SwiftPodsCore

final class NativeHeaderOwnershipTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testLegacyCleanupKeepsUnselectedTargetsAndSharedPhaseObjects() throws {
        let root = try directory()
        let engine = try NativeXcode(
            project: root, manifest: ["targets": [["name": "Demo", "project": "Demo.xcodeproj"]]],
            resolution: NativeResolution(specs: [:], requests: []), integrateUserProjects: false)
        let user = try NativePBX(root.appendingPathComponent("Demo.xcodeproj/project.pbxproj"))
        let old = user.add("legacy", ["isa": "PBXShellScriptBuildPhase", "name": "[CP] Embed Pods Frameworks"])
        let shared = user.add("shared", ["isa": "PBXShellScriptBuildPhase", "name": "[CP-User] Shared"])
        let foreign = user.add("foreign", ["isa": "PBXShellScriptBuildPhase", "name": "[CP-User] Other script"])
        let demo = user.add("demo", ["isa": "PBXNativeTarget", "name": "Demo", "buildPhases": [old, shared]])
        let other = user.add("other", ["isa": "PBXNativeTarget", "name": "Other", "buildPhases": [foreign, shared]])
        let before = try jsonData(user.objects[other]!)
        try engine.removePreviousAggregateIntegration(user)
        XCTAssertNil(user.objects[old])
        XCTAssertEqual(user.objects[demo]?["buildPhases"] as? [String], [])
        XCTAssertEqual(try jsonData(user.objects[other]!), before)
        XCTAssertNotNil(user.objects[shared])
        XCTAssertNotNil(user.objects[foreign])
        try engine.removePreviousAggregateIntegration(user)
        XCTAssertEqual(try jsonData(user.objects[other]!), before)
    }

    func testResourceBundleNamesSeparateAmbiguousPairsAndReservedTargets() throws {
        let preferred = ["111": "Kit-A-Shared", "222": "Kit-A-Shared", "333": "Reserved", "444": "Normal"]
        let labels = NativeResourceBundleNames.assign(preferred, reserved: ["Reserved"])
        XCTAssertEqual(Set(labels.values).count, 4)
        XCTAssertNotEqual(labels["111"], labels["222"])
        XCTAssertNotEqual(labels["333"], "Reserved")
        XCTAssertEqual(labels["444"], "Normal")
        XCTAssertEqual(labels, NativeResourceBundleNames.assign(preferred, reserved: ["Reserved"]))
    }

    func testResourceTargetLabelsReserveCaseVariantsOfOtherTargets() {
        let preferred = ["111": "Kit-Shared", "222": "kit-shared", "333": "pods-app-resources"]
        let labels = NativeResourceBundleNames.assign(preferred, reserved: ["Pods-App-Resources"])
        XCTAssertEqual(Set(labels.values.map { $0.lowercased() }).count, 3)
        XCTAssertFalse(labels.values.contains { $0.lowercased() == "pods-app-resources" })
    }

    func testPrivateAndProjectLibraryHeadersStayOutsideConsumerSearchPaths() throws {
        let root = try directory()
        for name in ["Kit.h", "Private.h", "Project.h", "Internal.h"] {
            try Data("// header\n".utf8).write(to: root.appendingPathComponent(name))
        }
        let spec = try NativeSpec(
            data: [
                "name": "Kit", "version": "1.0", "source_files": "*.h",
                "public_header_files": "Kit.h", "private_header_files": "Private.h",
                "project_header_files": "Project.h",
            ], directory: root)
        let engine = try generated(root: root, spec: spec)
        let privateRoot = root.appendingPathComponent(
            engine.headerDirectory("Kit", platform: "osx", visibility: .privateHeaders))
        for name in ["Private.h", "Project.h", "Internal.h"] {
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(
                    atPath: privateRoot.appendingPathComponent("Kit/" + name).path),
                root.appendingPathComponent(name).path)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(engine.headerDirectory("Kit", platform: "osx") + "/Kit/" + name)
                        .path))
        }
        XCTAssertFalse(engine.headerSettings(["Kit"], platform: "osx").contains { $0.contains("Headers/Private") })
    }

    func testCustomMapKeepsOriginalHeaderPathsAndReachesClangAndSwiftConsumers() throws {
        let root = try directory().appendingPathComponent("Path With Spaces")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let map = root.appendingPathComponent("Custom.modulemap")
        let contents = "module Kit { header \"Kit.h\" export * }\nmodule Feature { header \"Feature.h\" export * }\n"
        try Data(contents.utf8).write(to: map)
        for name in ["Kit.h", "Feature.h"] { try Data("// header\n".utf8).write(to: root.appendingPathComponent(name)) }
        let spec = try NativeSpec(
            data: ["name": "Kit", "version": "1.0", "source_files": "*.h", "module_map": "Custom.modulemap"],
            directory: root)
        let engine = try generated(root: root, spec: spec)
        XCTAssertEqual(engine.customModuleMaps["Kit:osx"], map)
        XCTAssertEqual(try String(contentsOf: map, encoding: .utf8), contents)
        let automatic = root.appendingPathComponent(
            engine.headerDirectory("Kit", platform: "osx") + "/Kit/module.modulemap")
        XCTAssertFalse(FileManager.default.fileExists(atPath: automatic.path))
        var settings: [String: Any] = ["OTHER_CFLAGS": ["$(inherited)", "-DUSER"]]
        engine.applyCustomModuleMaps(["Kit"], platform: "osx", settings: &settings)
        let flag = "-fmodule-map-file=" + NativeBuildSetting.quoted(map.path)
        XCTAssertEqual(settings["OTHER_CFLAGS"] as? [String], ["$(inherited)", "-DUSER", flag])
        XCTAssertEqual(settings["OTHER_SWIFT_FLAGS"] as? [String], ["$(inherited)", "-Xcc", flag])
    }

    func testHeaderPositionsIncludeEveryMappedCopyPhase() throws {
        let graph = try NativePBX(try directory().appendingPathComponent("project.pbxproj"))
        let copy = graph.add("copy", ["isa": "PBXCopyFilesBuildPhase", "dstPath": "$(PUBLIC_HEADERS_FOLDER_PATH)/Sub"])
        let headers = graph.add("headers", ["isa": "PBXHeadersBuildPhase"])
        let privateCopy = graph.add(
            "private", ["isa": "PBXCopyFilesBuildPhase", "dstPath": "$(PRIVATE_HEADERS_FOLDER_PATH)"])
        let target = graph.add("target", ["isa": "PBXNativeTarget", "buildPhases": [copy, headers, privateCopy]])
        let scripts = try ["before_headers", "after_headers"].map {
            try NativeScriptPhase(["name": $0, "script": "true", "execution_position": $0])
        }
        NativeScriptPhase.apply(scripts, target: target, graph: graph)
        let first = try XCTUnwrap(graph.objects[target]?["buildPhases"] as? [String])
        XCTAssertEqual(graph.objects[first.first!]?["name"] as? String, "[CP-User] before_headers")
        XCTAssertEqual(graph.objects[first.last!]?["name"] as? String, "[CP-User] after_headers")
        NativeScriptPhase.apply(scripts, target: target, graph: graph)
        XCTAssertEqual(graph.objects[target]?["buildPhases"] as? [String], first)
    }

    private func generated(root: URL, spec: NativeSpec) throws -> NativeXcode {
        let request = try NativeDependency(["name": "Kit"], platform: "osx", deployment: "13.0")
        let engine = try NativeXcode(
            project: root,
            manifest: ["targets": [["name": "Demo", "platform": ["name": "osx"], "dependencies": [["name": "Kit"]]]]],
            resolution: NativeResolution(specs: ["Kit": spec], requests: [request]), integrateUserProjects: false)
        try engine.generate()
        return engine
    }
}
