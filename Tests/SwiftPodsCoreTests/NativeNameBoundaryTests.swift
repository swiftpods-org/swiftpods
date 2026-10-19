import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeNameBoundaryTests: XCTestCase {
    func testSupplementarySpecsAndNamedAppHostsRetainCombiningMarks() throws {
        let spec = try NativeSpec(data: [
            "name": "Kit", "version": "1.0",
            "testspecs": [
                [
                    "name": "\u{301}Tests", "requires_app_host": true,
                    "app_host_name": "Kit/\u{301}Host", "dependencies": ["Kit/\u{301}Host": []],
                ]
            ],
            "appspecs": [["name": "\u{301}Host"]],
        ])
        let request = try NativeDependency(["name": "Kit/\u{301}Tests"])
        XCTAssertEqual(try spec.kind(request.name), .test)
        XCTAssertEqual(try spec.kind("Kit/\u{301}Host"), .app)
        XCTAssertNoThrow(try spec.validateSupplementary(request))
    }

    func testVariantLabelsKeepTheFullUnicodeSubspecSuffix() throws {
        let spec = try NativeSpec(data: [
            "name": "Kit", "version": "1.0", "subspecs": [["name": "\u{301}Core"], ["name": "Other"]],
        ])
        let requests = try ["Kit/\u{301}Core", "Kit/Other"].map { try NativeDependency(["name": $0]) }
        let targets = requests.enumerated().map { index, request -> [String: Any] in
            [
                "name": "Demo\(index)", "platform": ["name": "osx", "deployment_target": "13.0"],
                "dependencies": [["name": request.name]],
            ]
        }
        let plan = try NativeVariantPlan(
            manifest: ["targets": targets], resolution: NativeResolution(specs: ["Kit": spec], requests: requests))
        XCTAssertEqual(Set(plan.variants.values.map(\.label)), ["Kit-\u{301}Core", "Kit-Other"])
    }

    func testLockfilePinsAndDependencyEdgesUseUnicodeSubspecRoots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("Podfile.lock")
        try Data(
            """
            PODS:
              - "Kit/\u{301}Core (1.0)":
                - "Dep/\u{301}Nested (= 2.0)"
              - "Dep/\u{301}Nested (2.0)"
            DEPENDENCIES:
              - "Kit/\u{301}Core"
            """.utf8
        ).write(to: path)
        let lock = try NativeLock(path)
        XCTAssertEqual(lock.versions, ["Kit": "1.0", "Dep": "2.0"])
        XCTAssertEqual(lock.dependencies["Kit"], ["Dep"])
        XCTAssertEqual(lock.declarations["Kit/\u{301}Core"], [">= 0"])
    }

    func testHierarchySuffixesRetainMarksAndRejectSiblingPrefixes() {
        XCTAssertEqual(NativePodName.relativeName(of: "Kit/\u{301}Core", to: "Kit"), "\u{301}Core")
        XCTAssertEqual(
            NativePodName.relativeName(of: "Kit/\u{301}Core/\u{301}Nested", to: "Kit/\u{301}Core"), "\u{301}Nested")
        XCTAssertTrue(NativePodName.isWithin("Kit", "Kit"))
        XCTAssertFalse(NativePodName.isWithin("KitExtra/\u{301}Core", "Kit"))
        XCTAssertFalse(NativePodName.isWithin("Kit/\u{301}Core", "Kit/Core"))
    }

    func testDependencyRootPreservesScalarSeparatorsBeforeCombiningMarks() throws {
        for name in ["Kit/\u{301}Core", "Kit/\u{301}Core/\u{301}Nested"] {
            XCTAssertEqual(try NativeDependency(["name": name]).root, "Kit")
        }
    }

    func testRootNamesRejectSlashDotAndBackslashBeforeCombiningMarks() {
        for name in ["Kit/\u{301}Core", ".\u{301}Hidden", "Kit\\\u{301}Core"] {
            XCTAssertFalse(NativePodName.isValid(name), name)
        }
        XCTAssertTrue(NativePodName.isValid("\u{301}Kit"))
        XCTAssertTrue(NativePodName.isValid("Kit/\u{301}Core", subspecs: true))
    }

    func testNestedSubspecLookupAndInheritedAttributesRetainCombiningMarks() throws {
        let spec = try NativeSpec(data: [
            "name": "Kit", "version": "1.0", "compiler_flags": "-DROOT",
            "subspecs": [
                [
                    "name": "\u{301}Core", "compiler_flags": "-DCORE",
                    "subspecs": [["name": "\u{301}Nested", "source_files": "Nested.c"]],
                ]
            ],
        ])
        let name = "Kit/\u{301}Core/\u{301}Nested"
        XCTAssertEqual(try spec.nodes(name).count, 3)
        let attributes = try NativeVariantPlan.attributes(spec, names: [name], platform: "osx")
        XCTAssertEqual(nativeStrings(attributes["compiler_flags"]), ["-DROOT", "-DCORE"])
        XCTAssertEqual(nativeStrings(attributes["source_files"]), ["Nested.c"])
    }

    func testGraphRootQueriesIncludeUnicodeSubspecDescendants() throws {
        let name = "Kit/\u{301}Core"
        let report: [String: Any] = [
            "specs": [["name": name, "dependencies": []]],
            "targets": [["name": "Demo", "dependencies": [["name": "Kit", "requirement": ">= 0"]]]],
        ]
        let result = try DependencyGraph.why("Kit", report: report)
        XCTAssertEqual((result["dependency_chains"] as? [[String: Any]])?.count, 1)
    }

    func testInlineOptionsPreserveLeadingCombiningMarks() throws {
        var arguments = ["install", "--project-directory=\u{301}work", "--offline"]
        XCTAssertEqual(try CommandOptions.take("--project-directory", from: &arguments), "\u{301}work")
        XCTAssertEqual(arguments, ["install", "--offline"])
    }

    func testMixedInlineAndSplitDuplicateOptionsAreRejected() {
        var arguments = ["--project-directory=\u{301}work", "--project-directory", "other"]
        XCTAssertThrowsError(try CommandOptions.take("--project-directory", from: &arguments)) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-CLI-ARGUMENT")
        }
    }
}
