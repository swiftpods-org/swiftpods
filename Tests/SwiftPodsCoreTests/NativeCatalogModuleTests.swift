import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeCatalogModuleTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testCatalogLoadsOnlySelectedVersionsAndPrefersJSON() throws {
        let root = try directory()
        let specs = root.appendingPathComponent("specs")
        for version in ["1.0", "2.0"] {
            let path = specs.appendingPathComponent("Kit/" + version)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try Data("{invalid json".utf8).write(to: path.appendingPathComponent("Kit.podspec.json"))
            try Data("raise 'Unselected Ruby must not run'".utf8).write(to: path.appendingPathComponent("Kit.podspec"))
        }
        let selected = specs.appendingPathComponent("Kit/1.0/Kit.podspec.json")
        let content = try jsonData(["name": "Kit", "version": "1.0", "summary": "Selected"])
        try content.write(to: selected)
        let catalog = try NativeSources(
            project: root, cache: root.appendingPathComponent("cache"), sources: [specs.path], dsl: nil,
            offline: true, refreshRepositories: false, hardened: false)
        let resolver = NativeResolver(candidates: catalog.candidates, materialize: catalog.materialize)
        let pinned = try NativeDependency(["name": "Kit", "requirements": ["= 1.0"]])
        let result = try resolver.resolve([pinned])
        XCTAssertEqual(result.specs["Kit"]?.data["summary"] as? String, "Selected")
        XCTAssertEqual(result.specs["Kit"]?.checksum, NativeLock.sha1(content))
        XCTAssertThrowsError(try resolver.resolve([NativeDependency(["name": "Kit"])]))
    }

    func testCatalogRejectsSelectedIdentityMismatch() throws {
        let root = try directory()
        let specs = root.appendingPathComponent("Kit/1.0")
        try FileManager.default.createDirectory(at: specs, withIntermediateDirectories: true)
        try jsonData(["name": "Kit", "version": "2.0"]).write(to: specs.appendingPathComponent("Kit.podspec.json"))
        let catalog = try NativeSources(
            project: root, cache: root.appendingPathComponent("cache"), sources: [root.path], dsl: nil,
            offline: true, refreshRepositories: false, hardened: false)
        let entry = try XCTUnwrap(catalog.candidates(NativeDependency(["name": "Kit"])).first)
        XCTAssertThrowsError(try catalog.materialize(entry)) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-SOURCE-IDENTITY")
        }
    }

    func testFrameworkModuleConflictsRespectConsumersAndConfigurations() throws {
        let root = try directory()
        let specs = try ["Kit", "Peer"].map {
            try NativeSpec(data: ["name": $0, "version": "1.0", "module_name": "Shared"], directory: root)
        }
        func engine(_ targets: [[String: Any]]) throws -> NativeXcode {
            try NativeXcode(
                project: root, manifest: ["targets": targets],
                resolution: NativeResolution(
                    specs: Dictionary(uniqueKeysWithValues: specs.map { ($0.name, $0) }), requests: []),
                integrateUserProjects: false)
        }
        let base: [String: Any] = [
            "name": "Demo", "platform": ["name": "osx", "deployment_target": "13.0"], "frameworks": "dynamic",
        ]
        let both = [["name": "Kit"], ["name": "Peer"]]
        XCTAssertThrowsError(try engine([base.merging(["dependencies": both]) { _, new in new }])) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCODE-MODULE-CONFLICT")
        }
        let separate = try engine(
            specs.map { spec in
                base.merging(["name": spec.name, "dependencies": [["name": spec.name]]]) { _, new in new }
            })
        XCTAssertTrue(try XCTUnwrap(separate.variantPlan).variants.values.allSatisfy(\.scoped))
        let filtered: [[String: Any]] = [
            ["name": "Kit", "options": ["configurations": ["Debug"]]],
            ["name": "Peer", "options": ["configurations": ["Release"]]],
        ]
        XCTAssertNoThrow(try engine([base.merging(["dependencies": filtered]) { _, new in new }]))
        var libraries = base
        libraries.removeValue(forKey: "frameworks")
        XCTAssertNoThrow(try engine([libraries.merging(["dependencies": both]) { _, new in new }]))
    }

    func testCompilerAndARCFlagsAppendToPodTargetSettings() throws {
        let root = try directory()
        let spec = try NativeSpec(
            data: [
                "name": "Kit", "version": "1.0", "compiler_flags": "-DADDED=1",
                "pod_target_xcconfig": [
                    "OTHER_CFLAGS": "$(inherited) -DKEPT=1", "OTHER_LDFLAGS": "$(inherited) -Wl,-u,_kit_value",
                ],
            ], directory: root)
        let request = try NativeDependency(["name": "Kit"], platform: "osx", deployment: "13.0")
        let engine = try NativeXcode(
            project: root,
            manifest: [
                "set_arc_compatibility_flag": true,
                "targets": [
                    [
                        "name": "Demo", "platform": ["name": "osx", "deployment_target": "13.0"],
                        "dependencies": [["name": "Kit"]],
                    ]
                ],
            ], resolution: NativeResolution(specs: ["Kit": spec], requests: [request]), integrateUserProjects: false)
        try engine.generate()
        let target = try XCTUnwrap(
            engine.graph.objects.values.first {
                $0["name"] as? String == "Kit" && $0["isa"] as? String == "PBXNativeTarget"
            })
        let list = try XCTUnwrap(target["buildConfigurationList"] as? String)
        for config in engine.graph.objects[list]?["buildConfigurations"] as? [String] ?? [] {
            let settings = try NativeBuildSettings.resolved(engine.graph.objects[config] ?? [:], graph: engine.graph)
            let flags = nativeStrings(settings["OTHER_CFLAGS"]).joined(separator: " ")
            XCTAssertTrue(flags.contains("-DKEPT=1") && flags.contains("-DADDED=1"))
            let linker = nativeStrings(settings["OTHER_LDFLAGS"]).joined(separator: " ")
            XCTAssertTrue(linker.contains("-Wl,-u,_kit_value") && linker.contains("-fobjc-arc"))
        }
    }
}
