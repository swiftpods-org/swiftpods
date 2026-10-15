import XCTest
@testable import SwiftPodsCore

final class NativeBatchTests: XCTestCase {
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }
    private func write(_ name: String, root: URL) throws {
        let path = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(name.utf8).write(to: path)
    }
    func testMultipleRecursiveGlobsBracesAndHiddenDirectoryRules() throws {
        let root = try directory()
        for file in ["Sources/Layer/a.m", "Sources/Deep/Layer/Nested/b.mm", "Sources/.hidden/Layer/c.m", "Sources/Layer/a.h"] { try write(file, root: root) }
        let files = try nativeGlob("Sources/**/Layer/**/*.{m,mm}", root: root).map(\.lastPathComponent)
        XCTAssertEqual(files, ["b.mm", "a.m"])
        XCTAssertThrowsError(try nativeGlob("{..,Sources}/*", root: root))
    }
    func testHeaderVisibilityAndPerFileARC() throws {
        let root = try directory()
        for file in ["public.h", "private.h", "project.h", "arc.m", "manual.mm"] { try write(file, root: root) }
        let files = try nativeGlob("*", root: root)
        let rules = try NativeFileRules(["private_header_files": "private.h", "project_header_files": "project.h", "requires_arc": ["arc.m"]], root: root, files: files)
        XCTAssertEqual(rules.publicHeaders.map(\.lastPathComponent), ["public.h"])
        XCTAssertEqual(rules.headerSettings(root.appendingPathComponent("private.h"))["ATTRIBUTES"] as? [String], ["Private"])
        XCTAssertTrue(rules.headerSettings(root.appendingPathComponent("project.h")).isEmpty)
        XCTAssertEqual(rules.sourceSettings(root.appendingPathComponent("arc.m"))["COMPILER_FLAGS"] as? String, "-fobjc-arc")
        XCTAssertEqual(rules.sourceSettings(root.appendingPathComponent("manual.mm"))["COMPILER_FLAGS"] as? String, "-fno-objc-arc")
    }
    func testCustomConfigurationsAndSchemeActions() throws {
        let root = try directory()
        let spec = try NativeSpec(data: ["name": "Kit", "version": "1.0", "testspecs": [["name": "Tests", "scheme": ["build_configurations": ["Test": "Staging", "Archive": "Release"]]]]], directory: root)
        let requests = try ["Kit", "Kit/Tests"].map { try NativeDependency(["name": $0], platform: "osx", deployment: "14.0") }
        let manifest: [String: Any] = ["targets": [["name": "Demo", "platform": ["name": "osx", "deployment_target": "14.0"], "configurations": ["Staging": "debug"], "dependencies": requests.map { ["name": $0.name] }]]]
        let engine = try NativeXcode(project: root, manifest: manifest, resolution: NativeResolution(specs: ["Kit": spec], requests: requests), integrateUserProjects: false)
        try engine.generate()
        let configurations = engine.graph.objects.values.filter { $0["isa"] as? String == "XCBuildConfiguration" && $0["name"] as? String == "Staging" }
        XCTAssertFalse(configurations.isEmpty)
        XCTAssertTrue(configurations.allSatisfy { ($0["buildSettings"] as? [String: Any])?["ENABLE_TESTABILITY"] as? String == "YES" })
        let scheme = try String(contentsOf: root.appendingPathComponent("Pods/Pods.xcodeproj/xcshareddata/xcschemes/Kit-Unit-Tests.xcscheme"), encoding: .utf8)
        XCTAssertTrue(scheme.contains("TestAction buildConfiguration=\"Staging\""))
    }
    func testMultiplePlatformsKeepProductsAndDependenciesSeparate() throws {
        let root = try directory()
        let spec = try NativeSpec(data: ["name": "Kit", "version": "1.0", "platforms": ["osx": "13.0", "ios": "15.0"]], directory: root)
        let requests = try ["osx", "ios"].map { try NativeDependency(["name": "Kit"], platform: $0, deployment: $0 == "osx" ? "13.0" : "15.0") }
        let manifest: [String: Any] = ["targets": requests.map { ["name": $0.platform, "platform": ["name": $0.platform, "deployment_target": $0.deployment], "dependencies": [["name": "Kit"]]] }]
        let engine = try NativeXcode(project: root, manifest: manifest, resolution: NativeResolution(specs: ["Kit": spec], requests: requests), integrateUserProjects: false)
        try engine.generate()
        XCTAssertEqual(Set(engine.libraryTargets.keys), ["Kit:ios", "Kit:osx"])
        XCTAssertEqual(Set(engine.products.compactMap { engine.productPlatforms[$0] }), ["ios", "osx"])
        XCTAssertNotEqual(engine.libraryTargets["Kit:ios"], engine.libraryTargets["Kit:osx"])
    }
    func testHookGraphRejectsDanglingReferencesAndPersistsChanges() throws {
        let root = try directory()
        let spec = try NativeSpec(data: ["name": "Kit", "version": "1.0"], directory: root)
        let request = try NativeDependency(["name": "Kit"], platform: "osx", deployment: "13.0")
        let engine = try NativeXcode(project: root, manifest: ["targets": [["name": "Demo", "platform": ["name": "osx", "deployment_target": "13.0"], "dependencies": [["name": "Kit"]]]]], resolution: NativeResolution(specs: ["Kit": spec], requests: [request]), integrateUserProjects: false)
        try engine.generate()
        var description = engine.hookDescription()
        var graph = description["graph"] as! [String: Any]
        var objects = graph["objects"] as! [String: [String: Any]]
        let id = engine.libraryTargets["Kit:osx"]!
        objects[id]?["buildPhases"] = [String(repeating: "A", count: 24)]
        graph["objects"] = objects; description["graph"] = graph
        XCTAssertThrowsError(try engine.applyHook(description))
        description = engine.hookDescription(); graph = description["graph"] as! [String: Any]; objects = graph["objects"] as! [String: [String: Any]]
        objects[id]?["name"] = "Renamed"
        graph["objects"] = objects; description["graph"] = graph
        try engine.applyHook(description)
        XCTAssertEqual(engine.graph.objects[id]?["name"] as? String, "Renamed")
    }

    func testResourceRemovalLeavesValidGraphAndPreservesUserPhase() throws {
        let root = try directory()
        try write("en.lproj/Localizable.strings", root: root)
        let graph = try NativePBX(root.appendingPathComponent("project.pbxproj"))
        let group = graph.add("group", ["isa": "PBXGroup", "children": []])
        let userPhase = graph.add("user-phase", ["isa": "PBXShellScriptBuildPhase", "name": "User script"])
        let target = graph.add("target", ["isa": "PBXNativeTarget", "buildPhases": [userPhase]])
        let project = graph.add("root", ["isa": "PBXProject", "mainGroup": group, "targets": [target]])
        graph.root = ["rootObject": project]
        try NativeResources.apply([root.appendingPathComponent("en.lproj/Localizable.strings")], target: target, graph: graph)
        try NativeResources.apply([], target: target, graph: graph)
        XCTAssertEqual(graph.objects[target]?["buildPhases"] as? [String], [userPhase])
        XCTAssertFalse(graph.objects.values.contains { $0["isa"] as? String == "PBXVariantGroup" || $0["isa"] as? String == "PBXBuildFile" })
        var value = graph.root; value["objects"] = graph.objects
        XCTAssertNoThrow(try NativeHookGraph.parse(["graph": value]))
    }

    func testIntegrationSettingsRestoreOriginalAndRetainUserEdit() throws {
        let original: [String: Any] = ["HEADER_SEARCH_PATHS": ["original"], "CUSTOM": "keep"]
        let installed: [String: Any] = ["HEADER_SEARCH_PATHS": ["original", "pods"], "CUSTOM": "keep", "PODS_ROOT": "Pods"]
        let record = try NativeIntegrationSettings.record(before: original, after: installed)
        XCTAssertEqual(try jsonData(NativeIntegrationSettings.restore(installed, record: record)), try jsonData(original))
        var edited = installed; edited["HEADER_SEARCH_PATHS"] = ["user-edit"]
        let restored = try NativeIntegrationSettings.restore(edited, record: record)
        XCTAssertEqual(restored["HEADER_SEARCH_PATHS"] as? [String], ["user-edit"])
        XCTAssertNil(restored["PODS_ROOT"])
    }

    func testRepositoryRegistryRejectsMismatchedNameBeforeMutation() throws {
        let root = try directory(), registry = NativeRepositories(cache: try directory())
        try FileManager.default.createDirectory(at: registry.root, withIntermediateDirectories: true)
        try jsonData(["name": "../outside", "url": root.path, "kind": "git", "revision": String(repeating: "a", count: 40)]).write(to: registry.root.appendingPathComponent("safe.json"))
        XCTAssertThrowsError(try registry.records())
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testLinkageBelongsToActualConsumersAndGeneratesDistinctVariants() throws {
        let root = try directory()
        let specs = try ["Kit", "Other"].reduce(into: [String: NativeSpec]()) { result, name in result[name] = try NativeSpec(data: ["name": name, "version": "1.0"], directory: root) }
        let requests = try ["Kit", "Other"].map { try NativeDependency(["name": $0], platform: "osx", deployment: "13.0") }
        var targets: [[String: Any]] = [["name": "Library", "platform": ["name": "osx"], "dependencies": [["name": "Kit"]]], ["name": "Framework", "platform": ["name": "osx"], "frameworks": "dynamic", "dependencies": [["name": "Other"]]]]
        let resolution = NativeResolution(specs: specs, requests: requests)
        let engine = try NativeXcode(project: root, manifest: ["targets": targets], resolution: resolution, integrateUserProjects: false)
        try engine.generate()
        let paths = Set(engine.products.compactMap { engine.graph.objects[$0]?["path"] as? String })
        XCTAssertEqual(paths, ["libKit.a", "Other.framework"])
        targets[1]["dependencies"] = [["name": "Kit"]]
        let conflict = try NativeXcode(project: root, manifest: ["targets": targets], resolution: resolution, integrateUserProjects: false)
        try conflict.generate()
        let variants = conflict.variantPlan!.variants.values.filter { $0.root == "Kit" }
        XCTAssertEqual(Set(variants.map(\.mode)), ["library", "dynamic"])
        XCTAssertEqual(Set(variants.map(\.label)).count, 2)
        XCTAssertEqual(conflict.productBuildPaths.count, 2)
    }
}
