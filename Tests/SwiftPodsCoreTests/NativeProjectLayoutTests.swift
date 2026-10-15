import XCTest
@testable import SwiftPodsCore

final class NativeProjectLayoutTests: XCTestCase {
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }
    private func engine(count: Int = 3) throws -> NativeXcode {
        let root = try directory()
        var specs: [String: NativeSpec] = [:], requests: [NativeDependency] = []
        for index in 0..<count {
            let name = "Kit" + String(index), path = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try Data("int value_\(index)(void) { return \(index); }\n".utf8).write(to: path.appendingPathComponent(name + ".m"))
            var data: [String: Any] = ["name": name, "version": "1.0", "source_files": "*.m"]
            if index == 0 { data["dependencies"] = ["Kit1": [">= 0"]] }
            specs[name] = try NativeSpec(data: data, directory: path)
            requests.append(try NativeDependency(["name": name], platform: "osx", deployment: "13.0"))
        }
        let manifest: [String: Any] = ["options": ["generate_multiple_pod_projects": true], "targets": [["name": "Demo", "platform": ["name": "osx", "deployment_target": "13.0"], "dependencies": requests.map { ["name": $0.name] }]]]
        let engine = try NativeXcode(project: root, manifest: manifest, resolution: NativeResolution(specs: specs, requests: requests), integrateUserProjects: false)
        try engine.generate(); try engine.prepareMultipleProjects()
        return engine
    }
    func testProjectsContainOnlyReachableObjectsAndExternalDependencies() throws {
        let engine = try engine(count: 12)
        let graphs = [engine.podsProject] + engine.generatedProjects.values
        XCTAssertLessThan(graphs.reduce(0) { $0 + $1.objects.count }, 3 * engine.graph.objects.count)
        for graph in graphs {
            let root = graph.root["rootObject"] as! String
            let targets = Set(graph.objects[root]?["targets"] as! [String])
            let contained = Set(graph.objects.filter { ["PBXNativeTarget", "PBXAggregateTarget"].contains($0.value["isa"] as? String ?? "") }.keys)
            XCTAssertEqual(targets, contained)
            XCTAssertEqual(NativeProjectProjection.reachable(graph.objects, from: [root]), Set(graph.objects.keys))
            var value = graph.root; value["objects"] = graph.objects
            XCTAssertNoThrow(try NativeHookGraph.parse(["graph": value]))
        }
        let child = engine.generatedProjects[engine.projectForPod("Kit0").path]!
        XCTAssertNil(child.objects[engine.libraryTargets["Kit1:osx"]!])
        XCTAssertTrue(child.objects.values.contains { $0["remoteGlobalIDString"] as? String == engine.libraryTargets["Kit1:osx"] })
        XCTAssertFalse(child.objects.values.contains { ($0["path"] as? String)?.hasSuffix("/Kit1.m") == true })
        XCTAssertNotEqual(child.root["rootObject"] as? String, engine.podsProject.root["rootObject"] as? String)
    }
    func testChildRootChangesAndObjectIdentitySurviveSavingOtherProjects() throws {
        let engine = try engine()
        let child = engine.generatedProjects[engine.projectForPod("Kit0").path]!
        let id = child.root["rootObject"] as! String
        child.objects[id]?["attributes"] = ["ChildMarker": "preserved"]
        let list = child.objects[id]?["buildConfigurationList"] as! String
        let configuration = (child.objects[list]?["buildConfigurations"] as! [String])[0]
        child.objects[configuration]?["buildSettings"] = ["CHILD_ONLY": "preserved"]
        _ = try engine.savePods(); _ = try engine.savePods()
        XCTAssertTrue(engine.generatedProjects[engine.projectForPod("Kit0").path] === child)
        let saved = try NativePBX(child.url, existing: true)
        XCTAssertEqual((saved.objects[id]?["attributes"] as? [String: String])?["ChildMarker"], "preserved")
        XCTAssertEqual((saved.objects[configuration]?["buildSettings"] as? [String: String])?["CHILD_ONLY"], "preserved")
        XCTAssertFalse(engine.podsProject.objects.values.contains { ($0["buildSettings"] as? [String: Any])?["CHILD_ONLY"] != nil })
    }
    func testInventoryCleanupPreservesChangedAndUnownedFiles() throws {
        let root = try directory()
        var receipts: [String: String] = [:]
        for name in ["Old", "Edited", "Unowned"] {
            let file = root.appendingPathComponent(name + ".xcodeproj/project.pbxproj")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(name.utf8).write(to: file)
            if name != "Unowned" { receipts[name + ".xcodeproj/project.pbxproj"] = try FileFingerprint.file(file) }
        }
        try Data("user edit".utf8).write(to: root.appendingPathComponent("Edited.xcodeproj/project.pbxproj"))
        try NativeProjectInventory.clean(previous: receipts, current: [], root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Old.xcodeproj").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Edited.xcodeproj/project.pbxproj").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Unowned.xcodeproj/project.pbxproj").path))
        XCTAssertThrowsError(try NativeProjectInventory.path("../User.xcodeproj/project.pbxproj", root: root))
    }
    func testUserProjectChangesCannotChangeGeneratedObjectsWithSameUUIDs() throws {
        let engine = try engine()
        let user = try NativePBX(engine.project.appendingPathComponent("User.xcodeproj/project.pbxproj"))
        user.root = engine.graph.root; user.objects = engine.graph.objects
        engine.userProjects[user.url.path] = user
        let before = try jsonData(engine.graph.objects)
        let target = engine.libraryTargets["Kit0:osx"]!
        var changed = user.objects; changed[target]?["name"] = "UserTarget"
        var root = user.root; root["objects"] = changed
        try engine.applyHookGraph(["graph": root], to: user)
        XCTAssertEqual(user.objects[target]?["name"] as? String, "UserTarget")
        XCTAssertEqual(try jsonData(engine.graph.objects), before)
    }
    func testHardenedProjectOptionsRejectCommandsAndNumericBooleans() throws {
        let path = try directory().appendingPathComponent("Podfile.json")
        var manifest: [String: Any] = ["schema_version": 1, "platform": ["name": "osx", "deployment_target": "13.0"], "project": "Demo.xcodeproj", "targets": [["name": "Demo", "pods": []]], "options": ["generate_multiple_pod_projects": true]]
        try jsonData(manifest).write(to: path)
        XCTAssertNoThrow(try ExecutionPolicy.hardenedManifest(path))
        for options in [["generate_multiple_pod_projects": 1] as [String: Any], ["post_install": "execute"]] {
            manifest["options"] = options; try jsonData(manifest).write(to: path)
            XCTAssertThrowsError(try ExecutionPolicy.hardenedManifest(path))
        }
    }
}
