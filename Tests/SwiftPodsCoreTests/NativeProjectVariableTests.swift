import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeProjectVariableTests: XCTestCase {
    private func fixture(redirected: Bool = false) throws -> (NativePBX, String, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let graph = try NativePBX(root.appendingPathComponent("Apps/External.xcodeproj/project.pbxproj"))
        let projectConfig = graph.add("base", ["isa": "XCBuildConfiguration", "name": "Debug", "buildSettings": [:]])
        let targetConfig = graph.add(
            "config",
            [
                "isa": "XCBuildConfiguration", "name": "Debug",
                "buildSettings": ["SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "13.0"],
            ])
        let pList = graph.add("base-list", ["isa": "XCConfigurationList", "buildConfigurations": [projectConfig]])
        let tList = graph.add("config-list", ["isa": "XCConfigurationList", "buildConfigurations": [targetConfig]])
        let target = graph.add(
            "target", ["isa": "PBXNativeTarget", "name": "Consumer", "buildConfigurationList": tList])
        let group = graph.add("group", ["isa": "PBXGroup", "children": []])
        let project = graph.add(
            "project",
            [
                "isa": "PBXProject", "mainGroup": group, "targets": [target], "buildConfigurationList": pList,
                "projectDirPath": redirected ? "../Shared" : "",
            ])
        graph.root = ["archiveVersion": "1", "objectVersion": "56", "rootObject": project]
        try FileManager.default.createDirectory(at: graph.sourceRoot, withIntermediateDirectories: true)
        try graph.save()
        return (graph, targetConfig, target)
    }

    private func sdk(_ root: URL, name: String = "SelectedSDK.sdk", canonical: String = "macosx99.4") throws -> URL {
        let path = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["CanonicalName": canonical])
            .write(to: path.appendingPathComponent("SDKSettings.json"))
        return path
    }

    private func direct(_ graph: NativePBX, _ config: String, settings: [String: Any] = [:]) throws -> [String: Any] {
        var value = graph.objects[config]!
        value["buildSettings"] = settings
        return try NativeBuildSettings.resolved(value, graph: graph)
    }

    private func response(_ graph: NativePBX, target: String, key: String) throws -> [String: Any] {
        var root = graph.root
        root["objects"] = graph.objects
        return try XCTUnwrap(
            try NativeBuildSettings.response([
                "value": [
                    "path": graph.url.deletingLastPathComponent().path, "target": target, "key": key, "graph": root,
                    "xcconfig": true,
                ]
            ])["result"] as? [String: Any])
    }

    func testProjectRootAliasesHaveNativeDefaults() throws {
        let (graph, config, _) = try fixture()
        let values = try direct(graph, config)
        for key in ["SRCROOT", "SOURCE_ROOT", "PROJECT_DIR"] {
            XCTAssertEqual(values[key] as? String, graph.sourceRoot.path, key)
        }
    }

    func testProjectNameAndFilePathReferToTheSelectedProject() throws {
        let (graph, config, _) = try fixture()
        let values = try direct(graph, config)
        XCTAssertEqual(values["PROJECT_NAME"] as? String, "External")
        XCTAssertEqual(values["PROJECT_FILE_PATH"] as? String, graph.url.deletingLastPathComponent().path)
    }

    func testConfigurationDefaultFollowsEachConfiguration() throws {
        let (graph, config, _) = try fixture()
        for name in ["Debug", "Release", "Special"] {
            var value = graph.objects[config]!
            value["name"] = name
            XCTAssertEqual(try NativeBuildSettings.resolved(value, graph: graph)["CONFIGURATION"] as? String, name)
        }
    }

    func testParenthesizedRootVariablesSelectTheSDKWithoutRewritingSDKROOT() throws {
        let (graph, config, _) = try fixture()
        _ = try sdk(graph.sourceRoot)
        for variable in ["SRCROOT", "SOURCE_ROOT", "PROJECT_DIR"] {
            let raw = "$(\(variable))/SelectedSDK.sdk"
            let values = try direct(graph, config, settings: ["SDKROOT": raw, "VALUE[sdk=macosx99.*]": "selected"])
            XCTAssertEqual(values["VALUE"] as? String, "selected", variable)
            XCTAssertEqual(values["SDKROOT"] as? String, raw)
        }
    }

    func testBracedRootVariablesSelectTheSDK() throws {
        let (graph, config, _) = try fixture()
        _ = try sdk(graph.sourceRoot)
        for variable in ["SRCROOT", "SOURCE_ROOT", "PROJECT_DIR"] {
            let values = try direct(
                graph, config,
                settings: [
                    "SDKROOT": "${\(variable)}/SelectedSDK.sdk", "VALUE[sdk=macosx99.*]": "selected",
                ])
            XCTAssertEqual(values["VALUE"] as? String, "selected", variable)
        }
    }

    func testProjectNameCanParticipateInTheSDKPath() throws {
        let (graph, config, _) = try fixture()
        _ = try sdk(graph.sourceRoot, name: "External.sdk")
        let values = try direct(
            graph, config,
            settings: [
                "SDKROOT": "$(PROJECT_DIR)/$(PROJECT_NAME).sdk", "VALUE[sdk=macosx99.*]": "selected",
            ])
        XCTAssertEqual(values["VALUE"] as? String, "selected")
    }

    func testProjectFilePathRemainsTheContainerWhenSourceRootIsRedirected() throws {
        let (graph, config, _) = try fixture(redirected: true)
        let values = try direct(graph, config)
        XCTAssertEqual(values["SRCROOT"] as? String, graph.sourceRoot.path)
        XCTAssertEqual(values["PROJECT_DIR"] as? String, graph.sourceRoot.path)
        XCTAssertEqual(values["PROJECT_FILE_PATH"] as? String, graph.url.deletingLastPathComponent().path)
        XCTAssertNotEqual(graph.sourceRoot.path, graph.url.deletingLastPathComponent().deletingLastPathComponent().path)
    }

    func testRedirectedSourceRootSelectsItsOwnRelativeSDK() throws {
        let (graph, config, _) = try fixture(redirected: true)
        _ = try sdk(graph.sourceRoot)
        let values = try direct(
            graph, config, settings: ["SDKROOT": "./SelectedSDK.sdk", "VALUE[sdk=macosx99.*]": "selected"])
        XCTAssertEqual(values["VALUE"] as? String, "selected")
    }

    func testBareSDKBundleNameResolvesFromSourceRoot() throws {
        let (graph, config, _) = try fixture()
        _ = try sdk(graph.sourceRoot)
        let values = try direct(
            graph, config, settings: ["SDKROOT": "SelectedSDK.sdk", "VALUE[sdk=macosx99.*]": "selected"])
        XCTAssertEqual(values["VALUE"] as? String, "selected")
    }

    func testRelativeSDKSelectionIsIndependentOfTheWorkingDirectory() throws {
        let (first, config, _) = try fixture()
        let (second, other, _) = try fixture()
        _ = try sdk(first.sourceRoot)
        _ = try sdk(second.sourceRoot, canonical: "macosx88.2")
        for (graph, config, version) in [(first, config, "99"), (second, other, "88")] {
            let values = try direct(
                graph, config,
                settings: [
                    "SDKROOT": "./SelectedSDK.sdk", "VALUE[sdk=macosx\(version).*]": version,
                ])
            XCTAssertEqual(values["VALUE"] as? String, version)
        }
    }

    func testExplicitProjectDirectoryIsAvailableToExpansion() throws {
        let (graph, config, _) = try fixture()
        let custom = graph.sourceRoot.appendingPathComponent("Override")
        _ = try sdk(custom)
        let values = try direct(
            graph, config,
            settings: [
                "PROJECT_DIR": custom.path, "SDKROOT": "$(PROJECT_DIR)/SelectedSDK.sdk",
                "VALUE[sdk=macosx99.*]": "selected",
            ])
        XCTAssertEqual(values["PROJECT_DIR"] as? String, custom.path)
        XCTAssertEqual(values["VALUE"] as? String, "selected")
    }

    func testSourceRootAliasFollowsAnExplicitSRCROOTOverride() throws {
        let (graph, config, _) = try fixture()
        let custom = graph.sourceRoot.appendingPathComponent("Custom")
        _ = try sdk(custom)
        let values = try direct(
            graph, config,
            settings: [
                "SRCROOT": custom.path, "SDKROOT": "$(SOURCE_ROOT)/SelectedSDK.sdk",
                "VALUE[sdk=macosx99.*]": "selected",
            ])
        XCTAssertEqual(values["SOURCE_ROOT"] as? String, custom.path)
        XCTAssertEqual(values["VALUE"] as? String, "selected")
    }

    func testRelativeSDKIgnoresAnOverriddenProjectDirectory() throws {
        let (graph, config, _) = try fixture()
        _ = try sdk(graph.sourceRoot)
        let custom = graph.sourceRoot.appendingPathComponent("Override")
        _ = try sdk(custom, canonical: "iphoneos99.4")
        let values = try direct(
            graph, config,
            settings: [
                "PROJECT_DIR": custom.path, "SDKROOT": "SelectedSDK.sdk", "VALUE[sdk=macosx99.*]": "selected",
                "WRONG[sdk=iphoneos*]": "wrong",
            ])
        XCTAssertEqual(values["VALUE"] as? String, "selected")
        XCTAssertNil(values["WRONG"])
    }

    func testTargetAndConfigurationDefaultsReachHookQueries() throws {
        let (graph, config, target) = try fixture()
        _ = try sdk(graph.sourceRoot, name: "Consumer-Debug.sdk")
        graph.objects[config]?["buildSettings"] = [
            "SDKROOT": "$(PROJECT_DIR)/$(TARGET_NAME)-$(CONFIGURATION).sdk", "VALUE[sdk=macosx99.*]": "selected",
        ]
        XCTAssertEqual(try response(graph, target: target, key: "TARGET_NAME")["Debug"] as? String, "Consumer")
        XCTAssertEqual(try response(graph, target: target, key: "VALUE")["Debug"] as? String, "selected")
    }

    func testImplicitSDKVariablesParticipateInPlatformInference() throws {
        let (graph, config, _) = try fixture()
        _ = try sdk(graph.sourceRoot)
        graph.objects[config]?["buildSettings"] = [
            "SDKROOT": "$(SRCROOT)/SelectedSDK.sdk", "MACOSX_DEPLOYMENT_TARGET": "13.0",
            "MACOSX_DEPLOYMENT_TARGET[sdk=macosx99.*]": "14.0",
        ]
        try graph.save()
        let request: [String: Any] = ["project": "External.xcodeproj", "targets": [["name": "Consumer"]]]
        XCTAssertNoThrow(try NativeManifest.analyze(request, project: graph.sourceRoot, integrate: true))
        if let result = try? NativeManifest.analyze(request, project: graph.sourceRoot, integrate: true),
            let target = (result["targets"] as? [[String: Any]])?.first
        {
            XCTAssertEqual(target["platform"] as? [String: String], ["name": "osx", "deployment_target": "14.0"])
        }
    }

    func testProjectLevelSDKVariablesSeeTheTargetsConfiguration() throws {
        let (graph, config, _) = try fixture()
        _ = try sdk(graph.sourceRoot, name: "Debug.sdk")
        let value = graph.objects[config]!
        let base: [String: Any] = [
            "isa": "XCBuildConfiguration", "name": "Debug",
            "buildSettings": [
                "SDKROOT": "$(PROJECT_DIR)/$(CONFIGURATION).sdk", "VALUE[sdk=macosx99.*]": "selected",
            ],
        ]
        var target = value
        target["buildSettings"] = [:]
        let values = try NativeBuildSettings.resolved(target, inheriting: base, graph: graph)
        XCTAssertEqual(values["VALUE"] as? String, "selected")
    }

    func testUnknownMacrosCannotSelectSDKByTheirLastPathComponent() throws {
        let (graph, config, _) = try fixture()
        let values = try direct(
            graph, config,
            settings: [
                "SDKROOT": "$(UNKNOWN_SDK_ROOT)/MacOSX.sdk", "WRONG[sdk=macosx*]": "wrong",
            ])
        XCTAssertNil(values["WRONG"])
        XCTAssertEqual(values["SDKROOT"] as? String, "$(UNKNOWN_SDK_ROOT)/MacOSX.sdk")
    }

    func testMissingBundleCannotSelectSDKByItsFilename() throws {
        let (graph, config, _) = try fixture()
        let missing = graph.sourceRoot.appendingPathComponent("Absent/MacOSX.sdk")
        let values = try direct(
            graph, config,
            settings: [
                "SDKROOT": missing.path, "WRONG[sdk=macosx*]": "wrong",
            ])
        XCTAssertNil(values["WRONG"])
    }

    func testUnrelatedUnknownVariablesRetainTheirOriginalValue() throws {
        let (graph, config, _) = try fixture()
        let values = try direct(graph, config, settings: ["VALUE": "$(UNDECLARED)/literal"])
        XCTAssertEqual(try NativeBuildSettings.expandedValue("VALUE", settings: values), "$(UNDECLARED)/literal")
    }

    func testPercentAndCombiningSourceRootsRemainLiteral() throws {
        let (graph, config, _) = try fixture()
        graph.objects[graph.root["rootObject"] as! String]?["projectDirPath"] = "../\u{301}Root%2FName"
        try FileManager.default.createDirectory(at: graph.sourceRoot, withIntermediateDirectories: true)
        _ = try sdk(graph.sourceRoot)
        let values = try direct(
            graph, config,
            settings: [
                "SDKROOT": "$(SOURCE_ROOT)/SelectedSDK.sdk", "VALUE[sdk=macosx99.*]": "selected",
            ])
        XCTAssertEqual(values["SOURCE_ROOT"] as? String, graph.sourceRoot.path)
        XCTAssertEqual(values["VALUE"] as? String, "selected")
    }
    func testBaseConfigurationReferencesExpandBothRootMacroForms() throws {
        let (graph, _, _) = try fixture()
        for variable in ["SRCROOT", "SOURCE_ROOT", "PROJECT_DIR"] {
            for token in ["$(\(variable))", "${\(variable)}"] {
                let file = graph.add(
                    UUID().uuidString,
                    [
                        "isa": "PBXFileReference", "path": token + "/Configs/Base.xcconfig", "sourceTree": "<absolute>",
                    ])
                XCTAssertEqual(
                    try NativeBuildSettings.file(file, graph: graph).path,
                    graph.sourceRoot.appendingPathComponent("Configs/Base.xcconfig").path)
            }
        }
    }

    func testProjectNameAndFilePathExpandInConfigurationReferences() throws {
        let (graph, _, _) = try fixture()
        let named = graph.add(
            "named-reference",
            [
                "isa": "PBXFileReference", "path": "${PROJECT_DIR}/Configs/$(PROJECT_NAME).xcconfig",
                "sourceTree": "<absolute>",
            ])
        XCTAssertEqual(
            try NativeBuildSettings.file(named, graph: graph).path,
            graph.sourceRoot.appendingPathComponent("Configs/External.xcconfig").path)
        let container = graph.add(
            "container-reference",
            [
                "isa": "PBXFileReference", "path": "${PROJECT_FILE_PATH}/../Configs/Base.xcconfig",
                "sourceTree": "<absolute>",
            ])
        XCTAssertEqual(
            try NativeBuildSettings.file(container, graph: graph).path,
            graph.url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
                "Configs/Base.xcconfig"
            ).path)
    }

    func testSelectedConfigurationReachesTheBaseFileReference() throws {
        let (graph, config, _) = try fixture()
        let folder = graph.sourceRoot.appendingPathComponent("Configs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["Debug", "Release"] {
            try Data("VALUE = \(name)\n".utf8).write(to: folder.appendingPathComponent(name + ".xcconfig"))
        }
        let file = graph.add(
            "configuration-reference",
            [
                "isa": "PBXFileReference", "path": "$(PROJECT_DIR)/Configs/${CONFIGURATION}.xcconfig",
                "sourceTree": "<absolute>",
            ])
        for name in ["Debug", "Release"] {
            var value = graph.objects[config]!
            value["name"] = name
            value["baseConfigurationReference"] = file
            XCTAssertEqual(try NativeBuildSettings.resolved(value, graph: graph)["VALUE"] as? String, name)
        }
    }

    func testTargetNameReachesTheBaseFileReferenceInHookQueries() throws {
        let (graph, config, target) = try fixture()
        let folder = graph.sourceRoot.appendingPathComponent("Configs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("VALUE = selected\n".utf8).write(to: folder.appendingPathComponent("Consumer.xcconfig"))
        let file = graph.add(
            "target-reference",
            [
                "isa": "PBXFileReference", "path": "$(SOURCE_ROOT)/Configs/$(TARGET_NAME).xcconfig",
                "sourceTree": "<absolute>",
            ])
        graph.objects[config]?["baseConfigurationReference"] = file
        XCTAssertEqual(try response(graph, target: target, key: "VALUE")["Debug"] as? String, "selected")
    }

    func testExpandedReferenceNulIsRejectedBeforeURLConstruction() throws {
        let (graph, config, _) = try fixture()
        let file = graph.add(
            "nul-reference",
            [
                "isa": "PBXFileReference", "path": "$(PROJECT_DIR)/Configs/$(CONFIGURATION).xcconfig",
                "sourceTree": "<absolute>",
            ])
        var value = graph.objects[config]!
        value["name"] = "Debug\0Ignored"
        value["baseConfigurationReference"] = file
        XCTAssertThrowsError(try NativeBuildSettings.resolved(value, graph: graph)) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCCONFIG-PATH")
        }
    }

}
