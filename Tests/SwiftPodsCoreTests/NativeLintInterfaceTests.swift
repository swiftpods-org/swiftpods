import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeLintInterfaceTests: XCTestCase {
    private func probe(
        _ data: [String: Any], files: [String], selection: String = "Kit", modular: Bool = false,
        inspect: ((NativeXcode) throws -> Void)? = nil
    ) throws -> (URL, String) {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = workspace.appendingPathComponent("Library")
        for name in files {
            let path = library.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: path)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: workspace) }
        var base: [String: Any] = ["name": "Kit", "version": "1.0"]
        if !modular { base["module_map"] = false }
        let spec = try NativeSpec(
            data: base.merging(data) { _, new in new },
            directory: library)
        try NativeLintConsumer.create(in: workspace, platform: "osx", minimum: "14.0")
        let request = try NativeDependency(["name": selection], platform: "osx", deployment: "14.0")
        let resolution = try NativeResolver(candidates: { _ in [spec] }).resolve([request])
        let engine = try NativeXcode(
            project: workspace,
            manifest: [
                "targets": [
                    [
                        "name": "Lint", "platform": ["name": "osx", "deployment_target": "14.0"],
                        "dependencies": [["name": selection, "options": ["modular_headers": modular]]],
                    ]
                ]
            ], resolution: resolution, integrateUserProjects: false)
        try engine.generate()
        _ = try engine.savePods()
        try inspect?(engine)
        let installed = workspace.appendingPathComponent("Pods/Local Podspecs/Kit.podspec.json")
        try FileManager.default.createDirectory(
            at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jsonData(spec.data).write(to: installed)
        let declarations = Set(resolution.requests.map(\.name)).sorted().map { "  - " + $0 + " (1.0)" }.joined(
            separator: "\n")
        try Data(("PODS:\n" + declarations + "\n").utf8).write(to: workspace.appendingPathComponent("Podfile.lock"))
        try NativeLintConsumer.writeProbe(in: workspace, spec: spec, platform: "osx")
        let graph = try NativePBX(workspace.appendingPathComponent("Lint.xcodeproj/project.pbxproj"), existing: true)
        let path = try XCTUnwrap(graph.objects[NativePBX.identifier("lint:probe")]?["path"] as? String)
        return (
            workspace.appendingPathComponent(path),
            try String(contentsOf: workspace.appendingPathComponent(path), encoding: .utf8)
        )
    }

    func testLintExclusionsCannotHideAnotherSubspecsPublicInterface() throws {
        let (_, contents) = try probe(
            [
                "subspecs": [
                    ["name": "A", "source_files": "A.h", "exclude_files": "B.h"],
                    ["name": "B", "source_files": "B.h"],
                ]
            ], files: ["A.h", "B.h"])
        XCTAssertEqual(contents, "#import <Kit/A.h>\n#import <Kit/B.h>\n")
    }

    func testLintPrivateMasksCannotHideAnotherSubspecsPublicInterface() throws {
        let (_, contents) = try probe(
            [
                "subspecs": [
                    ["name": "A", "source_files": "A.h", "private_header_files": "B.h"],
                    ["name": "B", "source_files": "B.h"],
                ]
            ], files: ["A.h", "B.h"])
        XCTAssertEqual(contents, "#import <Kit/A.h>\n#import <Kit/B.h>\n")
    }

    func testLintProjectMasksCannotHideAnotherSubspecsPublicInterface() throws {
        let (_, contents) = try probe(
            [
                "subspecs": [
                    ["name": "A", "source_files": "A.h", "project_header_files": "B.h"],
                    ["name": "B", "source_files": "B.h"],
                ]
            ], files: ["A.h", "B.h"])
        XCTAssertEqual(contents, "#import <Kit/A.h>\n#import <Kit/B.h>\n")
    }

    func testLintExplicitPublicMasksCannotReplaceAnotherSubspecsDefaults() throws {
        let (_, contents) = try probe(
            [
                "subspecs": [
                    ["name": "A", "source_files": "A.h", "public_header_files": "A.h"],
                    ["name": "B", "source_files": "B.h"],
                ]
            ], files: ["A.h", "B.h"])
        XCTAssertEqual(contents, "#import <Kit/A.h>\n#import <Kit/B.h>\n")
    }

    func testLintImportsEachOwnersHeaderNamespaceAndMapping() throws {
        let (_, contents) = try probe(
            [
                "subspecs": [
                    ["name": "A", "source_files": "A/**/*.h", "header_dir": "Alpha", "header_mappings_dir": "A"],
                    ["name": "B", "source_files": "B/**/*.h", "header_dir": "Beta", "header_mappings_dir": "B"],
                ]
            ], files: ["A/Nested/A.h", "B/Nested/B.h"])
        XCTAssertEqual(contents, "#import <Alpha/Nested/A.h>\n#import <Beta/Nested/B.h>\n")
    }

    func testLintUsesObjectiveCPlusPlusForCPlusPlusSourcesAndHeaderOnlyLibraries() throws {
        for filename in [
            "Value.cpp", "Value.cc", "Value.cxx", "Value.c++", "Value.C", "Value.mm", "Value.M", "Value.hpp",
            "Value.hxx", "Value.hh", "Value.ipp", "Value.tpp",
        ] {
            let (path, _) = try probe(["source_files": ["Kit.h", filename]], files: ["Kit.h", filename])
            XCTAssertEqual(path.lastPathComponent, "Probe.mm", filename)
        }
    }

    func testPlainCObjectiveCAndSwiftProbesKeepTheirLanguage() throws {
        for (filename, expected) in [("Value.c", "Probe.m"), ("Value.m", "Probe.m"), ("Value.swift", "Probe.swift")] {
            let (path, _) = try probe(["source_files": ["Kit.h", filename]], files: ["Kit.h", filename])
            XCTAssertEqual(path.lastPathComponent, expected)
        }
    }

    func testUnselectedParentAndHiddenCPlusPlusHeadersDoNotEnterTheProbe() throws {
        let (path, contents) = try probe(
            [
                "source_files": "Root.hpp",
                "subspecs": [
                    [
                        "name": "Child", "source_files": ["Child.h", "Private.hpp", "Project.hpp"],
                        "private_header_files": "Private.hpp", "project_header_files": "Project.hpp",
                    ]
                ],
            ], files: ["Root.hpp", "Child.h", "Private.hpp", "Project.hpp"], selection: "Kit/Child")
        XCTAssertEqual(path.lastPathComponent, "Probe.m")
        XCTAssertEqual(contents, "#import <Kit/Child.h>\n")
    }

    func testSwiftImportTakesPrecedenceInMixedLanguageLibraries() throws {
        let (path, contents) = try probe(
            ["source_files": ["Value.swift", "Value.cpp", "Kit.hpp"]], files: ["Value.swift", "Value.cpp", "Kit.hpp"])
        XCTAssertEqual(path.lastPathComponent, "Probe.swift")
        XCTAssertEqual(contents, "import Kit\n")
    }

    func testCPlusPlusModuleImportsEnableTheCompilerModuleLanguage() throws {
        let (path, contents) = try probe(["source_files": "Kit.hpp"], files: ["Kit.hpp"], modular: true)
        XCTAssertEqual(contents, "@import Kit;\n")
        let graph = try NativePBX(
            path.deletingLastPathComponent().appendingPathComponent("Lint.xcodeproj/project.pbxproj"), existing: true)
        let configurations = graph.objects.values.filter {
            ($0["buildSettings"] as? [String: Any])?["PRODUCT_NAME"] as? String == "Lint"
        }
        XCTAssertFalse(configurations.isEmpty)
        for configuration in configurations {
            let settings = configuration["buildSettings"] as? [String: Any] ?? [:]
            XCTAssertEqual(
                settings["CLANG_DISABLE_CXX_MODULES"] as? String, "NO")
            XCTAssertTrue(nativeStrings(settings["OTHER_CPLUSPLUSFLAGS"]).contains("-fcxx-modules"))
            XCTAssertTrue(nativeStrings(settings["OTHER_CPLUSPLUSFLAGS"]).contains("$(inherited)"))
        }
    }

    func testGeneratedModuleWithAnAliasedHeaderDirectoryReachesAllConsumerCompilers() throws {
        _ = try probe(
            ["source_files": "Kit.h", "module_name": "Kit", "header_dir": "Alias"], files: ["Kit.h"], modular: true
        ) { engine in
            let consumer = try XCTUnwrap((engine.manifest["targets"] as? [[String: Any]])?.first)
            engine.selectConsumer(consumer)
            var settings: [String: Any] = [:]
            engine.applyCustomModuleMaps(["Kit"], platform: "osx", settings: &settings)
            for key in ["OTHER_CFLAGS", "OTHER_CPLUSPLUSFLAGS", "OTHER_SWIFT_FLAGS"] {
                let flags = nativeStrings(settings[key]).joined(separator: " ")
                XCTAssertTrue(flags.contains("-fmodule-map-file="), key)
                XCTAssertTrue(flags.contains("/Alias/module.modulemap"), key)
            }
        }
    }
}
