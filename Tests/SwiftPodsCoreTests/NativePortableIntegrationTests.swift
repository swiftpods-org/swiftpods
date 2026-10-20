import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativePortableIntegrationTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.resolvingSymlinksInPath()
    }

    private func consumer(_ root: URL, project: String = "Demo.xcodeproj", projectDir: String = "") throws -> NativePBX
    {
        let user = try NativePBX(root.appendingPathComponent(project + "/project.pbxproj"))
        user.objects = [
            "PROJECT": [
                "isa": "PBXProject", "mainGroup": "GROUP", "targets": ["TARGET"], "projectDirPath": projectDir,
            ],
            "GROUP": ["isa": "PBXGroup", "children": [], "sourceTree": "<group>"],
            "TARGET": ["isa": "PBXNativeTarget", "name": "Demo", "buildPhases": [], "buildConfigurationList": "LIST"],
            "LIST": ["isa": "XCConfigurationList", "buildConfigurations": ["CONFIG"]],
            "CONFIG": ["isa": "XCBuildConfiguration", "name": "Debug", "buildSettings": [:]],
        ]
        user.root = ["archiveVersion": "1", "objectVersion": "60", "rootObject": "PROJECT"]
        return user
    }

    private func install(_ root: URL) throws -> NativeXcode {
        let root = try NativeCommandRequest(["install"], project: root).project
        let spec = try NativeSpec(
            data: ["name": "Kit", "version": "1.0", "source_files": "*.c", "resources": "*.txt"], directory: root)
        let dependency: [String: Any] = ["name": "Kit"]
        let request = try NativeDependency(dependency, platform: "osx", deployment: "13.0")
        let engine = try NativeXcode(
            project: root,
            manifest: [
                "project": root.appendingPathComponent("Demo.xcodeproj").path,
                "targets": [["name": "Demo", "platform": ["name": "osx"], "dependencies": [dependency]]],
            ],
            resolution: NativeResolution(specs: ["Kit": spec], requests: [request]))
        try engine.generate()
        try engine.graph.save()
        _ = try engine.integrate()
        return engine
    }

    func testInstallAndReinstallAfterMovingTheWholeCheckoutKeepPortableReferences() throws {
        let parent = try directory()
        let original = parent.appendingPathComponent("Original spaces-$(SDKROOT)-🧩")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try Data("int kit(void) { return 1; }\n".utf8).write(to: original.appendingPathComponent("kit.c"))
        try Data("payload".utf8).write(to: original.appendingPathComponent("payload.txt"))
        let user = try consumer(original)
        try user.save()
        let first = try install(original)
        let file = user.url
        let bytes = try Data(contentsOf: file)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(parent.path))
        _ = try install(original)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let receipt = try readObject(
            original.appendingPathComponent("Pods/Target Support Files/SwiftPods-Integration.json"))
        XCTAssertEqual(receipt["_project_root"] as? String, first.project.resolvingSymlinksInPath().path)
        let recordedRoot = try XCTUnwrap(NativeIntegrationLocation.previousRoot(receipt))
        for path in NativeIntegrationSettings.projectPaths(receipt) {
            XCTAssertNotNil(
                NativePath.relativeComponents(of: URL(fileURLWithPath: path), to: recordedRoot),
                "\(path) / \(recordedRoot.path)")
        }

        let moved = parent.appendingPathComponent("Another checkout")
        try FileManager.default.moveItem(at: original, to: moved)
        let afterMoveRoot = try XCTUnwrap(NativeIntegrationLocation.previousRoot(receipt))
        for path in NativeIntegrationSettings.projectPaths(receipt) {
            XCTAssertNotNil(
                NativePath.relativeComponents(of: URL(fileURLWithPath: path), to: afterMoveRoot),
                "\(path) / \(afterMoveRoot.path)")
        }
        let relocated = try NativePBX(moved.appendingPathComponent("Demo.xcodeproj/project.pbxproj"), existing: true)
        for (id, reference) in relocated.objects where reference["sourceTree"] as? String == "SOURCE_ROOT" {
            let resolved = try NativeBuildSettings.file(id, graph: relocated)
            XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path), resolved.path)
            XCTAssertTrue(NativePath.isDescendant(resolved, of: moved))
        }
        let engine = try install(moved)
        XCTAssertEqual(try Data(contentsOf: relocated.url), bytes)
        for config in engine.userProjects.values.flatMap({ $0.objects.values })
        where config["isa"] as? String == "XCBuildConfiguration" {
            let resolved = try NativeBuildSettings.resolved(config, graph: relocated)
            XCTAssertEqual(
                try NativeBuildSettings.expandedValue("PODS_ROOT", settings: resolved),
                moved.appendingPathComponent("Pods").path)
        }
        _ = try install(moved)
        XCTAssertEqual(try Data(contentsOf: relocated.url), bytes)
        _ = try NativeDeintegrator.run(moved)
        let removed = try NativePBX(relocated.url, existing: true)
        XCTAssertFalse(removed.objects.values.contains { ($0["path"] as? String)?.contains("Pods/") == true })
    }

    func testReferencesAndSettingsRespectExternalProjectsAndCustomSourceRoots() throws {
        let root = try directory()
        for name in ["Root-$(SDKROOT)-🧩", #"Root-\$(SDKROOT)"#, #"Root-\\$Cash"#] {
            let integration = root.appendingPathComponent(name)
            let user = try consumer(root, project: "Apps/Demo.xcodeproj", projectDir: "../Sources")
            let sdk = integration.appendingPathComponent("Pods/Kit.xcframework")
            let reference = user.add("reference", user.relativeFileReference(sdk))
            XCTAssertEqual(try NativeBuildSettings.file(reference, graph: user), sdk)
            XCTAssertFalse((user.objects[reference]?["path"] as? String)?.hasPrefix("/") == true)
            let settings = try NativeBuildSettings.resolvedScopes(
                ["buildSettings": ["PODS_ROOT": user.buildSettingPath(integration.appendingPathComponent("Pods"))]],
                graph: user, targetName: "Demo"
            ).targetScope
            let expanded = try XCTUnwrap(settings.expandedValue("PODS_ROOT"))
            XCTAssertEqual(
                URL(fileURLWithPath: expanded).standardizedFileURL, integration.appendingPathComponent("Pods"))
        }
    }

    func testDeintegrationRecognizesBothLegacyAndPortableVendorReferences() throws {
        let root = try directory()
        let user = try consumer(root)
        let sdk = root.appendingPathComponent("Pods/SDK-$(SDKROOT).framework")
        var references: [String] = []
        for path in [sdk.path, user.relativeFilePath(sdk)] {
            let key = "swiftpods:vendor:" + path
            let reference = user.add(
                key,
                [
                    "isa": "PBXFileReference", "path": path,
                    "sourceTree": path.hasPrefix("/") ? "<absolute>" : "SOURCE_ROOT",
                ])
            let build = user.add(key + ":link", ["isa": "PBXBuildFile", "fileRef": reference])
            references.append(reference)
            user.objects["GROUP"]?["children"] = references
            user.objects["PHASE"] = ["isa": "PBXFrameworksBuildPhase", "files": [build]]
            user.objects["TARGET"]?["buildPhases"] = ["PHASE"]
        }
        try NativeDeintegrator.restore(user, settings: [:], products: [])
        for id in references { XCTAssertNil(user.objects[id]) }
    }
}
