import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeYAMLScalarBoundaryTests: XCTestCase {
    func testIndentationAndMappingValuesPreserveLeadingCombiningMarks() throws {
        let data = try NativeYAML.object(
            "EXTERNAL SOURCES:\n  \u{301}Kit:\n    :path: ./Kit\nVALUES:\n  field: \u{301}value\n")
        let sources = try XCTUnwrap(data["EXTERNAL SOURCES"] as? [String: [String: String]])
        XCTAssertEqual(sources["\u{301}Kit"]?[":path"], "./Kit")
        XCTAssertEqual((data["VALUES"] as? [String: String])?["field"], "\u{301}value")
    }

    func testSequenceAndFlowSeparatorsAreScalarBoundaries() throws {
        let data = try NativeYAML.object(
            "VALUES:\n  - \u{301}one\n  - [\u{301}two, \u{301}three]\nMAP: {plain: \u{301}value, \u{301}key: tail}\n")
        let values = try XCTUnwrap(data["VALUES"] as? [Any])
        XCTAssertEqual(values.first as? String, "\u{301}one")
        XCTAssertEqual(values.last as? [String], ["\u{301}two", "\u{301}three"])
        XCTAssertEqual(data["MAP"] as? [String: String], ["plain": "\u{301}value", "\u{301}key": "tail"])
    }

    func testQuotesKeepMarksImmediatelyAfterTheirOpeningDelimiter() throws {
        let data = try NativeYAML.object("VALUES:\n  '\u{301}Key': \"\u{301}Value\"\n  escaped: '\u{301}key''s'\n")
        XCTAssertEqual(data["VALUES"] as? [String: String], ["\u{301}Key": "\u{301}Value", "escaped": "\u{301}key's"])
    }

    func testCommentsAndRejectedTagsDoNotDependOnGraphemeBoundaries() throws {
        XCTAssertEqual(try NativeYAML.object("VALUE: before #\u{301}comment\n")["VALUE"] as? String, "before")
        for token in ["!", "&", "*"] {
            XCTAssertThrowsError(try NativeYAML.object("VALUE: " + token + "\u{301}tag\n")) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-LOCK-YAML")
            }
        }
    }

    func testEncodedNestedUnicodeDataRoundTripsWithoutNormalization() throws {
        let original: [String: Any] = ["\u{301}Key": ["\u{301}Value", "\u{301}Next", ["\u{301}Nested": "&safe"]]]
        let text = try NativeYAML.encode(original)
        let decoded = try NativeYAML.object(text)
        XCTAssertEqual(try jsonData(decoded), try jsonData(original))
    }
}
