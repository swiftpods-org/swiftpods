import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativePBXValueTests: XCTestCase {
    private func read(_ value: Any) throws -> Any {
        let text = NativePBX.serialize(["value": value])
        let graph = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: Any])
        return try XCTUnwrap(graph["value"])
    }

    func testNilBuildSettingSerializesAsAnEmptyString() throws {
        XCTAssertEqual(try read(NSNull()) as? String, "")
    }

    func testBooleanValuesKeepRubyScalarSpelling() throws {
        XCTAssertEqual(try read(true) as? String, "true")
        XCTAssertEqual(try read(false) as? String, "false")
        XCTAssertEqual(try read(NSNumber(value: true)) as? String, "true")
        XCTAssertEqual(try read(NSNumber(value: false)) as? String, "false")
    }

    func testFloatingPointValuesKeepDecimalPrecisionAndRubyExponents() throws {
        for (number, expected) in [(1.0, "1.0"), (-0.0, "-0.0"), (1.0e-6, "1.0e-06"), (1.0e20, "1.0e+20")] {
            XCTAssertEqual(try read(NSNumber(value: number)) as? String, expected)
        }
        XCTAssertEqual(try read(NSNumber(value: 42)) as? String, "42")
    }

    func testScalarCoercionAppliesRecursivelyWithoutFlatteningProjectContainers() throws {
        let source: [String: Any] = ["items": ["before", NSNull(), false, true, 42, NSNumber(value: 1.0)]]
        let result = try XCTUnwrap(try read(source) as? [String: Any])
        XCTAssertEqual(result["items"] as? [String], ["before", "", "false", "true", "42", "1.0"])
    }

    func testStringsKeepControlsUnicodeAndLiteralEscapes() throws {
        var values = (0..<32).map { "head" + String(UnicodeScalar($0)!) + "tail" }
        values += ["\\U1234\\n\\r\\\"end\\", "🧩東京E\u{0301}\u{2028}\u{2029}\u{FEFF}"]
        for value in values { XCTAssertEqual(try read(value) as? String, value) }
    }
}
