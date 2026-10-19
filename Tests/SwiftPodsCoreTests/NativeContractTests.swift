import XCTest

@testable import SwiftPodsCore

final class NativeContractTests: XCTestCase {
    func testCXXDriverDoesNotLinkItsStandardLibraryTwice() {
        let sources = [URL(fileURLWithPath: "/SDK/Bridge.mm")]
        XCTAssertEqual(
            NativeBuildSettings.libraryFlags(["c++", "z"], sources: sources, settings: [:], linkingWithClang: true),
            ["-lz"])
        XCTAssertEqual(
            NativeBuildSettings.libraryFlags(["c++", "z"], sources: sources, settings: [:], linkingWithClang: false),
            ["-lc++", "-lz"])
        for settings in [
            ["LINK_WITH_STANDARD_LIBRARIES": "NO"], ["LDPLUSPLUS": "custom-driver"], ["LD": "custom-driver"],
            ["CLANG_CXX_LIBRARY": "other-library"],
        ] {
            XCTAssertEqual(
                NativeBuildSettings.libraryFlags(["c++"], sources: sources, settings: settings, linkingWithClang: true),
                ["-lc++"])
        }
    }
    func testCAndSwiftTargetsKeepExplicitCXXRuntimeDependencies() {
        for language in ["c", "m", "swift"] {
            XCTAssertEqual(
                NativeBuildSettings.libraryFlags(
                    ["c++"], sources: [URL(fileURLWithPath: "/SDK/Bridge." + language)], settings: [:],
                    linkingWithClang: true), ["-lc++"])
        }
    }

    func testSwiftVersionUsesIntersectionAndHighestCompatibleSpecVersion() throws {
        let spec = try NativeSpec(data: [
            "name": "Kit", "version": "1", "swift_versions": ["4.2", "5.0", "5.9", "6.0"],
        ])
        XCTAssertEqual(
            try NativeSwiftVersion.select(
                spec: spec,
                targets: [
                    ["name": "A", "swift_version_requirements": [">= 5"]],
                    ["name": "B", "swift_version_requirements": ["< 6"]],
                ]), "5.9")
        XCTAssertThrowsError(
            try NativeSwiftVersion.select(
                spec: spec,
                targets: [
                    ["name": "A", "swift_version_requirements": ["< 5"]],
                    ["name": "B", "swift_version_requirements": [">= 6"]],
                ])
        ) { XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-SWIFT-VERSION-CONFLICT") }
        XCTAssertEqual(
            try NativeSwiftVersion.select(
                spec: NativeSpec(data: ["name": "Legacy", "version": "1"]), targets: [["swift_version": "5.0"]]), "5.0")
    }
    func testIdenticalConsumersMustShareSwiftVersionAndDeduplicationCanBeDisabled() throws {
        let spec = try NativeSpec(data: ["name": "Kit", "version": "1", "swift_versions": ["5.0", "6.0"]])
        let a: [String: Any] = [
            "name": "A", "platform": ["name": "osx", "deployment_target": "13.0"], "dependencies": [["name": "Kit"]],
            "swift_version_requirements": ["= 5.0"],
        ]
        var b = a
        b["name"] = "B"
        b["swift_version_requirements"] = ["= 6.0"]
        let resolution = NativeResolution(specs: ["Kit": spec], requests: [])
        XCTAssertThrowsError(try NativeVariantPlan(manifest: ["targets": [a, b]], resolution: resolution))
        let plan = try NativeVariantPlan(
            manifest: ["targets": [a, b], "options": ["deduplicate_targets": false]], resolution: resolution)
        XCTAssertEqual(plan.variants.count, 2)
        XCTAssertEqual(Set(plan.variants.values.compactMap(\.swiftVersion)), ["5.0", "6.0"])
    }
    func testHeaderMappingRetainsNestedPathsAndRejectsEscapes() throws {
        let root = URL(fileURLWithPath: "/tmp/Headers")
        XCTAssertEqual(
            try NativeFileRules.headerPath(
                root.appendingPathComponent("include/A/Common.h"), attributes: ["header_mappings_dir": "include"],
                root: root), "A/Common.h")
        XCTAssertThrowsError(
            try NativeFileRules.headerPath(
                root.appendingPathComponent("private/Secret.h"), attributes: ["header_mappings_dir": "include"],
                root: root))
        XCTAssertThrowsError(try NativeFileRules.headerDirectory(["header_dir": "../escape"], module: "Kit"))
    }
    func testOnDemandResourcesPreserveCategoriesAndMergeTagsPerFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("resource".utf8).write(to: root.appendingPathComponent("data.txt"))
        let value = try NativeOnDemandResources(
            attributes: [
                "on_demand_resources": [
                    "first": ["paths": "*.txt", "category": "initial_install"],
                    "next": ["paths": ["data.txt"], "category": "prefetched"],
                ]
            ], root: root)
        XCTAssertEqual(value.files[root.appendingPathComponent("data.txt")], ["first", "next"])
        XCTAssertEqual(value.buildSettings["ON_DEMAND_RESOURCES_INITIAL_INSTALL_TAGS"] as? String, "first")
        XCTAssertEqual(value.buildSettings["ON_DEMAND_RESOURCES_PREFETCH_ORDER"] as? String, "next")
        XCTAssertThrowsError(
            try NativeOnDemandResources(
                attributes: ["on_demand_resources": ["bad": ["paths": "data.txt", "category": "unknown"]]], root: root))
    }
    func testLintRequiresValidMetadataAndReportsLicenseWarnings() throws {
        XCTAssertThrowsError(try NativeValidation.metadata(NativeSpec(data: ["name": "Kit", "version": "1"])))
        let data: [String: Any] = [
            "name": "Kit", "version": "1", "summary": "A library.", "authors": "SwiftPods",
            "homepage": "https://swiftpods.org", "source": ["git": "https://example.org/kit.git"],
        ]
        XCTAssertEqual(
            try NativeValidation.metadata(NativeSpec(data: data)),
            ["Missing license", "Git sources should specify a tag"])
        XCTAssertEqual(try NativeValidation.metadata(NativeSpec(data: data), privateSpec: true), ["Missing license"])
        var invalid = data
        invalid["homepage"] = "invalid"
        XCTAssertThrowsError(try NativeValidation.metadata(NativeSpec(data: invalid)))
    }
    func testSubspecSourcesAreNotInheritedButBuildOptionsAre() throws {
        let spec = try NativeSpec(data: [
            "name": "Kit", "version": "1.0", "source_files": "Root/*.c", "frameworks": ["Foundation"],
            "pod_target_xcconfig": ["FLAG": "root"],
            "subspecs": [["name": "Child", "source_files": "Child/*.c", "pod_target_xcconfig": ["FLAG": "child"]]],
        ])
        let attributes = try spec.attributes("Kit/Child", platform: "osx")
        XCTAssertEqual(nativeStrings(attributes["source_files"]), ["Child/*.c"])
        XCTAssertEqual(nativeStrings(attributes["frameworks"]), ["Foundation"])
        XCTAssertEqual((attributes["pod_target_xcconfig"] as? [String: String])?["FLAG"], "root child")
        let plan = try NativeVariantPlan(
            manifest: [
                "targets": [
                    [
                        "name": "App", "dependencies": [["name": "Kit/Child"]],
                        "platform": ["name": "osx", "deployment_target": "13.0"],
                    ]
                ]
            ], resolution: NativeResolution(specs: ["Kit": spec], requests: []))
        let variant = try XCTUnwrap(plan.variants.values.first)
        XCTAssertEqual(variant.names, ["Kit/Child"])
        XCTAssertEqual(
            nativeStrings(
                try NativeVariantPlan.attributes(spec, names: variant.names, platform: "osx")["source_files"]),
            ["Child/*.c"])
    }
    func testDirectorySourcePatternsAndExcludedDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources/Excluded"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Sources/Good.c", "Sources/Good.hxx", "Sources/Excluded/Bad.c", "Sources/data.txt"] {
            try Data("fixture".utf8).write(to: root.appendingPathComponent(path))
        }
        XCTAssertEqual(
            try NativeFileSelection.sourceFiles(
                ["source_files": "Sources", "exclude_files": "Sources/Excluded"], root: root
            ).map(\.lastPathComponent), ["Good.c", "Good.hxx"])
    }
    func testTargetedUpdatesUnlockTransitiveDependenciesInLegacyLocks() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        try Data(
            "PODS:\n  - 'A (1.0)':\n    - 'B (>= 1)'\n  - 'B (1.0)':\n    - 'C/Sub (= 1.0)'\n  - 'C/Sub (1.0)'\n  - 'Other (2.0)'\n\nCOCOAPODS: 1.16.2\n"
                .utf8
        ).write(to: path)
        let lock = try NativeLock(path)
        XCTAssertEqual(lock.unlocked(["A"]), ["A", "B", "C"])
        XCTAssertEqual(lock.versions["Other"], "2.0")
    }
    func testUnknownAttributesInvalidPatternsAndNewerProfilesFailExplicitly() throws {
        XCTAssertThrowsError(try NativeSpec(data: ["name": "Kit", "version": "1", "unsupported_feature": true])) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-SPEC-ATTRIBUTE")
        }
        XCTAssertThrowsError(try NativeSpec(data: ["name": "Kit", "version": "1", "source_files": ["*.c", 12]]))
        XCTAssertThrowsError(
            try NativeSpec(data: ["name": "Kit", "version": "1", "cocoapods_version": ">= 1.18"]).validateProfile()
        ) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-SPEC-PROFILE")
        }
        XCTAssertThrowsError(try NativeSpec(data: ["name": "Kit", "version": "1", "module_name": "invalid-name"]))
        XCTAssertEqual(
            try NativeSpec(data: ["name": "Kit", "version": "1", "header_dir": "PublicKit"]).moduleName, "PublicKit")
    }
}
