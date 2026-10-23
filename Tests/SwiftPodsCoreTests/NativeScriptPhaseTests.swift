import XCTest

@testable import SwiftPodsCore

final class NativeScriptPhaseTests: XCTestCase {
    func testBuildOptionsPreserveScriptsAndFileLists() throws {
        let phase = try NativeScriptPhase([
            "name": "Generate", "script": "printf '\"hello\"\\n'\n", "shell_path": "/bin/bash",
            "execution_position": "before_compile", "input_files": ["$(PODS_TARGET_SRCROOT)/input"],
            "output_files": ["$(DERIVED_FILE_DIR)/output"],
            "input_file_lists": ["inputs.xcfilelist"], "output_file_lists": ["outputs.xcfilelist"],
            "dependency_file": "$(DERIVED_FILE_DIR)/output.d",
            "always_out_of_date": "1", "show_env_vars_in_log": "0",
        ])
        XCTAssertEqual(phase.object["shellScript"] as? String, "printf '\"hello\"\\n'\n")
        XCTAssertEqual(phase.object["inputFileListPaths"] as? [String], ["inputs.xcfilelist"])
        XCTAssertEqual(phase.object["outputPaths"] as? [String], ["$(DERIVED_FILE_DIR)/output"])
        XCTAssertEqual(phase.object["dependencyFile"] as? String, "$(DERIVED_FILE_DIR)/output.d")
        XCTAssertEqual(phase.object["alwaysOutOfDate"] as? String, "1")
        XCTAssertEqual(phase.object["showEnvVarsInLog"] as? String, "0")
        let defaults = try NativeScriptPhase(["name": "Default", "script": ""])
        XCTAssertEqual(defaults.position, "any")
        XCTAssertEqual(defaults.object["shellPath"] as? String, "/bin/sh")
        XCTAssertNil(defaults.object["alwaysOutOfDate"])
        XCTAssertNil(defaults.object["showEnvVarsInLog"])
    }
    func testMalformedOptionsAreRejected() throws {
        let valid: [String: Any] = ["name": "Generate", "script": "exit 0"]
        for extra: [String: Any] in [
            ["input_files": "file"], ["always_out_of_date": true], ["show_env_vars_in_log": "YES"],
            ["execution_position": "after_link"], ["unknown": 1], ["output_file_lists": ["bad\npath"]],
        ] {
            XCTAssertThrowsError(try NativeScriptPhase(valid.merging(extra) { _, new in new }))
        }
        XCTAssertThrowsError(try NativeScriptPhase(["name": "Missing script"]))
        XCTAssertThrowsError(try NativeScriptPhase.parse(["bad phase"]))
    }
    func testPositionsReinstallationAndRemovalPreserveUserPhases() throws {
        let graph = try NativePBX(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let headers = graph.add("headers", ["isa": "PBXHeadersBuildPhase"])
        let sources = graph.add("sources", ["isa": "PBXSourcesBuildPhase"])
        let custom = graph.add("custom", ["isa": "PBXShellScriptBuildPhase", "name": "User supplied"])
        let target = graph.add("target", ["isa": "PBXNativeTarget", "buildPhases": [headers, sources, custom]])
        let phases = try ["before_headers", "after_headers", "before_compile", "after_compile", "any"].map {
            try NativeScriptPhase(["name": $0, "script": "exit 0", "execution_position": $0])
        }
        NativeScriptPhase.apply(phases, target: target, graph: graph)
        let first = graph.objects[target]?["buildPhases"] as! [String]
        for phase in phases where phase.position != "any" {
            let id = first.first { graph.objects[$0]?["name"] as? String == NativeScriptPhase.prefix + phase.name }!
            let anchor = phase.position.hasSuffix("headers") ? headers : sources
            if phase.position.hasPrefix("before_") {
                XCTAssertLessThan(first.firstIndex(of: id)!, first.firstIndex(of: anchor)!)
            } else {
                XCTAssertGreaterThan(first.firstIndex(of: id)!, first.firstIndex(of: anchor)!)
            }
        }
        NativeScriptPhase.apply(phases, target: target, graph: graph)
        XCTAssertEqual(first, graph.objects[target]?["buildPhases"] as? [String])
        NativeScriptPhase.apply([], target: target, graph: graph)
        XCTAssertEqual(graph.objects[target]?["buildPhases"] as? [String], [headers, sources, custom])
        XCTAssertNotNil(graph.objects[custom])
    }
    func testReorderingPreservesForeignSlotsAndPositionChangesKeepDeclarationOrder() throws {
        let graph = try NativePBX(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let sources = graph.add("sources", ["isa": "PBXSourcesBuildPhase"])
        let foreign = graph.add("foreign", ["isa": "PBXShellScriptBuildPhase", "name": "User check"])
        let target = graph.add("target", ["isa": "PBXNativeTarget", "buildPhases": [sources, foreign]])
        func phases(_ names: [String], position: String) throws -> [NativeScriptPhase] {
            try names.map { try NativeScriptPhase(["name": $0, "script": "true", "execution_position": position]) }
        }
        NativeScriptPhase.apply(try phases(["A", "B"], position: "after_compile"), target: target, graph: graph)
        NativeScriptPhase.apply(try phases(["B", "A"], position: "after_compile"), target: target, graph: graph)
        let order = try XCTUnwrap(graph.objects[target]?["buildPhases"] as? [String])
        XCTAssertEqual(Array(order.prefix(2)), [sources, foreign])
        XCTAssertEqual(
            order.dropFirst(2).compactMap { graph.objects[$0]?["name"] as? String }, ["[CP-User] B", "[CP-User] A"])
        let moved = try phases(["B", "A"], position: "before_compile")
        NativeScriptPhase.apply(moved, target: target, graph: graph)
        let expected = Array(order.dropFirst(2)) + [sources, foreign]
        XCTAssertEqual(graph.objects[target]?["buildPhases"] as? [String], expected)
        NativeScriptPhase.apply(moved, target: target, graph: graph)
        XCTAssertEqual(graph.objects[target]?["buildPhases"] as? [String], expected)
    }

    func testSubspecPhasesAreNotInheritedAndPlatformPhasesAreAdditive() throws {
        let spec = try NativeSpec(data: [
            "name": "Kit", "version": "1.0", "script_phase": ["name": "Root", "script": "exit 0"],
            "osx": ["script_phases": [["name": "Mac", "script": "exit 0"]]],
            "subspecs": [
                ["name": "Child", "script_phases": [["name": "Child", "script": "exit 0"]]], ["name": "Plain"],
            ],
        ])
        XCTAssertEqual(
            try spec.scriptPhases(for: NativeDependency(["name": "Kit"], platform: "osx")).map(\.name), ["Root", "Mac"])
        XCTAssertEqual(
            try spec.scriptPhases(for: NativeDependency(["name": "Kit/Child"], platform: "osx")).map(\.name), ["Child"])
        XCTAssertEqual(try spec.scriptPhases(for: NativeDependency(["name": "Kit/Plain"], platform: "osx")).count, 0)
    }
    func testHardenedPolicyFindsNestedExecutableDeclarations() throws {
        for nested: [String: Any] in [
            ["osx": ["script_phase": ["name": "Run", "script": "true"]]],
            ["subspecs": [["name": "Child", "script_phases": [["name": "Run", "script": "true"]]]]],
            ["prepare_command": "true"],
        ] {
            let spec = try NativeSpec(data: ["name": "Kit", "version": "1.0"].merging(nested) { _, new in new })
            XCTAssertTrue(spec.containsExecutableCommands)
        }
        XCTAssertFalse(
            try NativeSpec(data: ["name": "Kit", "version": "1.0", "script_phases": []]).containsExecutableCommands)
    }
}
