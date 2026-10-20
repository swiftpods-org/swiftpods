import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeSubspecFileTests: XCTestCase {
    private func directory(_ files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for name in files {
            let path = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: path)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testCompilerFlagsRetainCommonInheritanceAndIsolateSiblingValues() throws {
        let root = try directory(["A/A.c", "B/B.cpp"])
        let spec = try NativeSpec(
            data: [
                "name": "Kit", "version": "1.0", "compiler_flags": "-DROOT=1",
                "subspecs": [
                    ["name": "A", "source_files": "A/*", "compiler_flags": "-DCHOICE=1"],
                    ["name": "B", "source_files": "B/*", "compiler_flags": "-DCHOICE=2"],
                ],
            ], directory: root)
        let files = try NativeLibraryFiles(spec: spec, names: ["Kit", "Kit/A", "Kit/B"], platform: "osx", root: root)
        XCTAssertEqual(files.compilerFlags, ["-DROOT=1"])
        for (path, expected, unwanted) in [
            ("A/A.c", "-DCHOICE=1", "-DCHOICE=2"), ("B/B.cpp", "-DCHOICE=2", "-DCHOICE=1"),
        ] {
            let flags = try XCTUnwrap(
                files.sourceSettings(root.appendingPathComponent(path))["COMPILER_FLAGS"] as? String)
            XCTAssertTrue(flags.contains(expected))
            XCTAssertFalse(flags.contains(unwanted))
        }
    }

    func testARCBoolsAndMasksApplyToEachOwnersObjectiveCSources() throws {
        let root = try directory(["A/Modern.m", "B/Manual.M", "B/ARC.mm", "B/Plain.c"])
        let spec = try NativeSpec(
            data: [
                "name": "Kit", "version": "1.0", "requires_arc": true,
                "subspecs": [
                    ["name": "A", "source_files": "A/*"],
                    ["name": "B", "source_files": "B/*", "requires_arc": ["B/ARC.mm"]],
                ],
            ], directory: root)
        let files = try NativeLibraryFiles(spec: spec, names: ["Kit/A", "Kit/B"], platform: "osx", root: root)
        for (path, flag) in [("A/Modern.m", "-fobjc-arc"), ("B/ARC.mm", "-fobjc-arc"), ("B/Manual.M", "-fno-objc-arc")]
        {
            XCTAssertEqual(files.sourceSettings(root.appendingPathComponent(path))["COMPILER_FLAGS"] as? String, flag)
        }
        XCTAssertNil(files.sourceSettings(root.appendingPathComponent("B/Plain.c"))["COMPILER_FLAGS"])
    }

    func testExclusionsCannotRemoveAnotherOwnersSourcesResourcesOrBundleFiles() throws {
        let root = try directory(["A/A.c", "A/Excluded.c", "A/a.txt", "B/B.c", "B/b.txt"])
        let spec = try NativeSpec(
            data: [
                "name": "Kit", "version": "1.0",
                "subspecs": [
                    [
                        "name": "A", "source_files": "A/*.c", "exclude_files": ["A/Excluded.c", "B/*"],
                        "resources": "A/a.txt", "resource_bundles": ["Shared": "A/a.txt"],
                    ],
                    [
                        "name": "B", "source_files": "B/*.c", "resources": "B/b.txt",
                        "resource_bundles": ["Shared": "B/b.txt"],
                    ],
                ],
            ], directory: root)
        let files = try NativeLibraryFiles(spec: spec, names: ["Kit/A", "Kit/B"], platform: "osx", root: root)
        XCTAssertEqual(Set(files.files.map(\.lastPathComponent)), ["A.c", "B.c"])
        XCTAssertEqual(Set(try files.paths("resources").map(\.lastPathComponent)), ["a.txt", "b.txt"])
        XCTAssertEqual(Set(try files.resourceBundles()["Shared"]?.map(\.lastPathComponent) ?? []), ["a.txt", "b.txt"])
    }

    func testHeadersKeepTheirOwnersNamespaceMappingAndVisibility() throws {
        let root = try directory(["A/One/A.h", "B/Two/B.h"])
        let spec = try NativeSpec(
            data: [
                "name": "Kit", "version": "1.0",
                "subspecs": [
                    [
                        "name": "A", "source_files": "A/**/*.h", "header_dir": "Alpha", "header_mappings_dir": "A",
                        "private_header_files": ["A/**/*.h", "B/**/*.h"],
                    ],
                    ["name": "B", "source_files": "B/**/*.h", "header_dir": "Beta", "header_mappings_dir": "B"],
                ],
            ], directory: root)
        let files = try NativeLibraryFiles(spec: spec, names: ["Kit/A", "Kit/B"], platform: "osx", root: root)
        let a = root.appendingPathComponent("A/One/A.h")
        let b = root.appendingPathComponent("B/Two/B.h")
        XCTAssertEqual(try files.headerPath(a), "One/A.h")
        XCTAssertEqual(try files.headerPath(b), "Two/B.h")
        XCTAssertEqual(try files.headerDirectory(a, module: "Kit"), "Alpha")
        XCTAssertEqual(try files.headerDirectory(b, module: "Kit"), "Beta")
        XCTAssertEqual(files.headerSettings(a)["ATTRIBUTES"] as? [String], ["Private"])
        XCTAssertEqual(files.headerSettings(b)["ATTRIBUTES"] as? [String], ["Public"])
    }

    func testWrapperSourcesDoNotCompileHeadersFromASiblingsVendoredSDK() throws {
        let vendorHeader = "Kit.xcframework/device/Kit.framework/Headers/Kit.h"
        let root = try directory(["Wrapper.c", "Wrapper.h", vendorHeader])
        let spec = try NativeSpec(
            data: [
                "name": "Kit", "version": "1.0",
                "subspecs": [
                    ["name": "Binary", "vendored_frameworks": "Kit.xcframework"],
                    ["name": "Wrapper", "source_files": ["Wrapper.*", "Kit.xcframework/**/*.h"]],
                ],
            ], directory: root)
        let files = try NativeLibraryFiles(
            spec: spec, names: ["Kit/Binary", "Kit/Wrapper"], platform: "ios", root: root)
        XCTAssertEqual(Set(files.files.map(\.lastPathComponent)), ["Wrapper.c", "Wrapper.h"])
        XCTAssertEqual(files.publicHeaders, [root.appendingPathComponent("Wrapper.h")])
        // The Ruby FileAccessor still exposes the author's full source declaration.
        let attributes = try spec.attributes("Kit/Wrapper", platform: "ios")
        XCTAssertTrue(
            try NativeFileSelection.sourceFiles(attributes, root: root).contains(
                root.appendingPathComponent(vendorHeader)))
    }

    func testSelectingOnlyAChildDoesNotAddItsParentsNonInheritedFiles() throws {
        let root = try directory(["Root.c", "Child.c"])
        let spec = try NativeSpec(
            data: [
                "name": "Kit", "version": "1.0", "source_files": "Root.c",
                "header_dir": "Alias", "subspecs": [["name": "Child", "source_files": "Child.c"]],
            ], directory: root)
        let files = try NativeLibraryFiles(spec: spec, names: ["Kit/Child"], platform: "osx", root: root)
        XCTAssertEqual(files.files.map(\.lastPathComponent), ["Child.c"])
    }

    func testFrameworkProjectHeadersMayLiveOutsideThePublishedMapping() throws {
        let root = try directory(["Public/Kit.h", "Internal.h"])
        let spec = try NativeSpec(
            data: [
                "name": "Kit", "version": "1.0", "source_files": ["Public/*.h", "Internal.h"],
                "header_mappings_dir": "Public", "project_header_files": "Internal.h",
            ], directory: root)
        let engine = try generated(root: root, spec: spec, frameworks: "static")
        XCTAssertNoThrow(try engine.generate())
    }

    func testEquivalentHeaderDirectoriesCannotOverwriteDifferentHeaders() throws {
        let root = try directory(["A/Common.h", "B/Common.h"])
        let spec = try NativeSpec(
            data: [
                "name": "Kit", "version": "1.0",
                "subspecs": [
                    ["name": "A", "source_files": "A/*.h", "header_dir": "Alias//Nested"],
                    ["name": "B", "source_files": "B/*.h", "header_dir": "Alias/Nested"],
                ],
            ], directory: root)
        let engine = try generated(root: root, spec: spec)
        XCTAssertThrowsError(try engine.generate()) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-SPEC-HEADER-COLLISION")
        }
    }

    private func generated(root: URL, spec: NativeSpec, frameworks: String? = nil) throws -> NativeXcode {
        var target: [String: Any] = ["name": "Demo", "platform": ["name": "osx"], "dependencies": [["name": "Kit"]]]
        target["frameworks"] = frameworks
        let request = try NativeDependency(["name": "Kit"], platform: "osx", deployment: "13.0")
        return try NativeXcode(
            project: root, manifest: ["targets": [target]],
            resolution: NativeResolution(specs: ["Kit": spec], requests: [request]), integrateUserProjects: false)
    }

    func testFrameworkStyleCustomMapUsesTheSelectedChildHeaderNamespace() throws {
        let root = try directory(["Child/Feature.h"])
        let contents = "framework module Kit { header \"Feature.h\" export * }\n"
        try Data(contents.utf8).write(to: root.appendingPathComponent("Author.modulemap"))
        let spec = try NativeSpec(
            data: [
                "name": "Kit", "version": "1.0", "module_map": "Author.modulemap",
                "subspecs": [["name": "Child", "source_files": "Child/*.h", "header_dir": "Alias"]],
            ], directory: root)
        let request = try NativeDependency(["name": "Kit/Child"], platform: "osx", deployment: "13.0")
        let engine = try NativeXcode(
            project: root,
            manifest: [
                "targets": [["name": "Demo", "platform": ["name": "osx"], "dependencies": [["name": "Kit/Child"]]]]
            ],
            resolution: NativeResolution(specs: ["Kit": spec], requests: [request]), integrateUserProjects: false)
        try engine.generate()
        let map = try XCTUnwrap(engine.customModuleMaps["Kit:osx"])
        XCTAssertEqual(map.deletingLastPathComponent().lastPathComponent, "Alias")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: map.deletingLastPathComponent().appendingPathComponent("Feature.h").path))
        XCTAssertEqual(try String(contentsOf: map, encoding: .utf8), "module Kit { header \"Feature.h\" export * }\n")
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("Author.modulemap"), encoding: .utf8), contents)
    }
}
