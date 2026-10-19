import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeConditionContextTests: XCTestCase {
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }

    private func context() throws -> NativeSDKContext {
        let root = try directory()
        for (name, canonical) in [("macosx", "macosx99.4"), ("iphoneos", "iphoneos88.2")] {
            let sdk = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["CanonicalName": canonical])
                .write(to: sdk.appendingPathComponent("SDKSettings.json"))
        }
        return NativeSDKContext(locate: { name, _ in
            ["macosx", "iphoneos"].contains(name) ? root.appendingPathComponent(name) : nil
        })
    }

    private func configuration(_ settings: [String: Any]) -> [String: Any] {
        ["isa": "XCBuildConfiguration", "name": "Debug", "buildSettings": settings]
    }

    private func read(_ text: String, sdkContext: NativeSDKContext) throws -> [String: Any] {
        let root = try directory()
        let file = root.appendingPathComponent("Base.xcconfig")
        try Data(text.utf8).write(to: file)
        var inputs = Set<String>()
        return try NativeBuildSettings.xcconfig(file, inputs: &inputs, sdkContext: sdkContext)
    }

    func testUniversalConditionsDoNotRequireAnAxisValue() {
        for axis in ["sdk", "arch", "config", "variant", "flavor", "sdk "] {
            XCTAssertTrue(NativeBuildSettings.conditions("VALUE[\(axis)=*]", context: [:]).1, axis)
        }
    }

    func testUniversalSDKConditionDoesNotLookUpAnUnavailableSDK() {
        let sdkContext = NativeSDKContext(locate: { _, _ in
            XCTFail("A universal condition does not need SDK metadata")
            return nil
        })
        XCTAssertTrue(
            NativeBuildSettings.conditions("VALUE[sdk=*]", context: ["sdk": "Unavailable"], sdkContext: sdkContext).1)
    }

    func testOnlyTheSingleUniversalPatternMatchesAnUnavailableSDK() {
        let sdkContext = NativeSDKContext(locate: { _, _ in nil })
        for value in ["auto", "MissingSDK", "/Absent/MacOSX.sdk", "$(UNDECLARED)/MacOSX.sdk"] {
            for pattern in ["*", "**", "?*", "*?", "macosx*", "*MacOSX.sdk", "auto", ""] {
                XCTAssertEqual(
                    NativeBuildSettings.conditions(
                        "VALUE[sdk=\(pattern)]", context: ["sdk": value], sdkContext: sdkContext
                    ).1,
                    pattern == "*", value + " " + pattern)
            }
        }
    }

    func testUniversalConditionsStillRejectNulValues() {
        XCTAssertFalse(NativeBuildSettings.conditions("VALUE[sdk=*]", context: ["sdk": "macosx\0tail"]).1)
        XCTAssertFalse(NativeBuildSettings.conditions("VALUE[sdk=*\0tail]", context: [:]).1)
    }

    func testUniversalConditionsDoNotBypassOtherConditions() {
        for configuration in ["Debug", "Release"] {
            XCTAssertEqual(
                NativeBuildSettings.conditions(
                    "VALUE[flavor=*][sdk=*][config=Release]", context: ["config": configuration]
                ).1,
                configuration == "Release")
        }
    }

    func testEmptyAndMissingSDKROOTUseDefaultSDKConditionsWithoutInventingADeclaration() throws {
        let graph = try NativePBX(try directory().appendingPathComponent("Project.xcodeproj/project.pbxproj"))
        for declared: String? in [nil, ""] {
            var settings: [String: Any] = ["VALUE[sdk=macosx99.*]": "selected"]
            settings["SDKROOT"] = declared
            let values = try NativeBuildSettings.resolved(configuration(settings), graph: graph, sdkContext: context())
            XCTAssertEqual(values["VALUE"] as? String, "selected")
            XCTAssertEqual(values["SDKROOT"] as? String, declared)
        }
    }

    func testDefaultSDKConditionsAlsoApplyToAStandaloneConfigurationFile() throws {
        let values = try read("VALUE[sdk=macosx99.*] = selected\n", sdkContext: context())
        XCTAssertEqual(values["VALUE"] as? String, "selected")
        XCTAssertNil(values["SDKROOT"])
    }

    func testAutomaticSDKDoesNotInheritTheDefaultSDKIdentity() throws {
        let graph = try NativePBX(try directory().appendingPathComponent("Project.xcodeproj/project.pbxproj"))
        let values = try NativeBuildSettings.resolved(
            configuration(["SDKROOT": "auto", "ANY[sdk=*]": "selected", "WRONG[sdk=macosx*]": "wrong"]),
            graph: graph, sdkContext: context())
        XCTAssertEqual(values["ANY"] as? String, "selected")
        XCTAssertNil(values["WRONG"])
        XCTAssertEqual(values["SDKROOT"] as? String, "auto")
    }

    func testLateAutomaticSDKReevaluatesEarlierConditionsIncludingAnInclude() throws {
        let root = try directory()
        try Data("SDKROOT = auto\n".utf8).write(to: root.appendingPathComponent("SDK.xcconfig"))
        for tail in ["SDKROOT = auto\n", "#include \"SDK.xcconfig\"\n"] {
            let file = root.appendingPathComponent("Base.xcconfig")
            try Data(("ANY[sdk=*] = selected\nWRONG[sdk=macosx*] = wrong\n" + tail).utf8).write(to: file)
            var inputs = Set<String>()
            let values = try NativeBuildSettings.xcconfig(file, inputs: &inputs, sdkContext: context())
            XCTAssertEqual(values["ANY"] as? String, "selected")
            XCTAssertNil(values["WRONG"])
            XCTAssertEqual(values["SDKROOT"] as? String, "auto")
        }
    }

    func testProjectConditionsUseTheTargetsAutomaticSDK() throws {
        let graph = try NativePBX(try directory().appendingPathComponent("Project.xcodeproj/project.pbxproj"))
        let values = try NativeBuildSettings.resolved(
            configuration(["SDKROOT": "auto"]),
            inheriting: configuration(["SDKROOT": "macosx", "WRONG[sdk=macosx*]": "wrong", "ANY[sdk=*]": "selected"]),
            graph: graph, sdkContext: context())
        XCTAssertEqual(values["ANY"] as? String, "selected")
        XCTAssertNil(values["WRONG"])
    }

    func testProjectConditionsUseTheTargetsEmptySDK() throws {
        let graph = try NativePBX(try directory().appendingPathComponent("Project.xcodeproj/project.pbxproj"))
        let values = try NativeBuildSettings.resolved(
            configuration(["SDKROOT": ""]),
            inheriting: configuration([
                "SDKROOT": "iphoneos", "WRONG[sdk=iphoneos*]": "wrong", "MAC[sdk=macosx*]": "selected",
            ]),
            graph: graph, sdkContext: context())
        XCTAssertEqual(values["MAC"] as? String, "selected")
        XCTAssertNil(values["WRONG"])
        XCTAssertEqual(values["SDKROOT"] as? String, "")
    }

    func testConditionalAutomaticSDKDoesNotRetainAnEarlierIdentity() throws {
        let graph = try NativePBX(try directory().appendingPathComponent("Project.xcodeproj/project.pbxproj"))
        let values = try NativeBuildSettings.resolved(
            configuration([
                "SDKROOT": "macosx", "SDKROOT[config=Debug]": "auto", "WRONG[sdk=macosx*]": "wrong",
                "ANY[sdk=*]": "selected",
            ]),
            graph: graph, sdkContext: context())
        XCTAssertNil(values["WRONG"])
        XCTAssertEqual(values["ANY"] as? String, "selected")
        XCTAssertEqual(values["SDKROOT"] as? String, "auto")
    }
}
