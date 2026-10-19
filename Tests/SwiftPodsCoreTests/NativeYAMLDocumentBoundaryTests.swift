import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeYAMLDocumentBoundaryTests: XCTestCase {
    private func value(_ text: String) throws -> Any {
        let parsed = try NativeYAML.object("VALUE: " + text + "\n")
        return try XCTUnwrap(parsed["VALUE"])
    }

    func testInlineCommentsFollowQuotedStringsAndCollections() throws {
        for text in ["'kept' # comment", "\"kept\"\t# comment"] {
            XCTAssertEqual(try value(text) as? String, "kept")
        }
        XCTAssertEqual(try value("[first, second] # comment") as? [String], ["first", "second"])
        XCTAssertEqual(try value("{field: kept} # comment") as? [String: String], ["field": "kept"])
        XCTAssertEqual(try value("'hash # kept' # removed") as? String, "hash # kept")
    }

    func testCommentOnlyValueCanHaveAnIndentedChild() throws {
        let parsed = try NativeYAML.object("VALUE: # comment\n  field: kept\n")
        XCTAssertEqual(parsed["VALUE"] as? [String: String], ["field": "kept"])
    }

    func testQuotesInsidePlainFlowValuesDoNotConsumeSeparators() throws {
        XCTAssertEqual(try value("[Bob's, next]") as? [String], ["Bob's", "next"])
        XCTAssertEqual(try value("[a\"b, next]") as? [String], ["a\"b", "next"])
    }

    func testFlowMappingsAcceptQuotedKeysWithoutWhitespace() throws {
        for text in ["{\"field\":\"kept\"}", "{'field':kept}"] {
            XCTAssertEqual(try value(text) as? [String: String], ["field": "kept"])
        }
    }

    func testFlowTrailingCommasAndImplicitNullEntriesKeepTheirMeaning() throws {
        XCTAssertEqual(try value("[one,]") as? [String], ["one"])
        XCTAssertEqual(try value("{field: kept,}") as? [String: String], ["field": "kept"])
        let nulls = try XCTUnwrap(value("{field, other, field:kept}") as? [String: Any])
        XCTAssertEqual(Set(nulls.keys), ["field", "other", "field:kept"])
        XCTAssertTrue(nulls.values.allSatisfy { $0 is NSNull })
    }

    func testFlowSequencePairsRemainMappings() throws {
        XCTAssertEqual(
            try value("[field: kept, other: next]") as? [[String: String]],
            [["field": "kept"], ["other": "next"]])
    }

    func testMalformedQuotesAndFlowDelimitersReportTheirSourceLine() {
        for text in ["'first'junk'", "[first], last]", "{field: first], other: kept}", "[[one}, two]", "[one,,two]"] {
            XCTAssertThrowsError(
                try NativeYAML.object("GOOD: kept\nBAD: " + text + "\nTAIL: kept\n", file: "fixture.lock")
            ) {
                let diagnostic = $0 as? Diagnostic
                XCTAssertEqual(diagnostic?.code, "SP-LOCK-YAML", text)
                XCTAssertEqual(diagnostic?.file, "fixture.lock", text)
                XCTAssertEqual(diagnostic?.line, 2, text)
            }
        }
    }

    func testDocumentMarkersCannotMergeSeparateDocuments() throws {
        XCTAssertEqual(try NativeYAML.object("--- # start\nVALUE: kept\n... # end\n")["VALUE"] as? String, "kept")
        for separator in ["---", "..."] {
            XCTAssertThrowsError(try NativeYAML.object("VALUE: first\n" + separator + "\nOTHER: second\n")) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-LOCK-YAML")
            }
        }
    }

    func testEmptyBlockScalarsAreEmptyStrings() throws {
        for text in ["|", "|-", "|+", ">", ">-", ">+"] { XCTAssertEqual(try value(text) as? String, "", text) }
    }

    func testLiteralAndFoldedBlockScalarsPreserveContentAndChomping() throws {
        for (yaml, expected) in [
            ("VALUE: |\n  first\n  second\n", "first\nsecond\n"),
            ("VALUE: >-\n  first\n  second\n", "first second"),
            ("VALUE: |+\n  first\n\n", "first\n\n"),
            ("VALUE: >\n  first\n\n  second\n", "first\nsecond\n"),
            ("VALUE: |2-\n  first\n    indented\n", "first\n  indented"),
        ] { XCTAssertEqual(try NativeYAML.object(yaml)["VALUE"] as? String, expected) }
    }

    func testMultilineQuotedValuesUseYAMLFolding() throws {
        for quote in ["'", "\""] {
            XCTAssertEqual(
                try NativeYAML.object("VALUE: " + quote + "first\n  last" + quote + "\n")["VALUE"] as? String,
                "first last")
            XCTAssertEqual(
                try NativeYAML.object("VALUE: " + quote + "first\n\n  last" + quote + "\n")["VALUE"] as? String,
                "first\nlast")
        }
        XCTAssertEqual(try NativeYAML.object("VALUE: \"first\u{85}last\"\n")["VALUE"] as? String, "first last")
    }

    func testUnicodeLineSeparatorsInsideQuotedValuesRemainData() throws {
        for scalar in ["\u{2028}", "\u{2029}"] {
            let expected = "first" + scalar + "last"
            XCTAssertEqual(try jsonData(["VALUE": value("\"" + expected + "\"")]), try jsonData(["VALUE": expected]))
        }
    }

    func testPlainNumericAndBooleanTypesMatchLockfileYAML() throws {
        let parsed = try NativeYAML.object(
            "INTEGER: 42\nNEGATIVE: -9\nLARGE: 9223372036854775807\nFLOAT: 1.5\nINTEGRAL: 1.0\nEXPONENT: 1.5e+20\nOCTAL: 012\nHEX: 0xFF\nBINARY: 0b1010\nSEPARATOR: 1_000\n'YES': yes\n'NO': no\n'ON': On\n'OFF': OFF\n"
        )
        let expected: [String: Any] = [
            "INTEGER": 42, "NEGATIVE": -9, "LARGE": Int64.max, "FLOAT": 1.5, "INTEGRAL": 1.0, "EXPONENT": 1.5e20,
            "OCTAL": 10, "HEX": 255, "BINARY": 10, "SEPARATOR": 1000, "YES": true, "NO": false, "ON": true,
            "OFF": false,
        ]
        XCTAssertEqual(try jsonData(parsed), try jsonData(expected))
    }

    func testLockQuotesEscapeApostrophesAtScalarBoundaries() throws {
        let text = "Kit'\u{301}s"
        XCTAssertEqual(NativeLock.quote(text).unicodeScalars.filter { $0 == "'" }.count, 4)
        XCTAssertEqual(try value(NativeLock.quote(text)) as? String, text)
    }

    func testLockQuotesRoundTripControlsWithoutLiteralLineBreaks() throws {
        for text in [
            "first\nlast", "first\rlast", "first\u{85}last", "first\u{2028}last", "first\u{2029}last", "first\0last",
        ] {
            let quoted = NativeLock.quote(text)
            XCTAssertFalse(quoted.unicodeScalars.contains { CharacterSet.newlines.contains($0) })
            XCTAssertEqual(try jsonData(["VALUE": value(quoted)]), try jsonData(["VALUE": text]))
        }
    }

    func testEncodedNestedValuesKeepScalarTypesAndUnicodeBytes() throws {
        let data: [String: Any] = [
            "\u{301}Key": ["line\u{2028}tail", "line\u{85}tail", "Kit'\u{301}s", 42, 1.0, true, NSNull()] as [Any]
        ]
        XCTAssertEqual(try jsonData(NativeYAML.object(NativeYAML.encode(data))), try jsonData(data))
    }

    func testIndentlessSequencesAndSequenceMappingEntriesKeepTheirShape() throws {
        let data = try NativeYAML.object("VALUE:\n- first: kept\n  other: next\n- first: last\nTAIL: kept\n")
        XCTAssertEqual(data["VALUE"] as? [[String: String]], [["first": "kept", "other": "next"], ["first": "last"]])
        XCTAssertEqual(data["TAIL"] as? String, "kept")
    }

    func testNonbreakingSpacesAreDataRatherThanIndentation() throws {
        XCTAssertEqual(try value("\u{a0}kept\u{a0}") as? String, "\u{a0}kept\u{a0}")
        XCTAssertEqual(try NativeYAML.object("\u{a0}KEY: kept\n")["\u{a0}KEY"] as? String, "kept")
    }

    func testExcessiveBlockNestingHasABoundedDiagnostic() throws {
        let rows = (0...520).map { String(repeating: " ", count: $0 * 2) + "KEY:" }.joined(separator: "\n")
        XCTAssertThrowsError(try NativeYAML.object(rows + "\n")) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-LOCK-YAML")
        }
    }

    func testInvalidEscapesAndRawControlCharactersAreRejected() {
        for text in [
            #""\u+123""#, #""\x-G""#, #""\uD83D\u+123""#, #""\U00110000""#, "'before\0after'", "before\u{7}after",
        ] {
            XCTAssertThrowsError(try value(text), text) { XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-LOCK-YAML") }
        }
    }

    func testPlainMultilineScalarsUseFolding() throws {
        for (yaml, expected) in [
            ("VALUE: first\n  last\n", "first last"),
            ("VALUE: first\n\n  last\n", "first\nlast"),
            ("VALUE: first\n  - last\n", "first - last"),
        ] { XCTAssertEqual(try NativeYAML.object(yaml)["VALUE"] as? String, expected) }
    }

    func testMultilineFlowEscapesAndCommentsPreserveValues() throws {
        XCTAssertEqual(try NativeYAML.object("VALUE: [\"first\\\n  last\"]\n")["VALUE"] as? [String], ["firstlast"])
        XCTAssertEqual(
            try NativeYAML.object("VALUE: [first, # comment\n  second]\n")["VALUE"] as? [String], ["first", "second"])
    }

    func testEmptyFlowValuesRequireASeparatedOrQuotedKey() throws {
        for text in ["{a: }", "{'a':}", "{'a':,}"] {
            let map = try XCTUnwrap(value(text) as? [String: Any])
            XCTAssertTrue(map["a"] is NSNull)
        }
        for text in ["{a:}", "{a:,}", "[a:]", "[a:,]", "- item", "? key", #""\uD83D\uDE00""#] {
            XCTAssertThrowsError(try value(text), text) { XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-LOCK-YAML") }
        }
        XCTAssertEqual(try value("'😀'") as? String, "😀")
    }

    func testSexagesimalNumbersMatchThePinnedReferenceScanner() throws {
        XCTAssertEqual((try value("1:23") as? NSNumber)?.intValue, 4980)
        XCTAssertEqual((try value("1:23:45") as? NSNumber)?.intValue, 5025)
        XCTAssertEqual((try value("1:23.5") as? NSNumber)?.doubleValue, 5010)
    }

    func testNumbersNeverSilentlyLoseIntegerPrecisionOrBecomeNonfinite() throws {
        let text = "18446744073709551616"
        XCTAssertEqual((try value(text) as? NSDecimalNumber)?.stringValue, text)
        for text in ["12345678901234567890123456789012345678901234567890", "1.0e+999", ".inf", ".nan"] {
            XCTAssertThrowsError(try value(text), text) { XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-LOCK-YAML") }
        }
    }

    func testYAMLEncoderCannotCollapseEquivalentFoundationKeys() throws {
        let bytes = Data(#"{"META":{"CAF\u00c9":"first","CAFE\u0301":"second"}}"#.utf8)
        let value = try JSONSerialization.jsonObject(with: bytes)
        XCTAssertThrowsError(try NativeYAML.encode(value)) { XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-DATA-KEY") }
        XCTAssertEqual(
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
            try JSONSerialization.data(
                withJSONObject: JSONSerialization.jsonObject(with: bytes), options: [.sortedKeys]))
    }
}
