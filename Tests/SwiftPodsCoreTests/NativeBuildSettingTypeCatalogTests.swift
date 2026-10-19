import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeBuildSettingTypeCatalogTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func specification(_ value: Any, at file: URL) throws -> URL {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: file)
        return file
    }

    func testAllDeclaredKindsFollowTheScalarOrListParser() throws {
        let kinds = [
            "Boolean", "bool", "String", "string", "Path", "Enumeration", "enum", "CodeSignIdentity", "CodeSignStyle",
            "CompilerVersion", "DevelopmentTeam", "ProvisioningProfile", "ProvisioningProfileSpecifier",
            "StringList", "stringlist", "PathList", "PathOrderedSet", "OpenCLArchitectures",
        ]
        let file = try specification(
            ["Options": kinds.map { ["Name": "PROBE_" + $0, "Type": $0] }],
            at: root().appendingPathComponent("Kinds.xcspec"))
        let types = NativeBuildSettingTypes(specifications: [file])
        for (index, kind) in kinds.enumerated() {
            let scalar = index < 13
            XCTAssertEqual(try types.isScalar("PROBE_" + kind), scalar, kind)
            let scope = NativeBuildSettingScope(
                ["PROBE_" + kind: #"value\$(SUFFIX)"#, "SUFFIX": "expanded"], settingTypes: types)
            XCTAssertEqual(
                try scope.expandedValue("PROBE_" + kind), scalar ? #"value\expanded"# : #"value\$(SUFFIX)"#, kind)
        }
    }

    func testOnlyOptionAndPropertyDeclarationsSupplyTypes() throws {
        let file = try specification(
            [
                ["Name": "CUSTOM_ROOT", "Type": "String", "Options": [["Name": "ACTUAL_OPTION", "Type": "Path"]]],
                ["Properties": [["Name": "ACTUAL_PROPERTY", "Type": "String"]]],
            ], at: root().appendingPathComponent("Domains.xcspec"))
        let types = NativeBuildSettingTypes(specifications: [file])
        XCTAssertTrue(try types.isScalar("ACTUAL_OPTION"))
        XCTAssertTrue(try types.isScalar("ACTUAL_PROPERTY"))
        XCTAssertFalse(try types.isScalar("CUSTOM_ROOT"))
        XCTAssertFalse(try types.isScalar("CUSTOM_NAME"))
    }

    func testInvalidAndUnrelatedSpecificationsDoNotInventDeclarations() throws {
        let root = try root()
        let invalid = root.appendingPathComponent("Invalid.xcspec")
        try Data("not a property list".utf8).write(to: invalid)
        let unrelated = try specification(
            ["Name": "CUSTOM", "Type": "String"], at: root.appendingPathComponent("Tool.xcspec"))
        let malformed = try specification(
            [
                "Options": [
                    ["Name": "UNKNOWN_TYPE", "Type": "FutureKind"], ["Name": "INVALID_CASE", "Type": "StRiNg"],
                    ["Name": "NO_TYPE"], ["Type": "String"],
                ]
            ],
            at: root.appendingPathComponent("Malformed.xcspec"))
        let types = NativeBuildSettingTypes(specifications: [
            invalid, unrelated, malformed, root.appendingPathComponent("Missing.xcspec"),
        ])
        XCTAssertFalse(try types.isScalar("CUSTOM"))
        XCTAssertTrue(try types.isScalar("NO_TYPE"))
        for key in ["UNKNOWN_TYPE", "INVALID_CASE"] {
            XCTAssertThrowsError(try types.isScalar(key)) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCODE-SETTING-TYPE")
            }
        }
        XCTAssertTrue(try types.isScalar("SDKROOT"))
    }

    func testConflictingDeclarationsFailOnlyWhenTheConflictingKeyIsEvaluated() throws {
        let root = try root()
        let files = try ["String", "StringList"].enumerated().map { index, kind in
            try specification(
                ["Options": [["Name": "CONFLICT", "Type": kind]]], at: root.appendingPathComponent("\(index).xcspec"))
        }
        let types = NativeBuildSettingTypes(specifications: files)
        let scope = NativeBuildSettingScope(["CONFLICT": "value", "OTHER": "safe"], settingTypes: types)
        XCTAssertEqual(try scope.expandedValue("OTHER"), "safe")
        XCTAssertThrowsError(try scope.expandedValue("CONFLICT")) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCODE-SETTING-TYPE")
        }
    }

    func testDeveloperInstallationsKeepTheirTypeNamespacesSeparate() throws {
        let root = try root()
        let first = root.appendingPathComponent("First.app/Contents/Developer")
        let second = root.appendingPathComponent("Second.app/Contents/Developer")
        for (developer, kind) in [(first, "String"), (second, "StringList")] {
            _ = try specification(
                ["Options": [["Name": "TOOLCHAIN_CUSTOM", "Type": kind]]],
                at: developer.deletingLastPathComponent().appendingPathComponent(
                    "SharedFrameworks/XCBuild.framework/Versions/A/PlugIns/BuildService.bundle/Contents/PlugIns/Specs.ideplugin/Contents/Resources/Custom.xcspec"
                ))
        }
        XCTAssertTrue(try NativeBuildSettingTypes(developerDirectory: first).isScalar("TOOLCHAIN_CUSTOM"))
        XCTAssertFalse(try NativeBuildSettingTypes(developerDirectory: second).isScalar("TOOLCHAIN_CUSTOM"))
        XCTAssertFalse(try NativeBuildSettingTypes(developerDirectory: nil).isScalar("TOOLCHAIN_CUSTOM"))
    }

    func testPlatformAndDeveloperSpecificationsAreIncluded() throws {
        let developer = try root().appendingPathComponent("Xcode.app/Contents/Developer")
        for (relative, key) in [
            ("Library/Xcode/Specifications/Core.xcspec", "CORE_CUSTOM"),
            ("Platforms/Test.platform/Developer/Library/Xcode/Specifications/Platform.xcspec", "PLATFORM_CUSTOM"),
        ] {
            _ = try specification(
                ["Options": [["Name": key, "Type": "Path"]]], at: developer.appendingPathComponent(relative))
        }
        let types = NativeBuildSettingTypes(developerDirectory: developer)
        XCTAssertTrue(try types.isScalar("CORE_CUSTOM"))
        XCTAssertTrue(try types.isScalar("PLATFORM_CUSTOM"))
    }

    func testSelectedNamespacePropagatesThroughProjectTargetAndFileScopes() throws {
        let root = try root()
        let spec = try specification(
            ["Options": [["Name": "CUSTOM_TYPED", "Type": "String"]]], at: root.appendingPathComponent("Types.xcspec"))
        let types = NativeBuildSettingTypes(specifications: [spec])
        let context = NativeSDKContext(settingTypes: types)
        let graph = try NativePBX(root.appendingPathComponent("App.xcodeproj/project.pbxproj"))
        let sdk = root.appendingPathComponent(#"SDK\Selected.sdk"#)
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["CanonicalName": "macosx99.4"]).write(
            to: sdk.appendingPathComponent("SDKSettings.json"))
        let configuration: [String: Any] = [
            "name": "Debug",
            "buildSettings": ["SDKROOT": "$(PROJECT_DIR)/$(CUSTOM_TYPED).sdk", "VALUE[sdk=macosx99.*]": "selected"],
        ]
        let scopes = try NativeBuildSettings.resolvedScopes(
            configuration,
            inheriting: ["name": "Debug", "buildSettings": ["CUSTOM_TYPED": #"SDK\$(SUFFIX)"#, "SUFFIX": "Selected"]],
            graph: graph, sdkContext: context)
        XCTAssertEqual(scopes.target["VALUE"] as? String, "selected")
        let ref = graph.add(
            "ref", ["isa": "PBXFileReference", "path": "$(CUSTOM_TYPED).xcconfig", "sourceTree": "SOURCE_ROOT"])
        XCTAssertEqual(
            try NativeBuildSettings.file(
                ref, graph: graph, configuration: "Debug", targetName: nil, scope: scopes.projectScope
            ).path,
            root.appendingPathComponent(#"SDK\Selected.xcconfig"#).path)
    }

    func testStandaloneConfigurationUsesTheExplicitSDKContextsNamespace() throws {
        let root = try root()
        let spec = try specification(
            ["Options": [["Name": "CUSTOM_TYPED", "Type": "Path"]]], at: root.appendingPathComponent("Types.xcspec"))
        let types = NativeBuildSettingTypes(specifications: [spec])
        let sdk = root.appendingPathComponent(#"SDK\Selected.sdk"#)
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["CanonicalName": "macosx99.4"]).write(
            to: sdk.appendingPathComponent("SDKSettings.json"))
        let file = root.appendingPathComponent("Base.xcconfig")
        try Data(
            #"""
            CUSTOM_TYPED = SDK\$(SUFFIX)
            SUFFIX = Selected
            SDKROOT = $(PROJECT_DIR)/$(CUSTOM_TYPED).sdk
            VALUE[sdk=macosx99.*] = selected
            """#.utf8
        ).write(to: file)
        var inputs = Set<String>()
        let result = try NativeBuildSettings.xcconfig(
            file, base: ["PROJECT_DIR": root.path], inputs: &inputs, sdkContext: NativeSDKContext(settingTypes: types))
        XCTAssertEqual(result["VALUE"] as? String, "selected")
    }
    func testAbsentTypeInheritsAKnownListOrDefaultsToAString() throws {
        let root = try root()
        let base = try specification(
            ["Options": [["Name": "KNOWN_LIST", "Type": "StringList"]]], at: root.appendingPathComponent("Base.xcspec"))
        let child = try specification(
            ["Options": [["Name": "KNOWN_LIST"], ["Name": "DEFAULT_STRING"]]],
            at: root.appendingPathComponent("Child.xcspec"))
        let types = NativeBuildSettingTypes(specifications: [child, base])
        XCTAssertFalse(try types.isScalar("KNOWN_LIST"))
        XCTAssertTrue(try types.isScalar("DEFAULT_STRING"))
        let scope = NativeBuildSettingScope(
            ["DEFAULT_STRING": #"value\$(SUFFIX)"#, "SUFFIX": "expanded"], settingTypes: types)
        XCTAssertEqual(try scope.expandedValue("DEFAULT_STRING"), #"value\expanded"#)
    }

    func testLiteralContextBindingsCannotBypassAConflictingDeclaration() throws {
        let file = try specification(
            ["Options": [["Name": "PROJECT_DIR", "Type": "StringList"]]],
            at: root().appendingPathComponent("Conflicting.xcspec"))
        let types = NativeBuildSettingTypes(specifications: [file])
        let scope = NativeBuildSettingScope(
            ["PROJECT_DIR": "/literal/path"], literalKeys: ["PROJECT_DIR"], settingTypes: types)
        XCTAssertThrowsError(try scope.expandedValue("PROJECT_DIR")) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCODE-SETTING-TYPE")
        }
    }

}
