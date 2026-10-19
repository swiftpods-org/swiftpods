import XCTest

@testable import SwiftPodsCore

final class NativeStructuredInputTests: XCTestCase {
    private func spec(_ changes: [String: Any]) throws -> NativeSpec {
        try NativeSpec(data: ["name": "Kit", "version": "1.0"].merging(changes) { _, last in last })
    }

    func testNumericGitSelectorsKeepIntegerAndFloatSpelling() throws {
        XCTAssertEqual(NativeSourceOptions.gitSelector(1), "1")
        XCTAssertEqual(NativeSourceOptions.gitSelector(1.0), "1.0")
        XCTAssertEqual(NativeSourceOptions.gitSelector(UInt64(9_007_199_254_740_993)), "9007199254740993")
        for key in ["tag", "commit"] {
            let value = try spec(["source": ["git": "fixture.git", key: 1.0]])
            XCTAssertEqual((value.data["source"] as? [String: Any])?[key] as? Double, 1.0)
            XCTAssertNoThrow(try NativeDependency(["name": "Kit", "options": ["git": "fixture.git", key: 1.0]]))
        }
        let swift = try spec(["swift_versions": [5.0]])
        XCTAssertEqual(try NativeSwiftVersion.select(spec: swift, targets: []), "5.0")
    }

    func testJSONPreservesFloatingTypesThroughNestedTransport() throws {
        let value: [String: Any] = ["source": ["tag": 1.0], "values": [true, 1, 0.0, -0.0], "text": "a\n\"b"]
        for pretty in [false, true] {
            let data = try NativeJSON.data(value, pretty: pretty)
            let decoded = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let source = decoded["source"] as! [String: NSNumber]
            XCTAssertTrue(NativeScalarString.isFloating(source["tag"]!))
            let values = decoded["values"] as! [NSNumber]
            XCTAssertEqual(NativeScalarString.boolean(values[0]), true)
            XCTAssertNil(NativeScalarString.boolean(values[1]))
            XCTAssertTrue(NativeScalarString.isFloating(values[2]))
            XCTAssertEqual(values[3].doubleValue.sign, .minus)
        }
        XCTAssertThrowsError(try NativeJSON.data(["value": Double.nan]))
    }

    func testNonFloatingJSONRetainsExistingByteIdentity() throws {
        let value: [String: Any] = ["empty": [], "map": ["bool": true, "integer": 42], "url": "https://swiftpods.org"]
        let previous = try JSONSerialization.data(
            withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        XCTAssertEqual(try jsonData(value), previous)
    }

    func testSelectorsRejectBooleansAndNumericBranchesBeforeCheckout() {
        for source: [String: Any] in [
            ["git": "fixture.git", "tag": true], ["git": "fixture.git", "commit": false],
            ["git": "fixture.git", "branch": 1], ["http": "source.zip", "tag": 1],
        ] {
            XCTAssertThrowsError(try spec(["source": source]))
        }
    }

    func testSchemeFlagsRequireBooleansWhileArgumentsUseScalarSpelling() throws {
        for value in [0, 1, 2] {
            XCTAssertThrowsError(try spec(["scheme": ["code_coverage": value]]))
            XCTAssertThrowsError(try spec(["testspecs": [["name": "Tests", "scheme": ["parallelizable": value]]]]))
        }
        let value = try spec([
            "scheme": [
                "launch_arguments": ["--value", 42], "environment_variables": ["VALUE": 1.0], "code_coverage": true,
            ]
        ])
        let options = try value.attributes("Kit", platform: "osx")["scheme"] as! [String: Any]
        XCTAssertEqual(options["launch_arguments"] as? [String], ["--value", "42"])
        XCTAssertEqual(options["environment_variables"] as? [String: String], ["VALUE": "1.0"])
    }

    func testMalformedStructuresFailAcrossAllSpecificationKinds() {
        let cases: [[String: Any]] = [
            ["scheme": ["launch_arguments": "--value"]], ["script_phases": [["name": "Missing script"]]],
            ["script_phases": [["name": "Unknown", "script": "true", "unknown": true]]],
            ["on_demand_resources": ["asset": ["paths": "*.txt", "category": 42]]],
            ["on_demand_resources": ["asset": ["paths": "*.txt", "category": "invalid"]]],
            ["default_subspecs": [42]], ["requires_arc": [42]], ["license": ["type": 42]],
            ["authors": [42]], ["info_plist": ["Field": NSNull()]],
        ]
        for changes in cases {
            XCTAssertThrowsError(try spec(changes))
            for kind in ["subspecs", "testspecs", "appspecs"] {
                XCTAssertThrowsError(try spec([kind: [["name": "Child"].merging(changes) { _, last in last }]]))
            }
        }
    }

    func testPrefixContentsJoinNumbersWithoutChangingRawAttributes() throws {
        let values: [Any] = ["#define VALUE \\", 42, NSNull(), ["#define OTHER 7"]]
        let value = try spec(["prefix_header_contents": values])
        XCTAssertEqual(
            try value.attributes("Kit", platform: "osx")["prefix_header_contents"] as? String,
            "#define VALUE \\\n42\n\n#define OTHER 7")
        XCTAssertEqual((value.data["prefix_header_contents"] as? [Any])?[1] as? Int, 42)
        XCTAssertEqual(NativeScalarString.prefixContents(["value\r\n"]), "value")
        XCTAssertEqual(NativeScalarString.prefixContents(["\r\n"]), "")
    }

    func testOpaqueXcconfigValuesAndNumericArraysAreNotDropped() throws {
        let value = try spec([
            "pod_target_xcconfig": [
                "DICTIONARY": ["nested": true], "VALUES": [42, "yes"], "FLOAT": 1.0, "EMPTY": NSNull(),
            ]
        ])
        let attributes = try value.attributes("Kit", platform: "osx")
        let settings = NativeSpec.xcconfig(attributes, key: "pod_target_xcconfig")
        XCTAssertEqual(settings["DICTIONARY"] as? String, "{\"nested\" => true}")
        XCTAssertEqual(settings["VALUES"] as? [String], ["42", "yes"])
        XCTAssertEqual(settings["FLOAT"] as? String, "1.0")
        XCTAssertEqual(settings["EMPTY"] as? String, "")
        XCTAssertThrowsError(try spec(["pod_target_xcconfig": ["INVALID": Double.nan]]))
    }

    func testOnDemandDeclarationsNormalizeEmptyAndNullablePaths() throws {
        let declarations = try NativeOnDemandResources.declarations([
            "empty": ["category": "prefetched"], "asset": ["paths": ["file.txt", NSNull()]],
        ])
        XCTAssertEqual(declarations.first?.paths, ["file.txt"])
        XCTAssertEqual(declarations.last?.paths, [])
        XCTAssertEqual(declarations.last?.category, "prefetched")
        XCTAssertNoThrow(try spec(["authors": ["A", ["B": "mail"]]]))
    }

    func testBooleanScriptLogVisibilityHasItsIntendedEffect() throws {
        let hidden = try NativeScriptPhase(["name": "Hidden", "script": "true", "show_env_vars_in_log": false])
        XCTAssertEqual(hidden.object["showEnvVarsInLog"] as? String, "0")
        let visible = try NativeScriptPhase(["name": "Visible", "script": "true", "show_env_vars_in_log": true])
        XCTAssertNil(visible.object["showEnvVarsInLog"])
        XCTAssertThrowsError(try NativeScriptPhase(["name": "Bad", "script": "true", "always_out_of_date": true]))
    }

    func testScalarStringMatchesFloatAndControlCharacterSpelling() {
        let samples: [(Double, String)] = [
            (1.0, "1.0"), (0.0001, "0.0001"), (0.00001, "1.0e-05"), (1e14, "100000000000000.0"),
            (1e15, "1.0e+15"), (1e20, "1.0e+20"), (-0.0, "-0.0"),
        ]
        for (value, text) in samples { XCTAssertEqual(NativeScalarString.number(value), text) }
        XCTAssertEqual(NativeScalarString.inspect("\u{0007}\u{001B}\u{001F}"), "\"\\a\\e\\u001F\"")
    }

    func testLargeFractionalSelectorsKeepRubyDecimalSpelling() {
        let samples: [(Double, String)] = [
            (1_000_000_000_000_000.1, "1000000000000000.1"),
            (3_826_980_940_661_245.5, "3826980940661245.5"),
            (-1_407_446_849_979_900.2, "-1407446849979900.2"),
            (1_000_000_000_000_001.0, "1.000000000000001e+15"),
        ]
        for (value, expected) in samples {
            XCTAssertEqual(NativeScalarString.number(value), expected)
            XCTAssertEqual(NativeSourceOptions.gitSelector(value), expected)
        }
    }
}
