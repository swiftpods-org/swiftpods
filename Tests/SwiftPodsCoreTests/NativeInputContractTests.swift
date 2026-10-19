import XCTest

@testable import SwiftPodsCore

final class NativeInputContractTests: XCTestCase {
    func testLintKeepsCompilerErrorsWhenCommandLinesFillTheLogTail() {
        let text =
            "Kit.h:1:2: error: Invalid public interface\n"
            + String(repeating: "compiler command arguments\n", count: 1000)
        let summary = NativeValidation.failureOutput(ToolOutput(status: 1, output: Data(text.utf8), error: Data()))
        XCTAssertTrue(summary.contains("Kit.h:1:2: error: Invalid public interface"))
        XCTAssertLessThan(summary.count, 6001)
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testDerivedModuleNamesNormalizeButExplicitIdentifiersRemainUnchanged() throws {
        XCTAssertEqual(try NativeSpec(data: ["name": "Kit--Core", "version": "1.0"]).moduleName, "Kit_Core")
        XCTAssertEqual(try NativeSpec(data: ["name": "1__Kit", "version": "1.0"]).moduleName, "_1_Kit")
        XCTAssertEqual(
            try NativeSpec(data: ["name": "Kit", "version": "1.0", "header_dir": "Custom--Kit"]).moduleName,
            "Custom_Kit")
        XCTAssertEqual(
            try NativeSpec(data: ["name": "Kit", "version": "1.0", "module_name": "_Kit__Core"]).moduleName,
            "_Kit__Core")
    }

    func testSnapshotRevisionIsBoundToContentAndCacheKeyButNotOwners() throws {
        let cache = try directory()
        let root = cache.appendingPathComponent("snapshots/" + String(repeating: "a", count: 64))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: root.appendingPathComponent("Kit.c"))
        try NativeSnapshotCache.write(
            root, metadata: ["checkout": ["hg": "local", "revision": String(repeating: "b", count: 40)]])
        XCTAssertEqual(try NativeCacheIntegrity.verify(cache)["status"] as? String, "passed")
        var metadata = try NativeSnapshotCache.verify(root)
        metadata["pod_names"] = ["Kit", "Peer"]
        try jsonData(metadata).write(to: root.appendingPathExtension("origin.json"))
        XCTAssertNoThrow(try NativeSnapshotCache.verify(root))
        metadata["checkout"] = ["hg": "local", "revision": String(repeating: "c", count: 40)]
        try jsonData(metadata).write(to: root.appendingPathExtension("origin.json"))
        XCTAssertThrowsError(try NativeSnapshotCache.verify(root))
        XCTAssertThrowsError(try NativeCacheIntegrity.verify(cache))
        XCTAssertThrowsError(try NativeMaintenance.run(["cache", "list"], cache: cache))
    }

    func testLegacySnapshotIsNotPromotedToAnInstallableRevision() throws {
        let root = try directory()
        let metadata: [String: Any] = [
            "fingerprint": try FileFingerprint.tree(root, requireContainedLinks: true),
            "checkout": ["hg": "local", "revision": "untrusted"], "pod_names": ["Kit"],
        ]
        try jsonData(metadata).write(to: root.appendingPathExtension("origin.json"))
        defer { try? FileManager.default.removeItem(at: root.appendingPathExtension("origin.json")) }
        XCTAssertThrowsError(try NativeSnapshotCache.verify(root))
        XCTAssertNil(try NativeSnapshotCache.maintenanceMetadata(root)["checkout"])
    }

    func testIncrementalStateRejectsChangedRevisionAndDisagreementWithLock() throws {
        let pin = ["git": "local", "commit": String(repeating: "a", count: 40)]
        var metadata = try NativeSourceState.metadata(identity: "identity", fingerprint: "tree", checkout: pin)
        XCTAssertEqual(try NativeSourceState.checkout(metadata, pin: pin), pin)
        XCTAssertNil(try NativeSourceState.checkout(["checkout": pin], pin: pin))
        let changed = ["git": "local", "commit": String(repeating: "b", count: 40)]
        metadata["checkout"] = changed
        XCTAssertThrowsError(try NativeSourceState.checkout(metadata, pin: pin))
        let resealed = try NativeSourceState.metadata(identity: "identity", fingerprint: "tree", checkout: changed)
        XCTAssertThrowsError(try NativeSourceState.checkout(resealed, pin: pin))
    }

    func testLocalizedResourcesKeepTheirIndividualOnDemandTags() throws {
        let root = try directory()
        let paths = try ["en", "fr"].map { language -> URL in
            let file = root.appendingPathComponent(language + ".lproj/Localizable.strings")
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("\"hello\" = \"Hello\";\n".utf8).write(to: file)
            return file
        }
        let odr = try NativeOnDemandResources(
            attributes: [
                "on_demand_resources": [
                    "Language": "*.lproj/*.strings",
                    "English": ["paths": "en.lproj/*.strings", "category": "prefetched"],
                ]
            ], root: root)
        let graph = try NativePBX(root.appendingPathComponent("App.xcodeproj/project.pbxproj"))
        let target = graph.add("app", ["isa": "PBXNativeTarget", "buildPhases": []])
        try NativeResources.apply(paths, target: target, graph: graph, ungrouped: Set(odr.files.keys))
        odr.tag(target: target, graph: graph)
        let builds = graph.objects.values.filter { $0["isa"] as? String == "PBXBuildFile" }
        XCTAssertEqual(builds.count, 2)
        for build in builds {
            let ref = try XCTUnwrap(build["fileRef"] as? String)
            let path = try XCTUnwrap(graph.objects[ref]?["path"] as? String)
            let tags = nativeStrings((build["settings"] as? [String: Any])?["ASSET_TAGS"])
            XCTAssertEqual(tags, path.contains("en.lproj") ? ["English", "Language"] : ["Language"])
        }
        let before = try jsonData(graph.objects)
        try NativeResources.apply(paths, target: target, graph: graph, ungrouped: Set(odr.files.keys))
        odr.tag(target: target, graph: graph)
        XCTAssertEqual(try jsonData(graph.objects), before)
    }
}
