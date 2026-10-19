import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeXcconfigValueTests: XCTestCase {
    private func read(_ text: String) throws -> [String: Any] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("Settings.xcconfig")
        try Data(text.utf8).write(to: path)
        var inputs = Set<String>()
        return try NativeBuildSettings.xcconfig(path, inputs: &inputs)
    }

    private func included(_ files: [String: String]) throws -> [String: Any] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for (name, text) in files { try Data(text.utf8).write(to: root.appendingPathComponent(name)) }
        var inputs = Set<String>()
        return try NativeBuildSettings.xcconfig(root.appendingPathComponent("Root.xcconfig"), inputs: &inputs)
    }

    func testNonXcodeAssignmentOperatorsAreRejected() throws {
        for operation in ["+=", "?="] {
            XCTAssertThrowsError(try read("VALUE = parent\nVALUE \(operation) child\n")) { error in
                XCTAssertEqual((error as? Diagnostic)?.code, "SP-XCCONFIG-SYNTAX")
                XCTAssertEqual((error as? Diagnostic)?.line, 2)
            }
        }
    }

    func testAssignmentOperatorsInsideValuesRemainLiteral() throws {
        XCTAssertEqual(try read("VALUE = literal += text ?= tail\n")["VALUE"] as? String, "literal += text ?= tail")
    }

    func testInvalidIncludedAssignmentReportsTheOriginalFileAndLine() throws {
        for operation in ["+=", "?="] {
            XCTAssertThrowsError(
                try included([
                    "Root.xcconfig": "#include \"Child.xcconfig\"\n",
                    "Child.xcconfig": "// Child\nVALUE \(operation) child\n",
                ])
            ) { error in
                let diagnostic = error as? Diagnostic
                XCTAssertEqual(diagnostic?.code, "SP-XCCONFIG-SYNTAX")
                XCTAssertEqual(diagnostic?.line, 2)
                XCTAssertTrue(diagnostic?.file?.hasSuffix("/Child.xcconfig") == true)
            }
        }
    }

    func testRepeatedIncludesKeepValidInheritanceOrdered() throws {
        let settings = try included([
            "Root.xcconfig":
                "FLAGS = base\n#include \"Child.xcconfig\"\n#include \"Child.xcconfig\"\nFLAGS = $(inherited) final\n",
            "Child.xcconfig": "FLAGS = $(inherited) child\n",
        ])
        XCTAssertEqual(settings["FLAGS"] as? String, "base child child final")
    }

    func testRecursivePathPatternsRemainLiteralValues() throws {
        let paths = "/root/**/*.h /root/**/Headers"
        XCTAssertEqual(try read("PATTERNS = \(paths)\n")["PATTERNS"] as? String, paths)
    }

    func testInlineBlockMarkersArePartOfTheValue() throws {
        XCTAssertEqual(try read("VALUE = x/* kept */y\n")["VALUE"] as? String, "x/* kept */y")
    }

    func testQuotedValuesRemainQuoted() throws {
        XCTAssertEqual(try read("VALUE = \"hello world\" // comment\n")["VALUE"] as? String, "\"hello world\"")
        XCTAssertEqual(try read("SDKROOT = \"macosx\"\n")["SDKROOT"] as? String, "\"macosx\"")
    }

    func testBlockMarkersInLineCommentsCannotConsumeAssignments() throws {
        let settings = try read("// Document /* literally\nVALUE = selected\n// Close */ literally\n")
        XCTAssertEqual(settings["VALUE"] as? String, "selected")
    }

    func testLiteralBlockMarkersDoNotChangeDiagnosticLineNumbers() throws {
        XCTAssertThrowsError(try read("FIRST = /root/*\nSECOND = */value\ninvalid line\n")) { error in
            let diagnostic = error as? Diagnostic
            XCTAssertEqual(diagnostic?.code, "SP-XCCONFIG-SYNTAX")
            XCTAssertEqual(diagnostic?.line, 3)
        }
    }

    func testUnsupportedFullLineBlockCommentsAreRejected() throws {
        for comment in ["/* Header */", "/* Header\n * line two\n */", "/* Unterminated"] {
            XCTAssertThrowsError(try read("VALUE = selected\n\(comment)\n")) { error in
                XCTAssertEqual((error as? Diagnostic)?.code, "SP-XCCONFIG-SYNTAX")
                XCTAssertEqual((error as? Diagnostic)?.line, 2)
            }
        }
    }

    func testLineCommentsKeepTheirExistingMeaningInsideQuotes() throws {
        XCTAssertEqual(try read("VALUE = \"https://example.invalid\"\n")["VALUE"] as? String, "\"https:")
    }

    func testLiteralBlockMarkersCannotConsumeTheNextAssignment() throws {
        let settings = try read("FIRST = /root/*\nSECOND = */value\n")
        XCTAssertEqual(settings["FIRST"] as? String, "/root/*")
        XCTAssertEqual(settings["SECOND"] as? String, "*/value")
    }

    func testContinuationsKeepPhysicalDiagnosticLineNumbers() throws {
        for newline in ["\n", "\r\n"] {
            let text = "FLAGS = FIRST \\" + newline + " SECOND" + newline + "invalid line" + newline
            XCTAssertThrowsError(try read(text)) { error in
                XCTAssertEqual((error as? Diagnostic)?.code, "SP-XCCONFIG-SYNTAX")
                XCTAssertEqual((error as? Diagnostic)?.line, 3)
            }
        }
    }
}
