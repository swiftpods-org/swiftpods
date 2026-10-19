import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeBuildSettingTypeTests: XCTestCase {
    func testDeclaredStringsUseStringExpressionEscaping() throws {
        for key in ["PRODUCT_NAME", "EXECUTABLE_NAME", "EXECUTABLE_PREFIX", "CURRENT_PROJECT_VERSION"] {
            let scope = NativeBuildSettingScope([key: #"SDK\$(SUFFIX)"#, "SUFFIX": "Selected"])
            XCTAssertEqual(try scope.expandedValue(key), #"SDK\Selected"#, key)
        }
    }

    func testDeclaredPathsUseStringExpressionEscaping() throws {
        for key in ["SYMROOT", "OBJROOT", "INFOPLIST_FILE", "MODULEMAP_FILE", "CONFIGURATION_BUILD_DIR"] {
            let scope = NativeBuildSettingScope([key: #"SDK\$(SUFFIX)"#, "SUFFIX": "Selected"])
            XCTAssertEqual(try scope.expandedValue(key), #"SDK\Selected"#, key)
        }
    }

    func testBooleanAndEnumerationReferencesRetainTheirStringForm() throws {
        for key in [
            "GENERATE_INFOPLIST_FILE", "GCC_TREAT_WARNINGS_AS_ERRORS", "MACH_O_TYPE", "SWIFT_OPTIMIZATION_LEVEL",
        ] {
            let scope = NativeBuildSettingScope([key: #"SDK\$(SUFFIX)"#, "SUFFIX": "Selected"])
            XCTAssertEqual(try scope.expandedValue(key), #"SDK\Selected"#, key)
        }
    }

    func testDeclaredListsAndUnknownNamesKeepListExpressionEscaping() throws {
        for key in ["HEADER_SEARCH_PATHS", "OTHER_CFLAGS", "ARCHS", "CUSTOM_DIR", "CUSTOM_NAME", "PODS_ROOT"] {
            let scope = NativeBuildSettingScope([key: #"SDK\$(SUFFIX)"#, "SUFFIX": "Selected"])
            XCTAssertEqual(try scope.expandedValue(key), #"SDK\$(SUFFIX)"#, key)
        }
    }

    func testNamedInheritanceKeepsTheDeclaredStringType() throws {
        let scope = NativeBuildSettingScope(["PRODUCT_NAME": #"SDK\$(SUFFIX)"#, "SUFFIX": "Selected"])
            .merging(["PRODUCT_NAME": "$(PRODUCT_NAME)/Next"])
        XCTAssertEqual(try scope.expandedValue("PRODUCT_NAME"), #"SDK\Selected/Next"#)
    }

    func testBuiltinToolchainDirectoryKeepsItsStringTypeWithoutAnOptionDeclaration() throws {
        let scope = NativeBuildSettingScope(["TOOLCHAIN_DIR": #"SDK\$(SUFFIX)"#, "SUFFIX": "Selected"])
        XCTAssertEqual(try scope.expandedValue("TOOLCHAIN_DIR"), #"SDK\Selected"#)
    }

    func testUntypedInstalledOptionsUseStringDefaults() throws {
        for key in [
            "LD_ADDRESS_SANITIZER", "LD_ADDRESS_SANITIZER_clang", "LD_ADDRESS_SANITIZER_swiftc", "LD_FUZZER",
            "LD_FUZZER_clang", "LD_FUZZER_swiftc", "LD_OBJC_RUNTIME_ARGS", "LD_OBJC_RUNTIME_ARGS_clang",
            "LD_OBJC_RUNTIME_ARGS_swiftc",
        ] {
            let scope = NativeBuildSettingScope([key: #"SDK\$(SUFFIX)"#, "SUFFIX": "Selected"])
            XCTAssertEqual(try scope.expandedValue(key), #"SDK\Selected"#, key)
        }
    }

    private func fixture() throws -> NativePBX {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let graph = try NativePBX(root.appendingPathComponent("App.xcodeproj/project.pbxproj"))
        let sdk = graph.sourceRoot.appendingPathComponent(#"SDK\Selected.sdk"#)
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["CanonicalName": "macosx99.4"]).write(
            to: sdk.appendingPathComponent("SDKSettings.json"))
        return graph
    }

    func testSDKSelectionUsesTheTypeOfIndirectReferences() throws {
        let graph = try fixture()
        for key in ["PRODUCT_NAME", "SYMROOT", "INFOPLIST_FILE", "MODULEMAP_FILE"] {
            let raw: [String: Any] = [
                key: #"SDK\$(SUFFIX)"#, "SUFFIX": "Selected",
                "SDKROOT": "$(PROJECT_DIR)/$(\(key)).sdk", "VALUE[sdk=macosx99.*]": "selected",
            ]
            let result = try NativeBuildSettings.resolved(["name": "Debug", "buildSettings": raw], graph: graph)
            XCTAssertEqual(result["VALUE"] as? String, "selected", key)
            XCTAssertEqual(result[key] as? String, raw[key] as? String)
        }
    }

    func testBaseFileReferencesUseTheTypeOfTheirIndirectVariables() throws {
        let graph = try fixture()
        let ref = graph.add(
            "configuration", ["isa": "PBXFileReference", "path": "$(INFOPLIST_FILE)", "sourceTree": "SOURCE_ROOT"])
        let selected = try NativeBuildSettings.file(
            ref, graph: graph, variables: ["INFOPLIST_FILE": #"Config\$(SUFFIX).xcconfig"#, "SUFFIX": "Selected"])
        XCTAssertEqual(selected.path, graph.sourceRoot.appendingPathComponent(#"Config\Selected.xcconfig"#).path)
    }

    func testStandaloneXcconfigSDKSelectionUsesDeclaredTypes() throws {
        let graph = try fixture()
        let file = graph.sourceRoot.appendingPathComponent("Base.xcconfig")
        try Data(
            #"""
            PRODUCT_NAME = SDK\$(SUFFIX)
            SUFFIX = Selected
            SDKROOT = $(PROJECT_DIR)/$(PRODUCT_NAME).sdk
            VALUE[sdk=macosx99.*] = selected
            """#.utf8
        ).write(to: file)
        var inputs = Set<String>()
        let result = try NativeBuildSettings.xcconfig(
            file, base: ["PROJECT_DIR": graph.sourceRoot.path], inputs: &inputs)
        XCTAssertEqual(result["VALUE"] as? String, "selected")
    }
}
