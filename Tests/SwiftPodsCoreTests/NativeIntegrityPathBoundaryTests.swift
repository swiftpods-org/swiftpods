import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeIntegrityPathBoundaryTests: XCTestCase {
    private func fixture() throws -> (URL, ArtifactIntegrity) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".swiftpods"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Pods"), withIntermediateDirectories: true)
        try Data("fixture lock\n".utf8).write(to: root.appendingPathComponent("Podfile.lock"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, ArtifactIntegrity(project: root))
    }

    private func source(_ name: String, root: URL) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("original\n".utf8).write(to: directory.appendingPathComponent("Payload.txt"))
        return directory
    }

    private func report(_ name: String, root: URL) throws -> [String: Any] {
        [
            "lock_digest": try FileFingerprint.file(root.appendingPathComponent("Podfile.lock")),
            "specs": [["name": name, "version": "1.0", "local": false]],
        ]
    }

    func testRecordedUnicodePodRootVerifies() throws {
        let (root, integrity) = try fixture()
        _ = try source("Pods/\u{301}Kit", root: root)
        _ = try integrity.record(report: report("\u{301}Kit", root: root))
        XCTAssertEqual(try integrity.verify()["status"] as? String, "passed")
    }

    func testTraversalBeforeCombiningMarkCannotSealAnOutsideTree() throws {
        let (root, integrity) = try fixture()
        _ = try source("\u{301}Outside", root: root)
        let path = "Pods/../\u{301}Outside"
        let record: [String: Any] = [
            "schema_version": 1,
            "lock_sha256": try FileFingerprint.file(root.appendingPathComponent("Podfile.lock")),
            "artifacts": [["path": path, "sha256": try FileFingerprint.tree(root.appendingPathComponent(path))]],
        ]
        try jsonData(record).write(to: integrity.path)
        XCTAssertThrowsError(try integrity.verify()) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-INTEGRITY-PATH")
        }
    }

    func testEscapingRootAliasCannotReplaceAnExistingIntegrityLock() throws {
        let (root, integrity) = try fixture()
        _ = try source("Pods/Kit", root: root)
        _ = try integrity.record(report: report("Kit", root: root))
        let before = try Data(contentsOf: integrity.path)
        let outside = try source("\u{301}Outside", root: root)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Pods/Alias"), withDestinationURL: outside)
        XCTAssertThrowsError(try integrity.record(report: report("Alias", root: root))) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-INTEGRITY-PATH")
        }
        XCTAssertEqual(try Data(contentsOf: integrity.path), before)
    }

    func testContainedRootAliasSealsItsSourceContents() throws {
        let (root, integrity) = try fixture()
        let actual = try source("Pods/Actual", root: root)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Pods/Alias"), withDestinationURL: actual)
        _ = try integrity.record(report: report("Alias", root: root))
        XCTAssertEqual(try integrity.verify()["status"] as? String, "passed")
        try Data("external edit\n".utf8).write(to: actual.appendingPathComponent("Payload.txt"))
        XCTAssertThrowsError(try integrity.verify()) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-INTEGRITY-CONTENT")
        }
    }

    func testMissingUnicodePodCanBeReportedForRestore() throws {
        let (root, integrity) = try fixture()
        let pod = try source("Pods/\u{301}Kit", root: root)
        _ = try integrity.record(report: report("\u{301}Kit", root: root))
        try FileManager.default.removeItem(at: pod)
        let result = try integrity.verify(allowMissing: true)
        XCTAssertEqual(result["status"] as? String, "requires_restore")
        XCTAssertEqual(nativeStrings(result["missing_artifacts"]), ["Pods/\u{301}Kit"])
    }
}
