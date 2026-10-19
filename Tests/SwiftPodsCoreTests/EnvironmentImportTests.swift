import Foundation
import XCTest

@testable import SwiftPodsCore

final class EnvironmentImportTests: XCTestCase {
    func testMissingGemfileDoesNotCreateState() throws {
        try withProject { root, project, bundle in
            try assertRejected(root, project, bundle, code: "SP-ENV-INPUT")
        }
    }

    func testMissingLockDoesNotCreateState() throws {
        try withProject { root, project, bundle in
            try Data().write(to: project.appendingPathComponent("Gemfile"))
            try assertRejected(root, project, bundle, code: "SP-ENV-INPUT")
        }
    }

    func testDirectoryGemfileDoesNotCreateState() throws {
        try withProject { root, project, bundle in
            try FileManager.default.createDirectory(
                at: project.appendingPathComponent("Gemfile"), withIntermediateDirectories: false)
            try assertRejected(root, project, bundle, code: "SP-ENV-INPUT")
        }
    }

    func testDirectoryLockDoesNotCreateState() throws {
        try withProject { root, project, bundle in
            try Data().write(to: project.appendingPathComponent("Gemfile"))
            try FileManager.default.createDirectory(
                at: project.appendingPathComponent("Gemfile.lock"), withIntermediateDirectories: false)
            try assertRejected(root, project, bundle, code: "SP-ENV-INPUT")
        }
    }

    func testStateSymlinksCannotWriteOutsideTheProject() throws {
        try assertSymlinksRejected(".swiftpods")
    }

    func testEnvironmentContainerSymlinksCannotWriteOutsideTheProject() throws {
        try assertSymlinksRejected(".swiftpods/environments")
    }

    func testProfileSymlinksAreRejectedIncludingDanglingLinks() throws {
        try assertSymlinksRejected(".swiftpods/environments/fixture")
    }

    func testLoadAlsoRejectsSymlinkedPrivateState() throws {
        try withProject { root, project, bundle in
            let outside = root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(
                at: project.appendingPathComponent(".swiftpods"), withDestinationURL: outside)
            XCTAssertThrowsError(
                try EnvironmentProfile.load(name: "fixture", project: project, bundle: bundle, environment: [:])
            ) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-ENV-PATH")
            }
        }
    }

    func testRuntimeFailureDoesNotCreateState() throws {
        try withProject { root, project, bundle in
            for name in ["Gemfile", "Gemfile.lock"] {
                try Data().write(to: project.appendingPathComponent(name))
            }
            try assertRejected(root, project, bundle, code: "SP-RUNTIME-PROFILE")
        }
    }

    func testSymlinkedGemfileIsReadBeforeDiagnosingItsMissingLock() throws {
        try withProject { root, project, bundle in
            let input = root.appendingPathComponent("input")
            try Data().write(to: input)
            try FileManager.default.createSymbolicLink(
                at: project.appendingPathComponent("Gemfile"), withDestinationURL: input)
            try assertRejected(root, project, bundle, code: "SP-ENV-INPUT")
        }
    }

    private func assertSymlinksRejected(_ path: String) throws {
        for dangling in [false, true] {
            try withProject { root, project, bundle in
                let outside = root.appendingPathComponent("outside")
                if !dangling {
                    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
                }
                let link = project.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
                try assertRejected(root, project, bundle, code: "SP-ENV-PATH")
            }
        }
    }

    private func assertRejected(_ root: URL, _ project: URL, _ bundle: RuntimeBundle, code: String) throws {
        let before = try FileFingerprint.tree(root)
        XCTAssertThrowsError(
            try EnvironmentProfile.importProfile(
                name: "fixture", gemfile: project.appendingPathComponent("Gemfile"), project: project,
                bundle: bundle, environment: [:], local: true)
        ) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, code)
        }
        XCTAssertEqual(try FileFingerprint.tree(root), before)
    }

    private func withProject(_ body: (URL, URL, RuntimeBundle) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        try jsonData(["schema_version": 1, "files": [String: [String: String]]()])
            .write(to: root.appendingPathComponent("compatibility.json"))
        try body(root, project, RuntimeBundle(root: root))
    }
}
