import XCTest

@testable import SwiftPodsCore

final class NativeValidationDiagnosticsTests: XCTestCase {
    func testOnlyTheOptionalAppIntentsSkipMessageBecomesANote() {
        let note = "2026-10-23 12:47:04.128 appintentsmetadataprocessor[12:34] warning: Metadata extraction skipped, no AppIntents.framework dependency found"
        let source = "Kit.swift:2:1: warning: Metadata extraction skipped, no AppIntents.framework dependency found"
        let metadata = "appintentsmetadataprocessor[12:34] warning: Invalid AppShortcut parameter"
        let compiler = "clang: warning: unused variable 'value'"
        let result = NativeValidation.diagnostics(in: [note, source, metadata, compiler].joined(separator: "\n"))
        XCTAssertEqual(result.notes, [note])
        XCTAssertEqual(result.warnings, [source, metadata, compiler])
    }
}
