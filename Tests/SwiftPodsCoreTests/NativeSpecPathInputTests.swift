import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeSpecPathInputTests: XCTestCase {
    func testNulFileAndPatternAttributesAreRejectedDuringSchemaValidation() {
        for key in [
            "source_files", "exclude_files", "resources", "preserve_paths", "public_header_files",
            "private_header_files", "project_header_files", "vendored_frameworks", "vendored_libraries",
            "header_dir", "header_mappings_dir", "prefix_header_file", "module_map", "readme", "requires_arc",
        ] {
            XCTAssertThrowsError(try NativeSpec(data: ["name": "Kit", "version": "1.0", key: "Path\0Suffix"]), key) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-SPEC-PATH")
            }
        }
        XCTAssertThrowsError(
            try NativeSpec(data: ["name": "Kit", "version": "1.0", "source_files": ["*.c", "Headers\0Suffix"]]))
    }

    func testStructuredResourcePathsAndProductNamesRejectNul() {
        for attributes: [String: Any] in [
            ["resource_bundles": ["Own": ["Assets\0Suffix"]]],
            ["resource_bundles": ["Own\0Suffix": ["Assets"]]],
            ["on_demand_resources": ["tag": ["paths": ["Assets\0Suffix"]]]],
            ["license": ["type": "MIT", "file": "LICENSE\0Suffix"]],
        ] {
            XCTAssertThrowsError(
                try NativeSpec(data: ["name": "Kit", "version": "1.0"].merging(attributes) { _, new in new })
            ) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-SPEC-PATH")
            }
        }
    }

    func testPrepareCommandCannotSilentlyExecuteOnlyItsPrefix() {
        XCTAssertThrowsError(
            try NativeSpec(data: ["name": "Kit", "version": "1.0", "prepare_command": "printf before\0printf after"])
        ) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-SPEC-SCRIPT")
        }
    }

    func testScriptPhasePathsRejectCrlfAsWellAsIndividualLineBreaks() {
        for key in ["input_files", "output_files", "input_file_lists", "output_file_lists"] {
            XCTAssertThrowsError(
                try NativeScriptPhase(["name": "Phase", "script": "true", key: ["Path\r\nSuffix"]]), key
            ) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-SCRIPT-SCHEMA")
            }
        }
    }

    func testUnicodePathsAndOptionalBooleanValuesRemainValid() throws {
        _ = try NativeSpec(data: [
            "name": "Kit", "version": "1.0", "source_files": ["\u{301}Folder/*.c"],
            "module_map": false, "prefix_header_file": false, "requires_arc": true,
            "resource_bundles": ["Own": ["Assets/\u{301}payload.txt"]],
        ])
    }
}
