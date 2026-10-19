import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeProjectPathBoundaryTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func write(_ relative: String, root: URL, contents: String = "original") throws -> URL {
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        return file
    }

    func testInternalUnicodeProjectsAreNotRegisteredTwice() throws {
        let root = try directory()
        let file = try write("\u{301}App.xcodeproj/project.pbxproj", root: root)
        let state = ProjectState(directory: root)
        try state.acquire()
        try state.begin(command: ["install"], profile: "test")
        try state.registerProject(file)
        let journal = try readObject(root.appendingPathComponent(".swiftpods/state.json"))
        let paths = (journal["journal"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        XCTAssertEqual(paths.filter { $0.hasSuffix("project.pbxproj") }, ["\u{301}App.xcodeproj/project.pbxproj"])
        XCTAssertTrue(nativeStrings(journal["external_paths"]).isEmpty)
    }

    func testHiddenUnicodeDirectoriesAreNotAddedToTheJournal() throws {
        let root = try directory()
        _ = try write(".\u{301}Hidden/App.xcodeproj/project.pbxproj", root: root)
        let state = ProjectState(directory: root)
        try state.acquire()
        try state.begin(command: ["install"], profile: "test")
        let journal = try readObject(root.appendingPathComponent(".swiftpods/state.json"))
        let paths = (journal["journal"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        XCTAssertFalse(paths.contains { $0.hasSuffix("project.pbxproj") })
    }

    func testRecoveryRestoresManagedUnicodeProjectPaths() throws {
        let root = try directory()
        let file = try write("\u{301}App.xcodeproj/project.pbxproj", root: root)
        var state: ProjectState? = ProjectState(directory: root)
        try state?.acquire()
        try state?.begin(command: ["install"], profile: "test")
        try Data("changed".utf8).write(to: file)
        try state?.finish(
            result: HostResult(status: 1, events: [["kind": "managed_write", "path": file.path]]),
            command: ["install"], profile: "test")
        state = nil
        let recovered = try ProjectState(directory: root).recover()
        XCTAssertEqual(recovered["status"] as? String, "recovered")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
    }

    func testRecoveryPreservesAnExternalEditToAUnicodeProject() throws {
        let root = try directory()
        let file = try write("\u{301}App.xcodeproj/project.pbxproj", root: root)
        var state: ProjectState? = ProjectState(directory: root)
        try state?.acquire()
        try state?.begin(command: ["install"], profile: "test")
        try Data("managed".utf8).write(to: file)
        try state?.finish(
            result: HostResult(status: 1, events: [["kind": "managed_write", "path": file.path]]),
            command: ["install"], profile: "test")
        state = nil
        try Data("external".utf8).write(to: file)
        XCTAssertThrowsError(try ProjectState(directory: root).recover()) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-RECOVER-CONFLICT")
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "external")
    }

    func testInventoryAcceptsUnicodeProjectDirectories() throws {
        let root = try directory()
        let file = try write("\u{301}Kit.xcodeproj/project.pbxproj", root: root)
        XCTAssertEqual(try NativeProjectInventory.path("\u{301}Kit.xcodeproj/project.pbxproj", root: root), file)
    }

    func testInventoryCleansUnicodeProjectsAndPreservesEditedPeers() throws {
        let root = try directory()
        let file = try write("\u{301}Kit.xcodeproj/project.pbxproj", root: root)
        let peer = try write("\u{301}Peer.xcodeproj/project.pbxproj", root: root)
        let receipts = [
            "\u{301}Kit.xcodeproj/project.pbxproj": try FileFingerprint.file(file),
            "\u{301}Peer.xcodeproj/project.pbxproj": try FileFingerprint.file(peer),
        ]
        try Data("external".utf8).write(to: peer)
        try NativeProjectInventory.clean(previous: receipts, current: [], root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        XCTAssertEqual(try String(contentsOf: peer, encoding: .utf8), "external")
    }

    func testInventoryRejectsUnicodeProjectSymlinksOutsidePods() throws {
        let root = try directory()
        let outside = try directory()
        _ = try write("project.pbxproj", root: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("\u{301}Escape.xcodeproj"), withDestinationURL: outside)
        XCTAssertThrowsError(try NativeProjectInventory.path("\u{301}Escape.xcodeproj/project.pbxproj", root: root)) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCODE-INVENTORY")
        }
    }

    func testGeneratedUnicodeProjectInventorySavesRelativePaths() throws {
        let root = try directory()
        let name = "\u{301}Kit"
        let spec = try NativeSpec(data: ["name": name, "version": "1.0"], directory: root)
        let request = try NativeDependency(["name": name], platform: "osx", deployment: "13.0")
        let engine = try NativeXcode(
            project: root,
            manifest: [
                "options": ["generate_multiple_pod_projects": true],
                "targets": [
                    [
                        "name": "Demo", "platform": ["name": "osx", "deployment_target": "13.0"],
                        "dependencies": [["name": name]],
                    ]
                ],
            ], resolution: NativeResolution(specs: [name: spec], requests: [request]), integrateUserProjects: false)
        try engine.generate()
        try engine.prepareMultipleProjects()
        _ = try engine.savePods()
        try engine.saveProjectInventory()
        let inventory = try readObject(engine.projectInventoryURL)
        let files = inventory["files"] as? [String: String] ?? [:]
        XCTAssertNotNil(files[name + ".xcodeproj/project.pbxproj"])
    }

    func testMissingGeneratedUnicodeXcconfigsRemainDeferred() throws {
        let root = try directory()
        let missing = root.appendingPathComponent("\u{301}Kit/debug.xcconfig")
        var inputs = Set<String>()
        XCTAssertTrue(
            try NativeBuildSettings.xcconfig(missing, missingGeneratedRoot: root, inputs: &inputs).isEmpty)
        XCTAssertTrue(inputs.isEmpty)
    }

    func testMissingXcconfigsOutsideGeneratedRootAreNotDeferred() throws {
        let root = try directory()
        var inputs = Set<String>()
        XCTAssertThrowsError(
            try NativeBuildSettings.xcconfig(
                root.appendingPathComponent("\u{301}Peer/debug.xcconfig"),
                missingGeneratedRoot: root.appendingPathComponent("\u{301}Generated"), inputs: &inputs))
    }

    private func consumer(_ root: URL) throws -> [String: Any] {
        let graph = try NativePBX(root.appendingPathComponent("\u{301}App.xcodeproj/project.pbxproj"))
        let config = graph.add(
            "config",
            [
                "isa": "XCBuildConfiguration", "name": "Debug",
                "buildSettings": ["SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "13.0"],
            ])
        let list = graph.add("config-list", ["isa": "XCConfigurationList", "buildConfigurations": [config]])
        let target = graph.add("target", ["isa": "PBXNativeTarget", "name": "Demo", "buildConfigurationList": list])
        let group = graph.add("group", ["isa": "PBXGroup", "children": [], "sourceTree": "<group>"])
        let project = graph.add(
            "root", ["isa": "PBXProject", "mainGroup": group, "targets": [target], "buildConfigurationList": list])
        graph.root = ["rootObject": project]
        try graph.save()
        return [
            "project": "\u{301}App.xcodeproj",
            "targets": [["name": "Demo", "platform": ["name": "osx", "deployment_target": "13.0"]]],
        ]
    }

    func testManifestRetainsRelativeUnicodeProjectPaths() throws {
        let root = try directory()
        let analyzed = try NativeManifest.analyze(consumer(root), project: root, integrate: true)
        XCTAssertEqual((analyzed["targets"] as? [[String: Any]])?.first?["project"] as? String, "\u{301}App.xcodeproj")
    }

    func testWorkspaceKeepsUnicodeProjectReferencesRelative() throws {
        let root = try directory()
        let manifest = try consumer(root)
        let engine = try NativeXcode(
            project: root, manifest: manifest, resolution: NativeResolution(specs: [:], requests: []))
        let updates = try engine.prepareWorkspaces()
        for update in updates { try update.save() }
        let path = try XCTUnwrap(engine.workspacePath())
        let text = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(text.contains("group:./\u{301}App.xcodeproj"))
        XCTAssertFalse(text.contains("absolute:"))
    }

    func testLegacyChecksumsKeepDeploymentCompatibleWithoutUnlockingDynamicInputs() throws {
        let root = URL(fileURLWithPath: "/new/work", isDirectory: true)
        let old = "/old/work"
        let name = "\u{301}App.xcodeproj"
        let target: [String: Any] = [
            "name": "Demo", "project": name, "dependencies": [["name": "Kit", "requirements": ["1.0"]]],
        ]
        let contract: [String: Any] = ["targets": [target]]
        var legacyTarget = target
        legacyTarget["project"] = old + "/" + name
        let checksum = digest(try jsonData(["targets": [legacyTarget]]))
        let ownership: [String: Any] = ["_project_root": old]
        XCTAssertTrue(
            try NativeManifest.legacyProjectChecksums(contract, project: root, ownership: ownership).contains(checksum))
        var changed = target
        changed["dependencies"] = [["name": "Kit", "requirements": ["2.0"]]]
        XCTAssertFalse(
            try NativeManifest.legacyProjectChecksums(["targets": [changed]], project: root, ownership: ownership)
                .contains(checksum))
        changed = target
        changed["project"] = "Ordinary.xcodeproj"
        XCTAssertTrue(
            try NativeManifest.legacyProjectChecksums(["targets": [changed]], project: root, ownership: ownership)
                .isEmpty)
    }
}
