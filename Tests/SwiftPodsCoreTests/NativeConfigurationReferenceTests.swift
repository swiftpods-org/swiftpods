import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeConfigurationReferenceTests: XCTestCase {
    private struct Fixture {
        let graph: NativePBX
        let project: String
        let target: String
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let graph = try NativePBX(root.appendingPathComponent("Project.xcodeproj/project.pbxproj"))
        let project = graph.add(
            "project-config", ["isa": "XCBuildConfiguration", "name": "Debug", "buildSettings": [:]])
        let target = graph.add(
            "target-config", ["isa": "XCBuildConfiguration", "name": "Debug", "buildSettings": ["SDKROOT": "macosx"]])
        let projectList = graph.add(
            "project-configs", ["isa": "XCConfigurationList", "buildConfigurations": [project]])
        let targetList = graph.add("target-configs", ["isa": "XCConfigurationList", "buildConfigurations": [target]])
        let native = graph.add(
            "target", ["isa": "PBXNativeTarget", "name": "Consumer", "buildConfigurationList": targetList])
        let group = graph.add("main", ["isa": "PBXGroup", "children": []])
        let id = graph.add(
            "project",
            ["isa": "PBXProject", "targets": [native], "mainGroup": group, "buildConfigurationList": projectList])
        graph.root = ["rootObject": id, "objectVersion": "56"]
        try write("Configs/Base.xcconfig", "VALUE = selected\n", graph: graph)
        try write("Other/Base.xcconfig", "VALUE = wrong\n", graph: graph)
        return Fixture(graph: graph, project: project, target: target)
    }

    private func write(_ path: String, _ contents: String, graph: NativePBX) throws {
        let file = graph.sourceRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
    }

    private func settings(_ values: [String: Any], configuration: String, fixture: Fixture) {
        fixture.graph.objects[configuration]?["buildSettings"] = values
    }

    @discardableResult
    private func attach(_ path: String, configuration: String, fixture: Fixture, tree: String = "<absolute>") -> String
    {
        let file = fixture.graph.add(UUID().uuidString, ["isa": "PBXFileReference", "path": path, "sourceTree": tree])
        fixture.graph.objects[configuration]?["baseConfigurationReference"] = file
        return file
    }

    private func resolve(_ fixture: Fixture, sdkContext: NativeSDKContext = NativeSDKContext()) throws -> [String: Any]
    {
        try NativeBuildSettings.resolved(
            fixture.graph.objects[fixture.target]!, inheriting: fixture.graph.objects[fixture.project]!,
            graph: fixture.graph, sdkContext: sdkContext, targetName: "Consumer")
    }

    func testProjectBuildSettingsLocateTheTargetsBaseConfiguration() throws {
        let f = try fixture()
        settings(["CONFIG_FOLDER": "$(PROJECT_DIR)/Configs"], configuration: f.project, fixture: f)
        attach("$(CONFIG_FOLDER)/Base.xcconfig", configuration: f.target, fixture: f)
        XCTAssertEqual(try resolve(f)["VALUE"] as? String, "selected")
    }

    func testProjectConfigurationFileCanDefineTheReferenceVariable() throws {
        let f = try fixture()
        try write("Project.xcconfig", "CONFIG_FOLDER = $(PROJECT_DIR)/Configs\n", graph: f.graph)
        attach("Project.xcconfig", configuration: f.project, fixture: f, tree: "SOURCE_ROOT")
        attach("${CONFIG_FOLDER}/Base.xcconfig", configuration: f.target, fixture: f)
        XCTAssertEqual(try resolve(f)["VALUE"] as? String, "selected")
    }

    func testTargetOverrideChangesTheSettingWithoutRelocatingTheReference() throws {
        let f = try fixture()
        settings(["CONFIG_FOLDER": "$(PROJECT_DIR)/Configs"], configuration: f.project, fixture: f)
        let other = f.graph.sourceRoot.appendingPathComponent("Other").path
        settings(["CONFIG_FOLDER": other, "SDKROOT": "macosx"], configuration: f.target, fixture: f)
        attach("$(CONFIG_FOLDER)/Base.xcconfig", configuration: f.target, fixture: f)
        let values = try resolve(f)
        XCTAssertEqual(values["VALUE"] as? String, "selected")
        XCTAssertEqual(values["CONFIG_FOLDER"] as? String, other)
    }

    func testTargetOnlyVariablesCannotLocateTheirOwnBaseFile() throws {
        let f = try fixture()
        settings(["CONFIG_FOLDER": "$(PROJECT_DIR)/Configs", "SDKROOT": "macosx"], configuration: f.target, fixture: f)
        attach("$(CONFIG_FOLDER)/Base.xcconfig", configuration: f.target, fixture: f)
        XCTAssertThrowsError(try resolve(f))
    }

    func testProjectOwnDirectVariablesCannotLocateItsOwnBaseFile() throws {
        let f = try fixture()
        settings(["CONFIG_FOLDER": "$(PROJECT_DIR)/Configs"], configuration: f.project, fixture: f)
        attach("$(CONFIG_FOLDER)/Base.xcconfig", configuration: f.project, fixture: f)
        XCTAssertThrowsError(try resolve(f))
    }

    func testNestedProjectVariablesAlsoResolveAParentGroup() throws {
        let f = try fixture()
        settings(
            ["CONFIG_ANCHOR": "${PROJECT_DIR}", "CONFIG_FOLDER": "$(CONFIG_ANCHOR)/Configs"], configuration: f.project,
            fixture: f)
        let file = attach("Base.xcconfig", configuration: f.target, fixture: f, tree: "<group>")
        _ = f.graph.add(
            "configs", ["isa": "PBXGroup", "path": "${CONFIG_FOLDER}", "sourceTree": "<absolute>", "children": [file]])
        XCTAssertEqual(try resolve(f)["VALUE"] as? String, "selected")
    }

    func testConfigurationConditionsSelectTheProjectReferenceVariable() throws {
        let f = try fixture()
        settings(
            [
                "CONFIG_FOLDER[config=Debug]": "$(PROJECT_DIR)/Configs",
                "CONFIG_FOLDER[config=Release]": "$(PROJECT_DIR)/Other",
            ], configuration: f.project, fixture: f)
        attach("$(CONFIG_FOLDER)/Base.xcconfig", configuration: f.target, fixture: f)
        XCTAssertEqual(try resolve(f)["VALUE"] as? String, "selected")
    }

    func testProjectSourceRootOverrideAffectsMacrosAndNotTheStructuralSourceTree() throws {
        let f = try fixture()
        settings(
            ["SRCROOT": f.graph.sourceRoot.appendingPathComponent("Other").path], configuration: f.project, fixture: f)
        try write("Other/Configs/Base.xcconfig", "VALUE = redirected\n", graph: f.graph)
        attach("${SOURCE_ROOT}/Configs/Base.xcconfig", configuration: f.target, fixture: f)
        XCTAssertEqual(try resolve(f)["VALUE"] as? String, "redirected")
        attach("Configs/Base.xcconfig", configuration: f.target, fixture: f, tree: "SOURCE_ROOT")
        XCTAssertEqual(try resolve(f)["VALUE"] as? String, "selected")
    }

    func testProjectDirectoryOverrideParticipatesInTheReference() throws {
        let f = try fixture()
        settings(
            ["PROJECT_DIR": f.graph.sourceRoot.appendingPathComponent("Other").path], configuration: f.project,
            fixture: f)
        attach("$(PROJECT_DIR)/Base.xcconfig", configuration: f.target, fixture: f)
        XCTAssertEqual(try resolve(f)["VALUE"] as? String, "wrong")
    }

    func testProjectConfigurationOverrideSelectsTheReferencedFilename() throws {
        let f = try fixture()
        try write("Configs/Debug.xcconfig", "VALUE = wrong\n", graph: f.graph)
        try write("Configs/Custom.xcconfig", "VALUE = selected\n", graph: f.graph)
        settings(["CONFIGURATION": "Custom"], configuration: f.project, fixture: f)
        attach("$(PROJECT_DIR)/Configs/$(CONFIGURATION).xcconfig", configuration: f.target, fixture: f)
        let values = try resolve(f)
        XCTAssertEqual(values["VALUE"] as? String, "selected")
        XCTAssertEqual(values["CONFIGURATION"] as? String, "Custom")
    }

    func testTargetDefaultNameOverridesProjectDeclarationsFromEitherLayer() throws {
        let f = try fixture()
        attach("$(PROJECT_DIR)/Configs/$(TARGET_NAME).xcconfig", configuration: f.target, fixture: f)
        try write("Configs/Consumer.xcconfig", "VALUE = selected\n", graph: f.graph)
        try write("Project.xcconfig", "TARGET_NAME = Different\n", graph: f.graph)
        for origin in ["direct", "conditional", "file"] {
            f.graph.objects[f.project]?.removeValue(forKey: "baseConfigurationReference")
            settings(
                origin == "file" ? [:] : [origin == "direct" ? "TARGET_NAME" : "TARGET_NAME[config=*]": "Different"],
                configuration: f.project, fixture: f)
            if origin == "file" {
                attach("Project.xcconfig", configuration: f.project, fixture: f, tree: "SOURCE_ROOT")
            }
            let values = try resolve(f)
            XCTAssertEqual(values["VALUE"] as? String, "selected")
            XCTAssertEqual(values["TARGET_NAME"] as? String, "Consumer")
        }
    }

    func testTargetNameOverrideChangesTheValueAndNotTheReference() throws {
        let f = try fixture()
        settings(["TARGET_NAME": "Different", "SDKROOT": "macosx"], configuration: f.target, fixture: f)
        attach("$(PROJECT_DIR)/Configs/$(TARGET_NAME).xcconfig", configuration: f.target, fixture: f)
        try write("Configs/Consumer.xcconfig", "VALUE = selected\n", graph: f.graph)
        let values = try resolve(f)
        XCTAssertEqual(values["VALUE"] as? String, "selected")
        XCTAssertEqual(values["TARGET_NAME"] as? String, "Different")
    }

    func testProjectReferenceConditionsSeeTheTargetsSDK() throws {
        let f = try fixture()
        settings(
            [
                "SDKROOT": "iphoneos", "CONFIG_FOLDER[sdk=macosx*]": "$(PROJECT_DIR)/Configs",
                "CONFIG_FOLDER[sdk=iphoneos*]": "$(PROJECT_DIR)/Other",
            ], configuration: f.project, fixture: f)
        attach("$(CONFIG_FOLDER)/Base.xcconfig", configuration: f.target, fixture: f)
        XCTAssertEqual(try resolve(f)["VALUE"] as? String, "selected")
    }

    func testNulFromAProjectVariableIsRejectedBeforeURLConstruction() throws {
        let f = try fixture()
        settings(["CONFIG_FOLDER": "Configs\0Ignored"], configuration: f.project, fixture: f)
        attach("$(CONFIG_FOLDER)/Base.xcconfig", configuration: f.target, fixture: f)
        XCTAssertThrowsError(try resolve(f)) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCCONFIG-PATH")
        }
    }

    func testAReferencedProjectVariableCycleHasAnExplicitDiagnostic() throws {
        let f = try fixture()
        settings(["FIRST": "$(SECOND)", "SECOND": "${FIRST}"], configuration: f.project, fixture: f)
        attach("$(FIRST)/Base.xcconfig", configuration: f.target, fixture: f)
        XCTAssertThrowsError(try resolve(f)) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCCONFIG-CYCLE")
        }
    }

    func testUnreferencedVariableCyclesDoNotPreventReadingAConfiguration() throws {
        let f = try fixture()
        settings(["FIRST": "$(SECOND)", "SECOND": "${FIRST}"], configuration: f.project, fixture: f)
        attach("Configs/Base.xcconfig", configuration: f.target, fixture: f, tree: "SOURCE_ROOT")
        XCTAssertEqual(try resolve(f)["VALUE"] as? String, "selected")
    }
}
