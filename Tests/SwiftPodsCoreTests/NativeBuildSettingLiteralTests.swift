import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeBuildSettingLiteralTests: XCTestCase {
    private func fixture(
        rootName: String = "Project", projectName: String = "External", configuration: String = "Debug"
    ) throws -> (NativePBX, [String: Any]) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = parent.appendingPathComponent(rootName)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let graph = try NativePBX(root.appendingPathComponent(projectName + ".xcodeproj/project.pbxproj"))
        let config: [String: Any] = ["isa": "XCBuildConfiguration", "name": configuration, "buildSettings": [:]]
        return (graph, config)
    }

    private func sdk(_ name: String, graph: NativePBX) throws -> URL {
        let path = graph.sourceRoot.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["CanonicalName": "macosx99.4"])
            .write(to: path.appendingPathComponent("SDKSettings.json"))
        return path
    }

    private func resolve(
        _ config: [String: Any], graph: NativePBX, settings: [String: Any], targetName: String = "Consumer"
    ) throws -> [String: Any] {
        var config = config
        config["buildSettings"] = settings
        return try NativeBuildSettings.resolved(config, graph: graph, targetName: targetName)
    }

    func testUnknownSDKExpressionsResolveAsEmptyWithoutRewritingTheirDeclaration() throws {
        let (graph, config) = try fixture()
        for raw in ["$(MISSING)", "${MISSING}", "macosx$(MISSING)", "$(SDK_CHOICE)"] {
            let values = try resolve(
                config, graph: graph,
                settings: [
                    "SDKROOT": raw, "SDK_CHOICE": "$(MISSING)", "VALUE[sdk=macosx*]": "selected",
                ])
            XCTAssertEqual(values["VALUE"] as? String, "selected", raw)
            XCTAssertEqual(values["SDKROOT"] as? String, raw)
        }
    }

    func testAnUnknownSDKPathStillCannotMatchItsBasename() throws {
        let (graph, config) = try fixture()
        let values = try resolve(
            config, graph: graph,
            settings: [
                "SDKROOT": "$(MISSING)/MacOSX.sdk", "WRONG[sdk=macosx*]": "wrong",
            ])
        XCTAssertNil(values["WRONG"])
    }

    func testLateUnknownSDKExpressionsReevaluateEarlierConditions() throws {
        let (graph, config) = try fixture()
        let path = graph.sourceRoot.appendingPathComponent("Base.xcconfig")
        try Data("VALUE[sdk=macosx*] = selected\nSDKROOT = $(MISSING)\n".utf8).write(to: path)
        let reference = graph.add("config", ["isa": "PBXFileReference", "path": path.path, "sourceTree": "<absolute>"])
        var configuration = config
        configuration["baseConfigurationReference"] = reference
        XCTAssertEqual(try NativeBuildSettings.resolved(configuration, graph: graph)["VALUE"] as? String, "selected")
    }

    func testLiteralMacroTextInASourceRootDoesNotChangeTheDefaultAlias() throws {
        let (graph, config) = try fixture(rootName: "Root-$(SDKROOT)")
        let values = try resolve(config, graph: graph, settings: ["SDKROOT": "macosx"])
        XCTAssertEqual(values["SRCROOT"] as? String, graph.sourceRoot.path)
        XCTAssertEqual(values["SOURCE_ROOT"] as? String, graph.sourceRoot.path)
    }

    func testLiteralMacroTextInSourceRootsCannotCreateAnSDKCycle() throws {
        for name in ["Root-$(SDKROOT)", "Root-${MISSING}", "Root-$(inherited)"] {
            let (graph, config) = try fixture(rootName: name)
            _ = try sdk("SelectedSDK.sdk", graph: graph)
            let values = try resolve(
                config, graph: graph,
                settings: [
                    "SDKROOT": "$(SRCROOT)/SelectedSDK.sdk", "VALUE[sdk=macosx99.*]": "selected",
                ])
            XCTAssertEqual(values["VALUE"] as? String, "selected", name)
            XCTAssertEqual(values["SOURCE_ROOT"] as? String, graph.sourceRoot.path)
        }
    }

    func testLiteralProjectNameIsNotParsedAsAnExpression() throws {
        let (graph, config) = try fixture(projectName: "External-$(CONFIGURATION)")
        _ = try sdk("External-$(CONFIGURATION).sdk", graph: graph)
        let values = try resolve(
            config, graph: graph,
            settings: [
                "SDKROOT": "$(PROJECT_DIR)/$(PROJECT_NAME).sdk", "VALUE[sdk=macosx99.*]": "selected",
            ])
        XCTAssertEqual(values["VALUE"] as? String, "selected")
    }

    func testLiteralConfigurationAndTargetNamesAreNotParsedAgain() throws {
        let (graph, config) = try fixture(configuration: "Debug$(SDKROOT)")
        _ = try sdk("Debug$(SDKROOT).sdk", graph: graph)
        _ = try sdk("Consumer$(SDKROOT).sdk", graph: graph)
        for variable in ["CONFIGURATION", "TARGET_NAME"] {
            let values = try resolve(
                config, graph: graph,
                settings: [
                    "SDKROOT": "$(PROJECT_DIR)/$(\(variable)).sdk", "VALUE[sdk=macosx99.*]": "selected",
                ], targetName: "Consumer$(SDKROOT)")
            XCTAssertEqual(values["VALUE"] as? String, "selected", variable)
        }
    }

    func testExplicitBuiltinOverridesRemainExpressions() throws {
        let (graph, config) = try fixture(rootName: "Original")
        let custom = graph.sourceRoot.appendingPathComponent("Override")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        let values = try resolve(
            config, graph: graph,
            settings: [
                "SOURCE_CHOICE": custom.path, "SRCROOT": "$(SOURCE_CHOICE)", "SDKROOT": "macosx",
            ])
        XCTAssertEqual(values["SOURCE_ROOT"] as? String, custom.path)
        XCTAssertEqual(values["SRCROOT"] as? String, "$(SOURCE_CHOICE)")
    }

    func testConfigurationReferenceExpansionDoesNotReparseLiteralBuiltins() throws {
        let (graph, _) = try fixture(rootName: "Root-$(SDKROOT)")
        let reference = graph.add(
            "ref", ["isa": "PBXFileReference", "path": "$(PROJECT_DIR)/Base.xcconfig", "sourceTree": "<absolute>"])
        XCTAssertEqual(
            try NativeBuildSettings.file(reference, graph: graph).path,
            graph.sourceRoot.appendingPathComponent("Base.xcconfig").path)
    }

    func testProjectVariablesSupportModifiersInBaseFileReferences() throws {
        let (graph, config) = try fixture()
        let folder = graph.sourceRoot.appendingPathComponent("Configs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("VALUE = selected\n".utf8).write(to: folder.appendingPathComponent("base.xcconfig"))
        let ref = graph.add(
            "ref",
            [
                "isa": "PBXFileReference", "path": "$(FOLDER:standardizepath)/$(FILENAME:lower).xcconfig",
                "sourceTree": "<absolute>",
            ])
        var target = config
        target["baseConfigurationReference"] = ref
        var project = config
        project["buildSettings"] = ["FOLDER": "$(PROJECT_DIR)/Configs/../Configs", "FILENAME": "BASE"]
        XCTAssertEqual(
            try NativeBuildSettings.resolved(target, inheriting: project, graph: graph)["VALUE"] as? String, "selected")
    }

    func testSDKSelectionSupportsChainedModifiers() throws {
        let (graph, config) = try fixture()
        _ = try sdk("SelectedSDK.sdk", graph: graph)
        let values = try resolve(
            config, graph: graph,
            settings: [
                "SDK_CHOICE": "MACOSX", "SDKROOT": "$(SDK_CHOICE:lower)", "VALUE[sdk=macosx*]": "selected",
            ])
        XCTAssertEqual(values["VALUE"] as? String, "selected")
        let pathValues = try resolve(
            config, graph: graph,
            settings: [
                "SDK_FOLDER": "$(SRCROOT)/Configs/../SelectedSDK.sdk", "SDKROOT": "$(SDK_FOLDER:standardizepath)",
                "VALUE[sdk=macosx99.*]": "selected",
            ])
        XCTAssertEqual(pathValues["VALUE"] as? String, "selected")
    }
    private func inferredPlatform(_ sdk: String) throws -> [String: Any] {
        let (graph, _) = try fixture()
        let config = graph.add(
            "config",
            [
                "isa": "XCBuildConfiguration", "name": "Debug",
                "buildSettings": ["SDKROOT": sdk, "MACOSX_DEPLOYMENT_TARGET": "13.0"],
            ])
        let list = graph.add("configs", ["isa": "XCConfigurationList", "buildConfigurations": [config]])
        let target = graph.add(
            "target", ["isa": "PBXNativeTarget", "name": "Consumer", "buildConfigurationList": list])
        let root = graph.add("project", ["isa": "PBXProject", "targets": [target], "projectDirPath": ""])
        graph.root = ["archiveVersion": "1", "objectVersion": "56", "rootObject": root]
        try graph.save()
        return try NativeManifest.analyze(
            ["project": "External.xcodeproj", "targets": [["name": "Consumer"]]], project: graph.sourceRoot,
            integrate: true)
    }

    func testEntirelyUnknownSDKExpressionsUseTheDefaultPlatform() throws {
        for raw in ["$(MISSING)", "${MISSING}", "macosx$(MISSING)"] {
            XCTAssertNoThrow(try inferredPlatform(raw), raw)
        }
    }

    func testUnknownSDKDirectoriesCannotInferPlatformFromAnUnavailableBasename() throws {
        for raw in ["$(MISSING)/MacOSX.sdk", "${MISSING}/MacOSX.sdk", "$(MISSING:lower)/MacOSX.sdk"] {
            XCTAssertThrowsError(try inferredPlatform(raw), raw) { error in
                XCTAssertEqual((error as? Diagnostic)?.code, "SP-PLATFORM-MISSING")
            }
        }
    }

}
