import XCTest

@testable import SwiftPodsCore

final class NativeClangModuleMapTests: XCTestCase {
    func testQuotedModuleIdentifiersAndLanguageRequirementsArePreserved() throws {
        let map = try NativeClangModuleMap("""
            module "Quoted" { header "Quoted.h" export * }
            framework module "CXX" { requires cplusplus header "Vendor.h" export * }
            extern module "External" "External.modulemap"
            module "Parent"."Child" { header "Child.h" }
            """)
        XCTAssertEqual(map.modules, [
            .init(name: "Quoted"), .init(name: "CXX", requiresCXX: true),
            .init(name: "External"), .init(name: "Parent.Child"),
        ])
    }

    func testUnimportableQuotedModuleNamesFailInsteadOfSkippingModuleValidation() throws {
        XCTAssertThrowsError(try NativeClangModuleMap("module \"Not-an-identifier\" { header \"Valid.h\" }")) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-LINT-MODULE-MAP")
        }
    }

    func testImportsEveryTopLevelModuleIncludingDeclarationsOnTheSameLine() throws {
        let map = try NativeClangModuleMap("""
            module First { header "First.h" export * } module Second { header "Second.h" export * }
            framework module Parent { module Nested { header "Nested.h" } export * }
            """)
        XCTAssertEqual(map.modules.map(\.name), ["First", "Second", "Parent"])
    }

    func testCommentsAndQuotedHeaderPathsCannotCreateModulesOrLanguageRequirements() throws {
        let map = try NativeClangModuleMap("""
            /* module Fake { requires cplusplus } */
            module Real {
                header "module Fake { requires cplusplus }.h"
                // requires cplusplus
            }
            """)
        XCTAssertEqual(map.modules, [.init(name: "Real")])
    }

    func testLanguageRequirementsBelongToTheirModuleAndRespectNegation() throws {
        let map = try NativeClangModuleMap("""
            module CXX [system] { requires objc, cplusplus header "Vendor.h" }
            module Plain { requires !cplusplus header "Plain.h" }
            module Modern { requires cplusplus17 header "Modern.h" }
            module Older { requires !cplusplus17 header "Older.hpp" }
            module CXX14 { requires cplusplus, !cplusplus17 header "CXX14.h" }
            module Parent { module Child { requires cplusplus } }
            """)
        XCTAssertEqual(map.modules, [
            .init(name: "CXX", requiresCXX: true, requiresObjC: true), .init(name: "Plain", requiresCXX: false),
            .init(name: "Modern", requiresCXX: true), .init(name: "Older"),
            .init(name: "CXX14", requiresCXX: true), .init(name: "Parent"),
        ])
    }

    func testLibraryNormalizationPreservesCommentsStringsAndLinkFrameworkDirectives() throws {
        let contents = """
            /* framework module Decoy {} */
            framework /* qualifier */ module First { header "framework module.h" link framework "Foundation" }
            framework module Second { header "Second.h" } // framework module Decoy {}
            """
        let expected = """
            /* framework module Decoy {} */
            /* qualifier */ module First { header "framework module.h" link framework "Foundation" }
            module Second { header "Second.h" } // framework module Decoy {}
            """
        let normalized = try NativeClangModuleMap.libraryContents(contents)
        XCTAssertEqual(normalized, expected)
        XCTAssertEqual(try NativeClangModuleMap(normalized).modules.map(\.name), ["First", "Second"])
        XCTAssertEqual(try NativeClangModuleMap.libraryContents(normalized), normalized)
    }

    func testModuleLanguagesRespectObjectiveCAndCPlusPlusRequirements() throws {
        let map = try NativeClangModuleMap("""
            module C { requires !objc, !cplusplus }
            module CPP { requires !objc, cplusplus }
            module ObjC { requires objc, !cplusplus }
            module ObjCPP { requires objc, cplusplus }
            module Default { header "objc, cplusplus.hpp" }
            """)
        for fallback in [false, true] {
            XCTAssertEqual(map.modules.map { $0.language(cxx: fallback) }, [.c, .cpp, .m, .mm, fallback ? .mm : .m])
        }
        XCTAssertEqual(map.modules[0].importDirective, "#pragma clang module import C\n")
        XCTAssertEqual(map.modules[1].importDirective, "#pragma clang module import CPP\n")
        XCTAssertEqual(map.modules[2].importDirective, "@import ObjC;\n")
    }
}
