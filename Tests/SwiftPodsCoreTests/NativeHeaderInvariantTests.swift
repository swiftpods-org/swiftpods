import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeHeaderInvariantTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func modules(
        _ names: [String], consumers: [[String]] = [["First", "Second"]],
        explicit: Bool = false, framework: Bool = false, modular: Bool = true,
        attributes: [String: Any] = [:], separateConfigurations: Bool = false
    ) throws -> NativeXcode {
        let root = try directory()
        var specs: [String: NativeSpec] = [:]
        for (name, module) in zip(["First", "Second"], names) {
            let source = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("#pragma once\n".utf8).write(to: source.appendingPathComponent(name + ".h"))
            try Data(("int " + name.lowercased() + "(void) { return 7; }\n").utf8).write(
                to: source.appendingPathComponent(name + ".c"))
            try Data("public func value() -> Int { 7 }\n".utf8).write(
                to: source.appendingPathComponent(name + ".swift"))
            try Data(("module " + module + " { header \"" + name + ".h\" export * }\n").utf8).write(
                to: source.appendingPathComponent("Author.modulemap"))
            specs[name] = try NativeSpec(
                data: ["name": name, "version": "1.0", "module_name": module, "source_files": "*.{c,h}"]
                    .merging(attributes) { _, new in new },
                directory: source)
        }
        let targets: [[String: Any]] = consumers.enumerated().map { index, dependencies in
            var target: [String: Any] = [
                "name": "App" + String(index), "platform": ["name": "osx", "deployment_target": "13.0"],
                "modular_headers": !explicit && modular,
                "dependencies": dependencies.enumerated().map { offset, name -> [String: Any] in
                    var options: [String: Any] = explicit ? ["modular_headers": true] : [:]
                    if separateConfigurations { options["configurations"] = [offset == 0 ? "Debug" : "Release"] }
                    if attributes["testspecs"] != nil { options["testspecs"] = ["Tests"] }
                    return ["name": name, "options": options]
                },
            ]
            if framework { target["frameworks"] = "static" }
            return target
        }
        let engine = try NativeXcode(
            project: root, manifest: ["targets": targets],
            resolution: NativeResolution(specs: specs, requests: []), integrateUserProjects: false)
        try engine.generate()
        return engine
    }

    func testModularStaticLibrariesRejectTheSameModuleInOneConsumer() throws {
        for explicit in [false, true] {
            XCTAssertThrowsError(try modules(["Shared", "Shared"], explicit: explicit)) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCODE-MODULE-CONFLICT")
            }
        }
    }

    func testDistinctStaticLibraryModulesRemainSupported() throws {
        XCTAssertNoThrow(try modules(["FirstModule", "SecondModule"]))
    }

    func testSeparateConsumersMayUseTheSameModuleFromDifferentLibraries() throws {
        XCTAssertNoThrow(try modules(["Shared", "Shared"], consumers: [["First"], ["Second"]]))
    }

    func testStaticFrameworkModuleConflictsRemainDiagnosed() throws {
        XCTAssertThrowsError(try modules(["Shared", "Shared"], framework: true)) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCODE-MODULE-CONFLICT")
        }
    }

    func testNonmodularAndDisabledStaticLibraryMapsMayShareNames() throws {
        XCTAssertNoThrow(try modules(["Shared", "Shared"], modular: false))
        XCTAssertNoThrow(try modules(["Shared", "Shared"], attributes: ["module_map": false]))
        XCTAssertNoThrow(
            try modules(
                ["Shared", "Shared"],
                attributes: ["module_map": false, "testspecs": [["name": "Tests", "source_files": "*.swift"]]]))
    }

    func testStaticLibraryModuleConflictsRespectConfigurations() throws {
        XCTAssertNoThrow(try modules(["Shared", "Shared"], separateConfigurations: true))
    }

    func testSwiftAndSpecDefinedLibraryModulesRejectConflicts() throws {
        let cases: [[String: Any]] = [
            ["source_files": "*.swift", "module_map": false],
            ["pod_target_xcconfig": ["DEFINES_MODULE": "YES"]],
            ["module_map": "Author.modulemap"],
            [
                "module_map": false,
                "pod_target_xcconfig": ["DEFINES_MODULE": "YES", "MODULEMAP_FILE": "Author.modulemap"],
            ],
        ]
        for attributes in cases {
            XCTAssertThrowsError(try modules(["Shared", "Shared"], modular: false, attributes: attributes)) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCODE-MODULE-CONFLICT")
            }
        }
    }

    private func headers(project: URL, source: URL) throws -> URL {
        let spec = try NativeSpec(
            data: [
                "name": "Kit", "version": "1.0", "source_files": "*.h", "public_header_files": "Public*.h",
            ], directory: source)
        let engine = try NativeXcode(
            project: project,
            manifest: [
                "targets": [
                    [
                        "name": "App", "platform": ["name": "osx", "deployment_target": "13.0"],
                        "dependencies": [["name": "Kit"]],
                    ]
                ]
            ], resolution: NativeResolution(specs: ["Kit": spec], requests: []), integrateUserProjects: false)
        try engine.generate()
        return project.appendingPathComponent(engine.headerDirectory("Kit", platform: "osx") + "/Kit")
    }

    private func fixture() throws -> (project: URL, source: URL) {
        let root = try directory()
        let source = root.appendingPathComponent("SDK")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("#define INTERNAL_API 7\n".utf8).write(to: source.appendingPathComponent("Internal.h"))
        return (root, source)
    }

    func testPublicHeaderSelectionAfterReinstallMatchesAFreshInstall() throws {
        let (project, source) = try fixture()
        let initial = try headers(project: project, source: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: initial.appendingPathComponent("Internal.h").path))
        try Data("#define PUBLIC_API 11\n".utf8).write(to: source.appendingPathComponent("PublicAPI.h"))
        let reinstalled = try headers(project: project, source: source)
        XCTAssertEqual(initial, reinstalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reinstalled.appendingPathComponent("PublicAPI.h").path))

        let fresh = try headers(project: directory(), source: source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.appendingPathComponent("Internal.h").path))
        XCTAssertEqual(
            FileManager.default.fileExists(atPath: reinstalled.appendingPathComponent("Internal.h").path),
            FileManager.default.fileExists(atPath: fresh.appendingPathComponent("Internal.h").path),
            "An obsolete public link must not expose a header excluded by the current public selection")
        XCTAssertEqual(
            try Data(contentsOf: source.appendingPathComponent("Internal.h")), Data("#define INTERNAL_API 7\n".utf8))
    }

    func testFreshExplicitPublicSelectionKeepsOtherHeadersUnpublished() throws {
        let (project, source) = try fixture()
        try Data("#define PUBLIC_API 11\n".utf8).write(to: source.appendingPathComponent("PublicAPI.h"))
        let publicRoot = try headers(project: project, source: source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: publicRoot.appendingPathComponent("Internal.h").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: publicRoot.appendingPathComponent("PublicAPI.h").path))
    }

    func testUnchangedPublicSelectionKeepsHeaderBytesAcrossReinstall() throws {
        let (project, source) = try fixture()
        let header = source.appendingPathComponent("PublicAPI.h")
        let original = Data("#define PUBLIC_API 11\n".utf8)
        try original.write(to: header)
        let first = try headers(project: project, source: source)
        let second = try headers(project: project, source: source)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: second.appendingPathComponent("PublicAPI.h")), original)
        XCTAssertEqual(try Data(contentsOf: header), original)
    }

    func testRemovedSourcesDoNotLeaveDanglingPublicOrPrivateHeaderLinks() throws {
        let (project, source) = try fixture()
        let publicRoot = try headers(project: project, source: source)
        let privateRoot = URL(
            fileURLWithPath: publicRoot.path.replacingOccurrences(of: "/Headers/Public/", with: "/Headers/Private/"))
        for root in [publicRoot, privateRoot] {
            XCTAssertNotNil(
                try? FileManager.default.destinationOfSymbolicLink(
                    atPath: root.appendingPathComponent("Internal.h").path))
        }
        try FileManager.default.removeItem(at: source.appendingPathComponent("Internal.h"))
        try Data("#define PUBLIC_API 11\n".utf8).write(to: source.appendingPathComponent("PublicAPI.h"))
        _ = try headers(project: project, source: source)
        for root in [publicRoot, privateRoot] {
            XCTAssertNil(
                try? FileManager.default.destinationOfSymbolicLink(
                    atPath: root.appendingPathComponent("Internal.h").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("PublicAPI.h").path))
        }
    }

    func testHeaderCleanupPreservesRegularFilesAndForeignLinksWithoutFollowingDirectories() throws {
        let (project, source) = try fixture()
        let publicRoot = try headers(project: project, source: source)
        let regular = publicRoot.appendingPathComponent("Notes.h")
        let bytes = Data("// Local notes\n".utf8)
        try bytes.write(to: regular)
        let external = try directory()
        let externalHeader = external.appendingPathComponent("External.h")
        try bytes.write(to: externalHeader)
        let foreign = publicRoot.appendingPathComponent("Foreign.h")
        try FileManager.default.createSymbolicLink(at: foreign, withDestinationURL: externalHeader)
        let nestedLink = external.appendingPathComponent("Keep.h")
        try FileManager.default.createSymbolicLink(
            at: nestedLink, withDestinationURL: source.appendingPathComponent("Internal.h"))
        let alias = publicRoot.appendingPathComponent("ForeignDirectory")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: external)
        let localDirectory = source.appendingPathComponent("Docs.h")
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        let localAlias = publicRoot.appendingPathComponent("LinkedDocs.h")
        try FileManager.default.createSymbolicLink(at: localAlias, withDestinationURL: localDirectory)
        let notes = source.appendingPathComponent("Notes.txt")
        try bytes.write(to: notes)
        let notesAlias = publicRoot.appendingPathComponent("SourceNotes.txt")
        try FileManager.default.createSymbolicLink(at: notesAlias, withDestinationURL: notes)
        try Data("#define PUBLIC_API 11\n".utf8).write(to: source.appendingPathComponent("PublicAPI.h"))
        _ = try headers(project: project, source: source)
        XCTAssertEqual(try Data(contentsOf: regular), bytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: foreign.path), externalHeader.path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), external.path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: localAlias.path), localDirectory.path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: notesAlias.path), notes.path)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: nestedLink.path),
            source.appendingPathComponent("Internal.h").path)
    }
}
