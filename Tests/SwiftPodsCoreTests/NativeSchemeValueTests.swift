import XCTest

@testable import SwiftPodsCore

#if canImport(FoundationXML)
    import FoundationXML
#endif

final class NativeSchemeValueTests: XCTestCase {
    private let values = ["tab\ttail", "line\ntail", "carriage\rtail", "pair\r\ntail", "", " \t\r\n "]

    private func scheme(_ options: [String: Any], kind: NativeSpecKind = .library) throws -> XMLDocument {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let xcode = try NativeXcode(
            project: directory, manifest: [:], resolution: NativeResolution(specs: [:], requests: []),
            integrateUserProjects: false)
        try xcode.writeScheme(id: "TARGET", label: "Kit", kind: kind, host: nil, options: options)
        return try XMLDocument(
            contentsOf: directory.appendingPathComponent("Pods/Pods.xcodeproj/xcshareddata/xcschemes/Kit.xcscheme"))
    }

    func testSchemeArgumentsPreserveWhitespaceAndEmptyValues() throws {
        for kind in [NativeSpecKind.library, .test, .app] {
            let document = try scheme(["launch_arguments": values], kind: kind)
            for action in ["LaunchAction", "TestAction"] {
                let arguments = try document.nodes(
                    forXPath: "/Scheme/\(action)/CommandLineArguments/CommandLineArgument/@argument")
                XCTAssertEqual(arguments.compactMap(\.stringValue), values)
            }
        }
    }

    func testSchemeEnvironmentPreservesWhitespaceAndEmptyValues() throws {
        let environment = Dictionary(
            uniqueKeysWithValues: values.enumerated().map { ("VALUE_\($0.offset)", $0.element) })
        let document = try scheme(["environment_variables": environment])
        for action in ["LaunchAction", "TestAction"] {
            let nodes = try document.nodes(forXPath: "/Scheme/\(action)/EnvironmentVariables/EnvironmentVariable")
            let observed = Dictionary(
                uniqueKeysWithValues: nodes.map { node in
                    let element = node as! XMLElement
                    return (
                        element.attribute(forName: "key")!.stringValue!,
                        element.attribute(forName: "value")!.stringValue!
                    )
                })
            XCTAssertEqual(observed, environment)
        }
    }

    func testSchemeEscapingPreservesLiteralReferencesMarkupAndUnicode() throws {
        let value = "&#9; &#10; &#13; &quot; <entry a='\"'/> 🧩東京E\u{0301}\\t\t\n\r"
        let document = try scheme(["launch_arguments": [value], "environment_variables": ["VALUE": value]])
        for path in [
            "/Scheme/LaunchAction/CommandLineArguments/CommandLineArgument/@argument",
            "/Scheme/TestAction/EnvironmentVariables/EnvironmentVariable/@value",
        ] {
            XCTAssertEqual(try document.nodes(forXPath: path).first?.stringValue, value)
        }
    }

    func testSchemeRejectsCharactersThatXMLCannotRepresent() {
        let invalid = Array(0...8) + [11, 12] + Array(14...31) + [0xFFFE, 0xFFFF]
        for code in invalid {
            let value = "head" + String(UnicodeScalar(code)!) + "tail"
            let options: [[String: Any]] = [
                ["launch_arguments": [value]], ["environment_variables": ["VALUE": value]],
                ["environment_variables": [value: "valid"]], ["build_configurations": ["Test": value]],
            ]
            for option in options {
                XCTAssertThrowsError(try NativeSchemeOptions.validate(option, file: "Kit")) {
                    XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-SPEC-SCHEME")
                }
            }
        }
    }

    func testSchemeAcceptsXMLWhitespaceAndUnicodeBoundaries() {
        for code in [9, 10, 13, 0x20, 0x7F, 0x85, 0xD7FF, 0xE000, 0xFFFD, 0x10000, 0x10FFFF] {
            let value = String(UnicodeScalar(code)!)
            XCTAssertNoThrow(
                try NativeSchemeOptions.validate(
                    ["launch_arguments": [value], "environment_variables": ["VALUE": value]], file: "Kit"))
        }
    }

    func testSchemeEnvironmentRejectsNamesTheOperatingSystemCannotPreserve() {
        for name in ["", "FIELD=SUFFIX", "FIELD=\u{301}Suffix"] {
            XCTAssertThrowsError(
                try NativeSchemeOptions.validate(["environment_variables": [name: "value"]], file: "Kit")
            ) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-SPEC-SCHEME")
            }
        }
    }

    func testSchemeEnvironmentAcceptsUnicodeNamesAndLiteralEqualsInValues() throws {
        let environment = ["\u{301}FIELD": "a=b\nnext", "SPACE NAME": "", "dash-name": "東京 🧩"]
        XCTAssertNoThrow(try NativeSchemeOptions.validate(["environment_variables": environment], file: "Kit"))
        let document = try scheme(["environment_variables": environment])
        let nodes = try document.nodes(forXPath: "/Scheme/TestAction/EnvironmentVariables/EnvironmentVariable")
        let observed = Dictionary(
            uniqueKeysWithValues: nodes.map { node in
                let element = node as! XMLElement
                return (
                    element.attribute(forName: "key")!.stringValue!, element.attribute(forName: "value")!.stringValue!
                )
            })
        XCTAssertEqual(observed, environment)
    }
}
