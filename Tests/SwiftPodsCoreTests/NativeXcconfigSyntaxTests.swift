import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeXcconfigSyntaxTests: XCTestCase {
    private func directory(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for (name, text) in files {
            let path = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: path)
        }
        return root
    }

    private func read(_ text: String, files: [String: String] = [:]) throws -> [String: Any] {
        let root = try directory(files.merging(["Root.xcconfig": text]) { _, new in new })
        var inputs = Set<String>()
        return try NativeBuildSettings.xcconfig(
            root.appendingPathComponent("Root.xcconfig"), context: ["sdk": "macosx", "config": "Debug"], inputs: &inputs
        )
    }

    func testWhitespaceBeforeAndBetweenConditionsIsAccepted() throws {
        for key in ["VALUE [sdk=macosx*]", "VALUE\t[sdk=macosx*]", "VALUE[sdk=macosx*] [config=Debug]"] {
            XCTAssertEqual(try read(key + " = selected\n")["VALUE"] as? String, "selected", key)
        }
    }

    func testSpacedConsumerFlagKeysPreserveBothPodsAndExplicitOverrides() {
        for key in ["OTHER_CFLAGS[sdk=macosx*]", "OTHER_CFLAGS [sdk=macosx*]"] {
            let merged = NativeBuildSettings.addingConsumerSettings(
                [key: "$(inherited) -DSECOND=1"], to: [key: "-DFIRST=1"], original: [:])
            XCTAssertEqual(merged[key] as? String, "-DFIRST=1 -DSECOND=1", key)
            let overridden = NativeBuildSettings.addingConsumerSettings(
                [key: "-DSECOND=1"], to: [key: "-DUSER=1"], original: [key: "-DUSER=1"])
            XCTAssertEqual(overridden[key] as? String, "-DUSER=1", key)
        }
    }

    func testConditionMembersKeepLiteralWhitespaceAndUnknownAxesDoNotApply() throws {
        for condition in ["[sdk =macosx*]", "[sdk= macosx*]", "[flavor=vanilla]", "[sdk=]"] {
            XCTAssertNil(try read("VALUE" + condition + " = selected\n")["VALUE"], condition)
        }
    }

    func testConditionsDoNotTruncatePatternsOrContextsAtNUL() throws {
        let key = "VALUE[sdk=macosx\0wrong]"
        XCTAssertFalse(NativeBuildSettings.conditions(key, context: ["sdk": "macosx"]).1)
        XCTAssertFalse(NativeBuildSettings.conditions("VALUE[sdk=macosx]", context: ["sdk": "macosx\0wrong"]).1)
        XCTAssertNil(try read(key + " = wrong\n")["VALUE"])
    }

    func testAllConditionsMustApply() throws {
        let settings = try read(
            "VALUE [sdk=macosx*] [config=Release] = wrong\nVALUE [sdk=macosx*] [config=Debug] = selected\n")
        XCTAssertEqual(settings["VALUE"] as? String, "selected")
    }

    func testMalformedConditionsReportTheirFileAndLine() throws {
        for key in ["VALUE[sdk=macosx*][bad]", "VALUE[=macosx*]"] {
            XCTAssertThrowsError(try read("// first line\n" + key + " = selected\n")) {
                let diagnostic = $0 as? Diagnostic
                XCTAssertEqual(diagnostic?.code, "SP-XCCONFIG-SYNTAX")
                XCTAssertEqual(diagnostic?.line, 2)
                XCTAssertTrue(diagnostic?.file?.hasSuffix("/Root.xcconfig") == true)
            }
        }
    }

    func testMalformedDirectKeysCannotPartiallyMatch() {
        for key in ["VALUE[sdk=macosx*][bad]", "VALUE[sdk=macosx*]trailing", "VALUE[=macosx*]"] {
            XCTAssertFalse(NativeBuildSettings.conditions(key, context: ["sdk": "macosx"]).1, key)
        }
    }

    func testIncludeAllowsWhitespaceAfterHashAndOptionalIncludes() throws {
        for directive in ["# include", "#\tinclude", "# include?"] {
            let values = try read(
                directive + " \"Child.xcconfig\" // \"comment\"\n", files: ["Child.xcconfig": "VALUE = selected\n"])
            XCTAssertEqual(values["VALUE"] as? String, "selected", directive)
        }
        XCTAssertEqual(try read("# include? \"Missing.xcconfig\"\nVALUE = selected\n")["VALUE"] as? String, "selected")
    }

    func testInvalidIncludeTokensAreRejected() throws {
        for directive in [
            "#included \"Child.xcconfig\"", "#include unexpected \"Child.xcconfig\"",
            "#include \"Child.xcconfig\" trailing", "#include ? \"Child.xcconfig\"",
        ] {
            XCTAssertThrowsError(try read(directive + "\n", files: ["Child.xcconfig": "VALUE = selected\n"])) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCCONFIG-INCLUDE")
                XCTAssertEqual(($0 as? Diagnostic)?.line, 1)
            }
        }
    }

    func testNestedInvalidIncludeReportsTheOriginalLocation() throws {
        XCTAssertThrowsError(
            try read(
                "#include \"Child.xcconfig\"\n",
                files: [
                    "Child.xcconfig": "// first line\n#include \"Leaf.xcconfig\" trailing\n",
                    "Leaf.xcconfig": "VALUE = selected\n",
                ])
        ) {
            let diagnostic = $0 as? Diagnostic
            XCTAssertEqual(diagnostic?.code, "SP-XCCONFIG-INCLUDE")
            XCTAssertEqual(diagnostic?.line, 2)
            XCTAssertTrue(diagnostic?.file?.hasSuffix("/Child.xcconfig") == true)
        }
    }

    func testIncludePathsPreserveLiteralVariableSyntax() throws {
        for token in ["$(DIR)", "${DIR}"] {
            let values = try read(
                "DIR = Expanded\n#include \"" + token + "/Leaf.xcconfig\"\n",
                files: [token + "/Leaf.xcconfig": "VALUE = literal\n", "Expanded/Leaf.xcconfig": "VALUE = expanded\n"])
            XCTAssertEqual(values["VALUE"] as? String, "literal", token)
        }
    }

    func testOptionalLiteralIncludeDoesNotSelectAnExpandedFile() throws {
        let values = try read(
            "DIR = Expanded\n#include? \"$(DIR)/Leaf.xcconfig\"\n", files: ["Expanded/Leaf.xcconfig": "VALUE = wrong\n"]
        )
        XCTAssertNil(values["VALUE"])
    }

    func testProjectRootMacrosRemainLiteralInIncludePaths() throws {
        let root = try directory([
            "Configs/Root.xcconfig": "SDKROOT = macosx\n#include \"$(SRCROOT)/Leaf.xcconfig\"\n",
            "Configs/$(SRCROOT)/Leaf.xcconfig": "VALUE = literal\n", "Leaf.xcconfig": "VALUE = expanded\n",
        ])
        let graph = try NativePBX(root.appendingPathComponent("App.xcodeproj/project.pbxproj"))
        graph.objects["FILE"] = [
            "isa": "PBXFileReference", "path": root.appendingPathComponent("Configs/Root.xcconfig").path,
            "sourceTree": "<absolute>",
        ]
        let configuration: [String: Any] = [
            "name": "Debug", "baseConfigurationReference": "FILE", "buildSettings": [:],
        ]
        XCTAssertEqual(try NativeBuildSettings.resolved(configuration, graph: graph)["VALUE"] as? String, "literal")
    }

    func testSpecConditionalKeysAreValidatedBeforeIntegration() throws {
        for attribute in ["xcconfig", "pod_target_xcconfig", "user_target_xcconfig"] {
            for key in ["FLAGS[sdk=macosx*][bad]", "FLAGS[=macosx*]"] {
                XCTAssertThrowsError(
                    try NativeSpec(data: ["name": "Kit", "version": "1.0", attribute: [key: "selected"]])
                ) {
                    XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCCONFIG-KEY")
                }
            }
        }
    }
}
