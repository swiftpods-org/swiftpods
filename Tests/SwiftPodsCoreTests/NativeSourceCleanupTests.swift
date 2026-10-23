import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeSourceCleanupTests: XCTestCase {
    private func directory(_ names: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for name in names {
            let path = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(name.utf8).write(to: path)
        }
        return root
    }

    private func link(_ name: String, to target: String, in root: URL) throws {
        let path = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: target)
    }

    private func finalize(_ root: URL, attributes: [String: Any]) throws {
        let pod = root.appendingPathComponent("Pod")
        let spec = try NativeSpec(
            data: ["name": "Kit", "version": "1.0"].merging(attributes) { _, value in value }, directory: pod)
        let sources = try NativeSources(
            project: root, cache: root.appendingPathComponent("cache"), sources: [], dsl: nil,
            offline: true, refreshRepositories: false, hardened: false)
        sources.installationOptions["lock_pod_sources"] = false
        let request = try NativeDependency(["name": "Kit"], platform: "osx", deployment: "13.0")
        try sources.finalize(["Kit": spec], requests: [request])
    }

    func testSelectedHeaderRetainsRelativeAndAbsoluteLinkChains() throws {
        for absolute in [false, true] {
            let root = try directory(["Pod/\u{301}Real/Kit.h", "Pod/\u{301}Real/unused.txt", "Pod/unused.txt"])
            let pod = root.appendingPathComponent("Pod")
            try link("Links/Actual.h", to: "../\u{301}Real/Kit.h", in: pod)
            try link(
                "Kit.h", to: absolute ? pod.appendingPathComponent("Links/Actual.h").path : "Links/Actual.h", in: pod)
            try finalize(root, attributes: ["source_files": "Kit.h"])
            XCTAssertEqual(
                try Data(contentsOf: pod.appendingPathComponent("Kit.h")), Data("Pod/\u{301}Real/Kit.h".utf8))
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(
                    atPath: pod.appendingPathComponent("Links/Actual.h").path),
                "../\u{301}Real/Kit.h")
            for unused in ["unused.txt", "\u{301}Real/unused.txt"] {
                XCTAssertFalse(FileManager.default.fileExists(atPath: pod.appendingPathComponent(unused).path))
            }
        }
    }

    func testPreservedDirectoriesRetainTheirNestedLinkTargets() throws {
        let root = try directory(["Pod/Real/payload.bin", "Pod/Real/unused.bin", "Pod/unused.txt"])
        let pod = root.appendingPathComponent("Pod")
        try link("Resources/Group/payload.bin", to: "../../Links/Actual.bin", in: pod)
        try link("Links/Actual.bin", to: "../Real/payload.bin", in: pod)
        try finalize(root, attributes: ["preserve_paths": "Resources"])
        XCTAssertEqual(
            try Data(contentsOf: pod.appendingPathComponent("Resources/Group/payload.bin")),
            Data("Pod/Real/payload.bin".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pod.appendingPathComponent("Real/unused.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pod.appendingPathComponent("unused.txt").path))
    }

    func testParentTraversalKeepsThePhysicalDirectoryAndIntermediateLinks() throws {
        let root = try directory(["Pod/Layouts/Real/Kit.h", "Pod/Layouts/Present/marker.txt", "Pod/unused.txt"])
        let pod = root.appendingPathComponent("Pod")
        try link("Current", to: "Layouts/Present", in: pod)
        try link("Kit.h", to: "Current/../Real/Kit.h", in: pod)
        try finalize(root, attributes: ["source_files": "Kit.h"])
        XCTAssertEqual(
            try Data(contentsOf: pod.appendingPathComponent("Kit.h")), Data("Pod/Layouts/Real/Kit.h".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pod.appendingPathComponent("unused.txt").path))
    }

    func testSelectedEscapingAndCyclicLinksFailBeforeCleanup() throws {
        for cyclic in [false, true] {
            let root = try directory(["Pod/unused.txt", "Outside.h"])
            let pod = root.appendingPathComponent("Pod")
            try link("Kit.h", to: cyclic ? "Kit.h" : "../Outside.h", in: pod)
            XCTAssertThrowsError(try finalize(root, attributes: ["preserve_paths": "Kit.h"])) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-INTEGRITY-SYMLINK")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: pod.appendingPathComponent("unused.txt").path))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Outside.h")), Data("Outside.h".utf8))
        }
    }

    func testPreservedDirectoryMayContainAnInternalDanglingLink() throws {
        let root = try directory(["Pod/unused.txt"])
        let pod = root.appendingPathComponent("Pod")
        try link("Resources/optional", to: "../Missing/optional", in: pod)
        try finalize(root, attributes: ["preserve_paths": "Resources"])
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: pod.appendingPathComponent("Resources/optional").path),
            "../Missing/optional")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pod.appendingPathComponent("unused.txt").path))
    }
}
