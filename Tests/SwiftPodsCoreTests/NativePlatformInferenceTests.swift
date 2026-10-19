import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativePlatformInferenceTests: XCTestCase {
    private func project(_ settings: [[String: Any]], xcconfig: String? = nil, projectSettings: [String: Any] = [:])
        throws -> NativePBX
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let graph = try NativePBX(root.appendingPathComponent("App.xcodeproj/project.pbxproj"))
        let configs = settings.enumerated().map { index, values in
            graph.add(
                "config:\(index)",
                ["isa": "XCBuildConfiguration", "name": index == 0 ? "Debug" : "Release", "buildSettings": values])
        }
        if let xcconfig {
            try Data(xcconfig.utf8).write(to: root.appendingPathComponent("Base.xcconfig"))
            let file = graph.add(
                "base", ["isa": "PBXFileReference", "path": "Base.xcconfig", "sourceTree": "SOURCE_ROOT"])
            for config in configs { graph.objects[config]?["baseConfigurationReference"] = file }
        }
        let list = graph.add("configs", ["isa": "XCConfigurationList", "buildConfigurations": configs])
        let projectConfigs = settings.enumerated().map { index, _ in
            graph.add(
                "project-config:\(index)",
                [
                    "isa": "XCBuildConfiguration", "name": index == 0 ? "Debug" : "Release",
                    "buildSettings": projectSettings,
                ])
        }
        let projectList = graph.add(
            "project-configs", ["isa": "XCConfigurationList", "buildConfigurations": projectConfigs])
        let target = graph.add("app", ["isa": "PBXNativeTarget", "name": "App", "buildConfigurationList": list])
        let group = graph.add("group", ["isa": "PBXGroup", "children": []])
        let id = graph.add(
            "project",
            [
                "isa": "PBXProject", "targets": [target], "mainGroup": group, "projectDirPath": "",
                "buildConfigurationList": projectList,
            ])
        graph.root = ["archiveVersion": "1", "objectVersion": "56", "rootObject": id]
        try graph.save()
        return graph
    }

    private func analyze(_ graph: NativePBX, platform: [String: String]? = nil) throws -> [String: Any] {
        var target: [String: Any] = ["name": "App"]
        target["platform"] = platform
        return try NativeManifest.analyze(
            ["project": "App.xcodeproj", "targets": [target]], project: graph.sourceRoot, integrate: true)
    }

    private var mac: [String: Any] { ["SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "13.0"] }

    func testPlatformInferenceCannotDropAnInvalidConfiguration() throws {
        for invalid: [String: Any] in [
            ["SDKROOT": "custom-sdk", "MACOSX_DEPLOYMENT_TARGET": "13.0"],
            ["SDKROOT": "macosx"],
            ["SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "$(MISSING_MINIMUM)"],
            ["SDKROOT": "iphoneos", "MACOSX_DEPLOYMENT_TARGET": "13.0"],
        ] {
            for settings in [[mac, invalid], [invalid, mac]] {
                let graph = try project(settings)
                XCTAssertThrowsError(try analyze(graph)) { error in
                    XCTAssertEqual((error as? Diagnostic)?.code, "SP-PLATFORM-MISSING")
                }
            }
        }
    }

    func testAutomaticSDKIgnoresExplicitlyEmptyDeploymentSettings() throws {
        for (mac, ios, name, minimum) in [("13.0", "", "osx", "13.0"), ("", "15.0", "ios", "15.0")] {
            let graph = try project([
                ["SDKROOT": "auto", "MACOSX_DEPLOYMENT_TARGET": mac, "IPHONEOS_DEPLOYMENT_TARGET": ios]
            ])
            let target = try XCTUnwrap((try analyze(graph)["targets"] as? [[String: Any]])?.first)
            XCTAssertEqual(target["platform"] as? [String: String], ["name": name, "deployment_target": minimum])
        }
    }

    func testAutomaticSDKRejectsMultipleDeploymentPlatforms() throws {
        for sdk in ["", "auto"] {
            let graph = try project([
                ["SDKROOT": sdk, "MACOSX_DEPLOYMENT_TARGET": "13.0", "IPHONEOS_DEPLOYMENT_TARGET": "15.0"]
            ])
            XCTAssertThrowsError(try analyze(graph)) { error in
                XCTAssertEqual((error as? Diagnostic)?.code, "SP-PLATFORM-MISSING")
            }
        }
    }

    func testSDKPathsAndNamesInferEverySupportedPlatform() throws {
        for (name, sdk, deployment, minimum) in [
            ("osx", "MacOSX27.0.sdk", "MACOSX_DEPLOYMENT_TARGET", "13.0"),
            ("ios", "iPhoneOS27.0.sdk", "IPHONEOS_DEPLOYMENT_TARGET", "15.0"),
            ("tvos", "AppleTVSimulator27.0.sdk", "TVOS_DEPLOYMENT_TARGET", "15.0"),
            ("watchos", "WatchOS27.0.sdk", "WATCHOS_DEPLOYMENT_TARGET", "8.0"),
            ("visionos", "XRSimulator27.0.sdk", "XROS_DEPLOYMENT_TARGET", "1.0"),
        ] {
            let graph = try project([["SDKROOT": "/SDKs/" + sdk, deployment: minimum]])
            let targets = try XCTUnwrap(try analyze(graph)["targets"] as? [[String: Any]])
            XCTAssertEqual(
                targets.first?["platform"] as? [String: String], ["name": name, "deployment_target": minimum])
        }
    }

    func testSDKParentDirectoryCannotSelectThePlatform() throws {
        let graph = try project([["SDKROOT": "/SDKs/iphone-tools/Custom.sdk", "IPHONEOS_DEPLOYMENT_TARGET": "15.0"]])
        XCTAssertThrowsError(try analyze(graph))
    }

    func testCompleteConfigurationsChooseTheLowestDeploymentVersion() throws {
        let graph = try project([mac, ["SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "14.0"]])
        let targets = try XCTUnwrap(try analyze(graph)["targets"] as? [[String: Any]])
        XCTAssertEqual(targets.first?["platform"] as? [String: String], ["name": "osx", "deployment_target": "13.0"])
    }

    func testOneAutomaticDeploymentPlatformAndExplicitPodfilePlatformRemainSupported() throws {
        let graph = try project([["SDKROOT": "auto", "MACOSX_DEPLOYMENT_TARGET": "13.0"]])
        XCTAssertNoThrow(try analyze(graph))
        let ambiguous = try project([
            ["SDKROOT": "auto", "MACOSX_DEPLOYMENT_TARGET": "13.0", "IPHONEOS_DEPLOYMENT_TARGET": "15.0"]
        ])
        XCTAssertNoThrow(try analyze(ambiguous, platform: ["name": "osx", "deployment_target": "13.0"]))
    }

    func testAbsoluteSDKMatchesConditionsWithoutRewritingItsValue() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("MacOSX27.0.sdk")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        try JSONSerialization.data(withJSONObject: ["CanonicalName": "macosx27.0"])
            .write(to: directory.appendingPathComponent("SDKSettings.json"))
        let sdk = directory.path
        for text in [
            "SDKROOT = \(sdk)\nVALUE[sdk=macosx*] = selected\n",
            "VALUE[sdk=macosx*] = selected\nSDKROOT = \(sdk)\n",
        ] {
            let graph = try project([[:]], xcconfig: text)
            let config = try XCTUnwrap(graph.objects[NativePBX.identifier("config:0")])
            let values = try NativeBuildSettings.resolved(config, graph: graph)
            XCTAssertEqual(values["VALUE"] as? String, "selected")
            XCTAssertEqual(values["SDKROOT"] as? String, sdk)
        }
    }

    func testDirectSDKConditionsUseTheFinalSDKAcrossIncludesAndTargetOverrides() throws {
        let graph = try project(
            [
                [
                    "SDKROOT": "iphoneos", "SDKROOT[config=Debug]": "macosx",
                    "DIRECT[sdk=macosx*]": "selected", "WRONG[sdk=iphoneos*]": "unselected",
                ]
            ], xcconfig: "INCLUDED[sdk=macosx*] = selected\nWRONG_INCLUDED[sdk=iphoneos*] = unselected\n")
        let config = try XCTUnwrap(graph.objects[NativePBX.identifier("config:0")])
        let values = try NativeBuildSettings.resolved(config, graph: graph)
        XCTAssertEqual(values["SDKROOT"] as? String, "macosx")
        XCTAssertEqual(values["DIRECT"] as? String, "selected")
        XCTAssertEqual(values["INCLUDED"] as? String, "selected")
        XCTAssertNil(values["WRONG"])
        XCTAssertNil(values["WRONG_INCLUDED"])
    }

    func testProjectSDKConditionsUseTheTargetsSDKForDeploymentAndSwiftVersions() throws {
        let graph = try project(
            [["SDKROOT": "macosx"]],
            projectSettings: [
                "SDKROOT": "iphoneos", "MACOSX_DEPLOYMENT_TARGET[sdk=macosx*]": "13.0",
                "IPHONEOS_DEPLOYMENT_TARGET[sdk=iphoneos*]": "15.0",
                "SWIFT_VERSION[sdk=macosx*]": "6.0", "SWIFT_VERSION[sdk=iphoneos*]": "5.0",
            ])
        let target = try XCTUnwrap((try analyze(graph)["targets"] as? [[String: Any]])?.first)
        XCTAssertEqual(target["platform"] as? [String: String], ["name": "osx", "deployment_target": "13.0"])
        XCTAssertEqual(target["swift_version"] as? String, "6.0")
    }

    func testConditionalTargetSDKReevaluatesProjectSDKConditions() throws {
        let graph = try project(
            [["SDKROOT": "iphoneos", "SDKROOT[config=Debug]": "macosx"]],
            projectSettings: [
                "SDKROOT": "iphoneos", "MACOSX_DEPLOYMENT_TARGET": "13.0",
                "SWIFT_VERSION[sdk=macosx*]": "6.0", "SWIFT_VERSION[sdk=iphoneos*]": "5.0",
            ])
        let target = try XCTUnwrap((try analyze(graph)["targets"] as? [[String: Any]])?.first)
        XCTAssertEqual(target["swift_version"] as? String, "6.0")
    }

    func testProjectSDKAndMinimumRemainInheritedWithoutATargetOverride() throws {
        let graph = try project([[:]], projectSettings: ["SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "14.0"])
        let target = try XCTUnwrap((try analyze(graph)["targets"] as? [[String: Any]])?.first)
        XCTAssertEqual(target["platform"] as? [String: String], ["name": "osx", "deployment_target": "14.0"])
    }

    func testDirectConditionalSDKCyclesAreDiagnosed() throws {
        let graph = try project([
            ["SDKROOT": "macosx", "SDKROOT[sdk=macosx*]": "iphoneos", "SDKROOT[sdk=iphoneos*]": "macosx"]
        ])
        let config = try XCTUnwrap(graph.objects[NativePBX.identifier("config:0")])
        XCTAssertThrowsError(try NativeBuildSettings.resolved(config, graph: graph)) { error in
            XCTAssertEqual((error as? Diagnostic)?.code, "SP-XCCONFIG-CYCLE")
        }
    }
}
