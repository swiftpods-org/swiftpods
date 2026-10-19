import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeSDKConditionBoundaryTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func bundle(_ root: URL, name: String = "MacOSX.sdk", canonical: String = "macosx99.4", plist: Bool = false)
        throws -> URL
    {
        let sdk = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        let metadata = ["CanonicalName": canonical, "Version": "99.4"]
        let data =
            try plist
            ? PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0)
            : JSONSerialization.data(withJSONObject: metadata)
        try data.write(to: sdk.appendingPathComponent(plist ? "SDKSettings.plist" : "SDKSettings.json"))
        return sdk
    }

    private func applies(_ pattern: String, _ sdk: URL) -> Bool {
        NativeBuildSettings.conditions("VALUE[sdk=\(pattern)]", context: ["sdk": sdk.path]).1
    }

    private func read(_ root: URL, _ text: String) throws -> [String: Any] {
        let path = root.appendingPathComponent("Base.xcconfig")
        try Data(text.utf8).write(to: path)
        var inputs = Set<String>()
        return try NativeBuildSettings.xcconfig(path, inputs: &inputs)
    }

    private func graph(_ root: URL, sdk: URL, projectSettings: [String: Any] = [:], targetSettings: [String: Any] = [:])
        throws -> (NativePBX, [String: Any], [String: Any])
    {
        let graph = try NativePBX(root.appendingPathComponent("App.xcodeproj/project.pbxproj"))
        let base: [String: Any] = ["isa": "XCBuildConfiguration", "name": "Debug", "buildSettings": projectSettings]
        let target: [String: Any] = [
            "isa": "XCBuildConfiguration", "name": "Debug",
            "buildSettings": ["SDKROOT": sdk.path, "MACOSX_DEPLOYMENT_TARGET": "13.0"].merging(targetSettings) {
                _, new in new
            },
        ]
        let p = graph.add("base", base)
        let t = graph.add("configuration", target)
        let pList = graph.add("project-configurations", ["isa": "XCConfigurationList", "buildConfigurations": [p]])
        let tList = graph.add("target-configurations", ["isa": "XCConfigurationList", "buildConfigurations": [t]])
        let app = graph.add("target", ["isa": "PBXNativeTarget", "name": "App", "buildConfigurationList": tList])
        let group = graph.add("group", ["isa": "PBXGroup", "children": []])
        let project = graph.add(
            "project",
            [
                "isa": "PBXProject", "targets": [app], "mainGroup": group, "projectDirPath": "",
                "buildConfigurationList": pList,
            ])
        graph.root = ["archiveVersion": "1", "objectVersion": "56", "rootObject": project]
        try graph.save()
        return (graph, target, base)
    }

    private func analyze(_ graph: NativePBX) throws -> [String: Any] {
        let result = try NativeManifest.analyze(
            ["project": "App.xcodeproj", "targets": [["name": "App"]]], project: graph.sourceRoot, integrate: true)
        return try XCTUnwrap((result["targets"] as? [[String: Any]])?.first)
    }

    func testJSONCanonicalNameSelectsTheActualSDKVersion() throws {
        let sdk = try bundle(directory())
        XCTAssertTrue(applies("macosx99.4", sdk))
        XCTAssertTrue(applies("macosx99.*", sdk))
        XCTAssertFalse(applies("macosx98.*", sdk))
    }

    func testPlistMetadataSelectsTheActualSDKVersion() throws {
        let sdk = try bundle(directory(), plist: true)
        XCTAssertTrue(applies("macosx99.4", sdk))
        XCTAssertTrue(applies("macosx99.*", sdk))
    }

    func testBundleFilenameCannotSelectAnotherSDK() throws {
        let sdk = try bundle(directory(), name: "iPhoneOS.sdk")
        XCTAssertTrue(applies("macosx99.*", sdk))
        XCTAssertFalse(applies("iphoneos*", sdk))
    }

    func testUnversionedExactPatternDoesNotMatchAVersionedSDK() throws {
        let sdk = try bundle(directory())
        XCTAssertFalse(applies("macosx", sdk))
        XCTAssertTrue(applies("macosx*", sdk))
    }

    func testSDKAliasUsesItsMetadata() throws {
        let root = try directory()
        let sdk = try bundle(root)
        let alias = root.appendingPathComponent("ToolchainAlias.sdk")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: sdk)
        XCTAssertTrue(applies("macosx99.*", alias))
        XCTAssertFalse(applies("toolchainalias*", alias))
    }

    func testXcconfigKeepsRawSDKROOTWhileSelectingCanonicalConditions() throws {
        let root = try directory()
        let sdk = try bundle(root)
        let values = try read(
            root, "SDKROOT = \(sdk.path)\nVALUE[sdk=macosx99.*] = selected\nWRONG[sdk=macosx] = wrong\n")
        XCTAssertEqual(values["SDKROOT"] as? String, sdk.path)
        XCTAssertEqual(values["VALUE"] as? String, "selected")
        XCTAssertNil(values["WRONG"])
    }

    func testDirectAndInheritedConditionsSeeTheSameFinalSDK() throws {
        let root = try directory()
        let sdk = try bundle(root)
        let (graph, target, base) = try graph(
            root, sdk: sdk,
            projectSettings: ["SDKROOT": "iphoneos", "BASE[sdk=macosx99.*]": "base"],
            targetSettings: ["DIRECT[sdk=macosx99.*]": "target"])
        let values = try NativeBuildSettings.resolved(target, inheriting: base, graph: graph)
        XCTAssertEqual(values["BASE"] as? String, "base")
        XCTAssertEqual(values["DIRECT"] as? String, "target")
        XCTAssertEqual(values["SDKROOT"] as? String, sdk.path)
    }

    func testLateIncludeSDKSelectionUsesCanonicalName() throws {
        let root = try directory()
        let sdk = try bundle(root)
        try Data("SDKROOT = \(sdk.path)\n".utf8).write(to: root.appendingPathComponent("SDK.xcconfig"))
        let values = try read(root, "VALUE[sdk=macosx99.*] = selected\n#include \"SDK.xcconfig\"\n")
        XCTAssertEqual(values["VALUE"] as? String, "selected")
    }

    func testConditionalMinimumParticipatesInPlatformInference() throws {
        let root = try directory()
        let sdk = try bundle(root)
        let (graph, _, _) = try graph(
            root, sdk: sdk,
            targetSettings: ["MACOSX_DEPLOYMENT_TARGET[sdk=macosx99.*]": "14.0"])
        XCTAssertEqual(
            try analyze(graph)["platform"] as? [String: String], ["name": "osx", "deployment_target": "14.0"])
    }

    func testSDKMetadataCanInferPlatformThroughAnAlias() throws {
        let root = try directory()
        let sdk = try bundle(root, name: "ToolchainAlias.sdk")
        let (graph, _, _) = try graph(root, sdk: sdk)
        XCTAssertNoThrow(try analyze(graph))
        if let target = try? analyze(graph) {
            XCTAssertEqual(target["platform"] as? [String: String], ["name": "osx", "deployment_target": "13.0"])
        }
    }

    func testEqualBundleBasenamesCannotShareAnotherSDKsIdentity() throws {
        let root = try directory()
        let first = try bundle(root.appendingPathComponent("first"))
        let second = try bundle(root.appendingPathComponent("second"), canonical: "macosx88.2")
        XCTAssertTrue(applies("macosx99.*", first))
        XCTAssertFalse(applies("macosx99.*", second))
        XCTAssertTrue(applies("macosx88.*", second))
    }

    func testMetadataChangesAreVisibleToTheNextEvaluation() throws {
        let root = try directory()
        let sdk = try bundle(root)
        XCTAssertEqual(
            try read(root, "SDKROOT = \(sdk.path)\nVALUE[sdk=macosx99.*] = first\n")["VALUE"] as? String, "first")
        _ = try bundle(root, canonical: "macosx88.2")
        XCTAssertEqual(
            try read(root, "SDKROOT = \(sdk.path)\nVALUE[sdk=macosx88.*] = second\n")["VALUE"] as? String, "second")
    }

    func testPercentAndCombiningNamesRemainLiteralSDKPaths() throws {
        let sdk = try bundle(directory(), name: "\u{301}SDK%2FName.sdk")
        XCTAssertTrue(applies("macosx99.*", sdk))
    }

    func testRetargetedSymlinkUsesTheNewSDKMetadata() throws {
        let root = try directory()
        let first = try bundle(root.appendingPathComponent("first"))
        let second = try bundle(root.appendingPathComponent("second"), canonical: "macosx88.2")
        let alias = root.appendingPathComponent("Selected.sdk")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
        XCTAssertTrue(applies("macosx99.*", alias))
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
        XCTAssertTrue(applies("macosx88.*", alias))
        XCTAssertFalse(applies("macosx99.*", alias))
    }
}
