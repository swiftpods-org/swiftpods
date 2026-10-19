import XCTest

@testable import SwiftPodsCore

final class CommandOptionsTests: XCTestCase {
    func testSplitValueCannotConsumeLongOption() {
        assertMissingValue("--offline")
    }

    func testSplitValueCannotConsumeShortOption() {
        assertMissingValue("-h")
    }

    func testSplitValueCannotConsumeOptionTerminator() {
        assertMissingValue("--")
    }

    func testCombiningMarksCannotHideAnOptionPrefix() {
        assertMissingValue("-\u{301}option")
    }

    func testMissingTrailingValueIsRejected() {
        var arguments = ["install", "--project-directory"]
        XCTAssertThrowsError(try CommandOptions.take("--project-directory", from: &arguments)) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-CLI-ARGUMENT")
        }
    }

    func testEmptyValuesAreRejectedInBothForms() {
        for input in [["--directory", ""], ["--directory="]] {
            var arguments = input
            XCTAssertThrowsError(try CommandOptions.take("--directory", from: &arguments)) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-CLI-ARGUMENT")
            }
        }
    }

    func testDuplicateValuesAreRejectedInBothOrders() {
        for input in [
            ["--directory=one", "--directory", "two"],
            ["--directory", "one", "--directory=two"],
        ] {
            var arguments = input
            XCTAssertThrowsError(try CommandOptions.take("--directory", from: &arguments)) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-CLI-ARGUMENT")
            }
        }
    }

    func testInlineValuesCanBeginWithHyphens() throws {
        for value in ["--offline", "-h", "--", "-\u{301}directory"] {
            var arguments = ["env", "shim", "--directory=" + value]
            XCTAssertEqual(try CommandOptions.take("--directory", from: &arguments), value)
            XCTAssertEqual(arguments, ["env", "shim"])
        }
    }

    func testRelativePathsCanBeginWithHyphens() throws {
        var arguments = ["--directory", "./--offline", "--json"]
        XCTAssertEqual(try CommandOptions.take("--directory", from: &arguments), "./--offline")
        XCTAssertEqual(arguments, ["--json"])
    }

    func testSingleHyphenRemainsAValue() throws {
        var arguments = ["--directory", "-"]
        XCTAssertEqual(try CommandOptions.take("--directory", from: &arguments), "-")
        XCTAssertTrue(arguments.isEmpty)
    }

    func testSplitValuesPreserveWhitespaceAndUnicode() throws {
        for value in ["a path", "\u{301}directory", "a=b", "−directory"] {
            var arguments = ["env", "--directory", value, "--json"]
            XCTAssertEqual(try CommandOptions.take("--directory", from: &arguments), value)
            XCTAssertEqual(arguments, ["env", "--json"])
        }
    }

    func testAbsentOptionPreservesArguments() throws {
        var arguments = ["env", "--directory-extra=one", "--json"]
        let original = arguments
        XCTAssertNil(try CommandOptions.take("--directory", from: &arguments))
        XCTAssertEqual(arguments, original)
    }

    private func assertMissingValue(_ next: String, file: StaticString = #filePath, line: UInt = #line) {
        var arguments = ["env", "shim", "--directory", next]
        XCTAssertThrowsError(try CommandOptions.take("--directory", from: &arguments), file: file, line: line) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-CLI-ARGUMENT", file: file, line: line)
            XCTAssertEqual(($0 as? Diagnostic)?.message, "Missing value for --directory", file: file, line: line)
        }
    }
}
