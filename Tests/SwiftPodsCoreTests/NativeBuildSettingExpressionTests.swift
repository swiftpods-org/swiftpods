import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeBuildSettingExpressionTests: XCTestCase {
    func testExpressionsMatchRecordedXcodeResults() throws {
        struct Observation: Decodable {
            let name: String
            var settings: [String: String]
            let expression: String
            let expected: String
        }
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/BuildSettingExpressions.json")
        let observations = try JSONDecoder().decode([Observation].self, from: Data(contentsOf: file))
        XCTAssertEqual(observations.count, 53)
        for var observation in observations {
            observation.settings["OUTPUT"] = observation.expression
            XCTAssertEqual(
                try NativeBuildSettings.expandedValue("OUTPUT", settings: observation.settings), observation.expected,
                observation.name)
        }
    }

    func testUnknownOrdinarySettingsKeepTheirLiteralReferences() throws {
        XCTAssertEqual(
            try NativeBuildSettings.expandedValue("VALUE", settings: ["VALUE": "$(MISSING)/literal"]),
            "$(MISSING)/literal")
    }

    func testUnknownModifiersStillExpandKnownOperands() throws {
        XCTAssertEqual(
            try NativeBuildSettings.expandedValue(
                "VALUE", settings: ["VALUE": "$(KNOWN:unrecognized)", "KNOWN": "literal"]),
            "literal")
    }

    func testDynamicMacroNamesAndModifierDefaultsCanBeCombined() throws {
        let settings: [String: Any] = [
            "VALUE": "${SDK_${CHOICE}:lower:default=macosx}", "CHOICE": "SELECTED", "SDK_SELECTED": "MACOSX",
        ]
        XCTAssertEqual(try NativeBuildSettings.expandedValue("VALUE", settings: settings), "macosx")
    }

    func testCyclesAreStillDiagnosedThroughModifiers() throws {
        XCTAssertThrowsError(
            try NativeBuildSettings.expandedValue(
                "FIRST", settings: ["FIRST": "$(SECOND:lower)", "SECOND": "${FIRST:upper}"])
        ) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCCONFIG-CYCLE")
        }
    }
}
