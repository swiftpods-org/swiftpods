import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeHeaderPathBoundaryTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/fixture/Kit", isDirectory: true)

    func testHeaderDirectoriesRejectAbsoluteAndTraversalBoundariesBeforeMarks() {
        for value in ["/Headers", "/\u{301}Headers", "../Headers", "../\u{301}Headers", "Folder/../\u{301}Headers"] {
            XCTAssertThrowsError(try NativeFileRules.headerDirectory(["header_dir": value], module: "Kit"), value) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-SPEC-HEADER-MAPPING")
            }
        }
    }

    func testHeaderMappingsRejectInvalidBoundariesEvenWhenTheFileMatches() {
        for mapping in ["/\u{301}Headers", "../\u{301}Headers", "Folder/../\u{301}Headers"] {
            let file = root.appendingPathComponent(mapping).appendingPathComponent("Kit.h")
            XCTAssertThrowsError(
                try NativeFileRules.headerPath(file, attributes: ["header_mappings_dir": mapping], root: root), mapping
            ) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-SPEC-HEADER-MAPPING")
            }
        }
    }

    func testRelativeHeaderDirectoriesKeepUnicodeAndLiteralDotNames() throws {
        for value in ["\u{301}Headers", "Folder/\u{301}Headers", "..\u{301}Headers"] {
            XCTAssertEqual(try NativeFileRules.headerDirectory(["header_dir": value], module: "Kit"), value)
        }
    }

    func testRelativeHeaderMappingsPreserveTheCompleteSuffix() throws {
        for mapping in ["\u{301}Headers", "Folder/\u{301}Headers"] {
            let file = root.appendingPathComponent(mapping).appendingPathComponent("\u{301}Nested/Kit.h")
            XCTAssertEqual(
                try NativeFileRules.headerPath(file, attributes: ["header_mappings_dir": mapping], root: root),
                "\u{301}Nested/Kit.h")
        }
    }
}
