import XCTest

@testable import SwiftPodsCore

final class NativePublicationPathTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testNormalPublicationPathIsAcceptedWithoutCreatingFiles() throws {
        let root = try directory()
        try NativePublication.validateDestination(root.appendingPathComponent("Kit/1.0/Kit.podspec.json"), in: root)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testPublicationRejectsExternalInternalAndDanglingParentSymlinks() throws {
        for kind in ["external", "internal", "dangling"] {
            let root = try directory()
            let target = kind == "external" ? try directory() : root.appendingPathComponent("Target")
            if kind == "internal" { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true) }
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Kit"), withDestinationURL: target)
            XCTAssertThrowsError(try NativePublication.validateDestination(root.appendingPathComponent("Kit/1.0/Kit.podspec.json"), in: root)) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-REPO-PATH")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("1.0").path))
        }
    }

    func testPublicationRejectsPathsOutsideTheCheckoutAndSymlinkLeaves() throws {
        let root = try directory()
        let target = try directory().appendingPathComponent("file.json")
        XCTAssertThrowsError(try NativePublication.validateDestination(target, in: root))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("file.json"), withDestinationURL: target)
        XCTAssertThrowsError(try NativePublication.validateDestination(root.appendingPathComponent("file.json"), in: root))
        let alias = try directory().appendingPathComponent("Checkout")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        XCTAssertThrowsError(try NativePublication.validateDestination(alias.appendingPathComponent("Kit/1.0/Kit.podspec.json"), in: alias))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
}
