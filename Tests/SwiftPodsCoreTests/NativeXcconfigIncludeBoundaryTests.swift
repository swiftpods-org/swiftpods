import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeXcconfigIncludeBoundaryTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testNULIncludesCannotSelectExistingLiteralPercentFiles() throws {
        let root = try directory()
        let alias = root.appendingPathComponent("Leaf%00Ignored.xcconfig")
        try Data("VALUE = wrong\n".utf8).write(to: alias)
        let file = root.appendingPathComponent("Root.xcconfig")
        for directive in ["#include", "#include?"] {
            try Data(("// first line\n" + directive + " \"Leaf\0Ignored.xcconfig\"\n").utf8).write(to: file)
            var inputs = Set<String>()
            XCTAssertThrowsError(try NativeBuildSettings.xcconfig(file, inputs: &inputs)) {
                let diagnostic = $0 as? Diagnostic
                XCTAssertEqual(diagnostic?.code, "SP-XCCONFIG-INCLUDE")
                XCTAssertEqual(diagnostic?.file, file.path)
                XCTAssertEqual(diagnostic?.line, 2)
            }
            XCTAssertFalse(inputs.contains(alias.path))
        }
    }

    func testNestedNULIncludesReportTheContainingFileAndLine() throws {
        let root = try directory()
        let file = root.appendingPathComponent("Root.xcconfig")
        let child = root.appendingPathComponent("Child.xcconfig")
        try Data("#include \"Child.xcconfig\"\n".utf8).write(to: file)
        try Data("// first\n// second\n#include? \"Missing\0Leaf.xcconfig\"\n".utf8).write(to: child)
        var inputs = Set<String>()
        XCTAssertThrowsError(try NativeBuildSettings.xcconfig(file, inputs: &inputs)) {
            let diagnostic = $0 as? Diagnostic
            XCTAssertEqual(diagnostic?.code, "SP-XCCONFIG-INCLUDE")
            XCTAssertEqual(diagnostic?.file, child.path)
            XCTAssertEqual(diagnostic?.line, 3)
        }
    }

    func testLiteralPercentAndUnicodeIncludeNamesKeepTheirMeaning() throws {
        let root = try directory()
        let file = root.appendingPathComponent("Root.xcconfig")
        for name in ["Leaf%00Ignored.xcconfig", "\u{301}Leaf東京.xcconfig"] {
            let child = root.appendingPathComponent(name)
            try Data("VALUE = selected\n".utf8).write(to: child)
            try Data(("#include \"" + name + "\"\n").utf8).write(to: file)
            var inputs = Set<String>()
            XCTAssertEqual(try NativeBuildSettings.xcconfig(file, inputs: &inputs)["VALUE"] as? String, "selected")
            XCTAssertTrue(inputs.contains(child.path))
        }
    }
}
