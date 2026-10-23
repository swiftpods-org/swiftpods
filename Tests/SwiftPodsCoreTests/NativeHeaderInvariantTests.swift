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
        explicit: Bool = false, framework: Bool = false
    ) throws -> NativeXcode {
        let root = try directory()
        var specs: [String: NativeSpec] = [:]
        for (name, module) in zip(["First", "Second"], names) {
            let source = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("#pragma once\n".utf8).write(to: source.appendingPathComponent(name + ".h"))
            try Data(("int " + name.lowercased() + "(void) { return 7; }\n").utf8).write(
                to: source.appendingPathComponent(name + ".c"))
            specs[name] = try NativeSpec(
                data: ["name": name, "version": "1.0", "module_name": module, "source_files": "*.{c,h}"],
                directory: source)
        }
        let targets: [[String: Any]] = consumers.enumerated().map { index, dependencies in
            var target: [String: Any] = [
                "name": "App" + String(index), "platform": ["name": "osx", "deployment_target": "13.0"],
                "modular_headers": !explicit,
                "dependencies": dependencies.map { name -> [String: Any] in
                    explicit ? ["name": name, "options": ["modular_headers": true]] : ["name": name]
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
}
