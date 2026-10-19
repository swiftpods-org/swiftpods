import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeBuildSettingDefinitionTests: XCTestCase {
    private func fixture() throws -> (NativePBX, NativeSDKContext) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var sdks: [String: URL] = [:]
        for (name, canonical) in [("macosx", "macosx99.4"), ("iphoneos", "iphoneos99.4")] {
            let sdk = root.appendingPathComponent(name + ".sdk")
            try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["CanonicalName": canonical]).write(
                to: sdk.appendingPathComponent("SDKSettings.json"))
            sdks[name] = sdk
        }
        let graph = try NativePBX(root.appendingPathComponent("App.xcodeproj/project.pbxproj"))
        return (graph, NativeSDKContext(locate: { name, _ in sdks[name] }))
    }

    private func resolve(_ target: [String: Any], project: [String: Any] = [:], file: String? = nil) throws -> [String:
        Any]
    {
        let (graph, context) = try fixture()
        var configuration: [String: Any] = ["name": "Debug", "buildSettings": target]
        if let file {
            try Data(file.utf8).write(to: graph.sourceRoot.appendingPathComponent("Base.xcconfig"))
            configuration["baseConfigurationReference"] = graph.add(
                "base", ["isa": "PBXFileReference", "path": "Base.xcconfig", "sourceTree": "SOURCE_ROOT"])
        }
        return try NativeBuildSettings.resolved(
            configuration, inheriting: ["name": "Debug", "buildSettings": project], graph: graph, sdkContext: context)
    }

    func testNamedReferenceUsesThePreviousAssignment() throws {
        let scope = NativeBuildSettingScope(["LEVEL": "base"]).merging(["LEVEL": "$(LEVEL) next"])
        XCTAssertEqual(try scope.expandedValue("LEVEL"), "base next")
    }

    func testNamedReferencesTraverseMultipleAssignments() throws {
        let scope = NativeBuildSettingScope(["LEVEL": "base"]).merging(["LEVEL": "${LEVEL}/middle"]).merging([
            "LEVEL": "$(LEVEL:upper)/last"
        ])
        XCTAssertEqual(try scope.expandedValue("LEVEL"), "BASE/MIDDLE/last")
    }

    func testNamedInheritedAndValueReferencesUseTheSamePriorAssignment() throws {
        let scope = NativeBuildSettingScope(["LEVEL": "base"]).merging(["LEVEL": "$(LEVEL)/$(inherited)/$(value)"])
        XCTAssertEqual(try scope.expandedValue("LEVEL"), "base/base/base")
    }

    func testAncestorReferenceUsesTheAncestorsPreviousAssignment() throws {
        let scope = NativeBuildSettingScope(["FIRST": "base"]).merging(["FIRST": "$(SECOND)", "SECOND": "$(FIRST)"])
        XCTAssertEqual(try scope.expandedValue("FIRST"), "base")
    }

    func testSeparateContextsCannotReuseAnotherBranchesInheritedResult() throws {
        let scope = NativeBuildSettingScope(["FIRST": "first", "SECOND": "second"]).merging([
            "FIRST": "$(SECOND)", "SECOND": "$(FIRST)", "RESULT": "$(FIRST)/$(SECOND)",
        ])
        XCTAssertEqual(try scope.expandedValue("RESULT"), "first/second")
    }

    func testInheritedAliasesConsumeTheirOwnHistory() throws {
        let scope = NativeBuildSettingScope(["LEVEL": "base"]).merging(["LEVEL": "$(value)/middle"]).merging([
            "LEVEL": "$(inherited)/last"
        ])
        XCTAssertEqual(try scope.expandedValue("LEVEL"), "base/middle/last")
    }

    func testCyclesWithNoEarlierAssignmentStillHaveAnExplicitDiagnostic() {
        for settings in [["FIRST": "$(SECOND)", "SECOND": "$(FIRST)"], ["FIRST": "$(FIRST)"]] {
            XCTAssertThrowsError(try NativeBuildSettingScope(settings).expandedValue("FIRST")) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCCONFIG-CYCLE")
            }
        }
    }

    func testSDKSelfReferenceInheritsTheProjectValue() throws {
        let result = try resolve(
            ["SDKROOT": "$(SDKROOT)", "VALUE[sdk=iphoneos99.*]": "selected"], project: ["SDKROOT": "iphoneos"])
        XCTAssertEqual(result["VALUE"] as? String, "selected")
        XCTAssertEqual(result["SDKROOT"] as? String, "$(SDKROOT)")
    }

    func testSDKSelfReferenceCanUseTheGlobalDefaultWithoutInventingADeclaration() throws {
        let result = try resolve(["SDKROOT": "$(SDKROOT)", "VALUE[sdk=macosx99.*]": "selected"])
        XCTAssertEqual(result["VALUE"] as? String, "selected")
        XCTAssertEqual(result["SDKROOT"] as? String, "$(SDKROOT)")
        let undeclared = try resolve(["VALUE[sdk=macosx99.*]": "selected"])
        XCTAssertNil(undeclared["SDKROOT"])
        XCTAssertEqual(undeclared["VALUE"] as? String, "selected")
    }

    func testSDKSelfReferenceCanUseAnEarlierXcconfigAssignment() throws {
        let result = try resolve(
            [:], file: "SDKROOT = macosx\nSDKROOT = $(SDKROOT:lower)\nVALUE[sdk=macosx99.*] = selected\n")
        XCTAssertEqual(result["VALUE"] as? String, "selected")
    }

    func testPreliminarySDKResolutionWaitsForTheBaseFilesDefinitions() throws {
        let result = try resolve(
            ["SDKROOT": "$(SDK_CHOICE)", "SDK_CHOICE": "$(SDK_CHOICE:lower)"],
            file: "SDK_CHOICE = MACOSX\nVALUE[sdk=macosx99.*] = selected\n")
        XCTAssertEqual(result["VALUE"] as? String, "selected")
    }

    func testProjectSDKResolutionCanUseATargetBaseFileDefinition() throws {
        let result = try resolve(
            [:], project: ["SDKROOT": "$(SDK_CHOICE)", "SDK_CHOICE": "$(SDK_CHOICE:lower)"],
            file: "SDK_CHOICE = macosx\nVALUE[sdk=macosx99.*] = selected\n")
        XCTAssertEqual(result["VALUE"] as? String, "selected")
    }

    func testPreliminarySDKResolutionWaitsForConditionalDefinitions() throws {
        let result = try resolve([
            "SDKROOT": "$(SDK_CHOICE)", "SDK_CHOICE": "$(SDK_CHOICE)", "SDK_CHOICE[config=Debug]": "macosx",
            "VALUE[sdk=macosx99.*]": "selected",
        ])
        XCTAssertEqual(result["VALUE"] as? String, "selected")
    }

    func testAnonymousFileExpressionsCannotReadAnInternalSyntheticBinding() throws {
        let (graph, _) = try fixture()
        for name in [".SwiftPods.xcconfig.reference.", "$(PREFIX)$(SUFFIX)"] {
            let ref = graph.add(
                name,
                [
                    "isa": "PBXFileReference", "path": "$(\(name):default=$(PROJECT_DIR))/Configs/Debug.xcconfig",
                    "sourceTree": "<absolute>",
                ])
            let path = try NativeBuildSettings.file(
                ref, graph: graph, variables: ["PREFIX": ".SwiftPods.xcconfig", "SUFFIX": ".reference."])
            XCTAssertEqual(path.path, graph.sourceRoot.appendingPathComponent("Configs/Debug.xcconfig").path)
        }
    }

    func testSDKRootCannotContainNulAfterEvaluation() throws {
        for settings in [
            ["SDKROOT": "macosx\0ignored"], ["SDKROOT": "$(SDK_CHOICE)", "SDK_CHOICE": "macosx\0ignored"],
        ] {
            XCTAssertThrowsError(try resolve(settings)) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCCONFIG-PATH")
            }
        }
    }

    func testUnresolvedSDKPrefixesCannotSupplyAPlatformHint() {
        let context = NativeSDKContext(locate: { _, _ in nil })
        for raw in [
            "macosx$(MISSING)/Custom.sdk", "iphoneos${MISSING}/Custom.sdk", "macosx$MISSING/Custom.sdk",
            "macosx\0ignored", "macosx\"ignored",
        ] {
            XCTAssertEqual(context.name(raw), "", raw)
        }
        XCTAssertEqual(context.name("/SDKs/MacOSX99.4.sdk"), "macosx99.4")
    }
    func testUnknownShortReferencesRemainLiteralForSDKSelection() throws {
        for raw in ["$MISSING", "macosx$MISSING"] {
            let result = try resolve(["SDKROOT": raw, "WRONG[sdk=macosx*]": "wrong"])
            XCTAssertNil(result["WRONG"])
            XCTAssertEqual(result["SDKROOT"] as? String, raw)
        }
        let known = try resolve(["SDKROOT": "$SDK_CHOICE", "SDK_CHOICE": "macosx", "VALUE[sdk=macosx99.*]": "selected"])
        XCTAssertEqual(known["VALUE"] as? String, "selected")
    }

    func testStandaloneConfigurationParsingUsesTheGlobalSDKPriorAssignment() throws {
        let (graph, _) = try fixture()
        let file = graph.sourceRoot.appendingPathComponent("Standalone.xcconfig")
        try Data("SDKROOT = $(SDK_CHOICE)\nSDK_CHOICE = $(SDKROOT)\nSENTINEL = 17\n".utf8).write(to: file)
        var inputs = Set<String>()
        let values = try NativeBuildSettings.xcconfig(file, inputs: &inputs)
        XCTAssertEqual(values["SENTINEL"] as? String, "17")
        XCTAssertEqual(values["SDKROOT"] as? String, "$(SDK_CHOICE)")
    }

    func testBaseFileSDKGuessWaitsForDirectConditionalDefinitions() throws {
        let result = try resolve(
            ["SDKROOT": "$(SDK_CHOICE)", "SDK_CHOICE": "$(SDK_CHOICE)", "SDK_CHOICE[config=*]": "macosx"],
            file: "VALUE[sdk=macosx99.*] = selected\n")
        XCTAssertEqual(result["VALUE"] as? String, "selected")
    }

}
