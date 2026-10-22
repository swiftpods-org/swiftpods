import Darwin
import XCTest

@testable import SwiftPodsCore

final class ContentStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testSymlinkInputPublishesAnIndependentRegularSnapshotWithoutChangingSourcePermissions() throws {
        let root = try directory()
        let source = root.appendingPathComponent("source")
        let alias = root.appendingPathComponent("alias")
        let original = Data("immutable archive\n".utf8)
        try original.write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: source.path)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let store = try ContentStore(cacheRoot: root.appendingPathComponent("cache"))
        let origin = ["pod": "Kit"]
        _ = try store.put(file: alias, origin: origin)
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? NSNumber)?.intValue,
            0o640)
        let entry = try store.get(origin: origin)
        XCTAssertEqual(entry["status"] as? String, "hit")
        let object = URL(fileURLWithPath: try XCTUnwrap(entry["path"] as? String))
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: object.path)[.type] as? FileAttributeType, .typeRegular)
        try Data("changed source\n".utf8).write(to: source)
        try FileManager.default.removeItem(at: alias)
        XCTAssertEqual(try Data(contentsOf: object), original)
        XCTAssertEqual(try store.get(origin: origin)["status"] as? String, "hit")
        XCTAssertEqual(try store.verify()["status"] as? String, "passed")
    }

    func testDirectoriesDanglingLinksAndNamedPipesAreRejectedBeforeReadingOrPublishing() throws {
        let root = try directory()
        let pipe = root.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        let alias = root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "missing")
        let store = try ContentStore(cacheRoot: root.appendingPathComponent("cache"))
        for source in [root, alias, pipe] {
            XCTAssertThrowsError(try store.put(file: source, origin: ["pod": "Kit"])) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-CACHE-SOURCE")
            }
        }
        XCTAssertEqual(try store.get(origin: ["pod": "Kit"])["status"] as? String, "miss")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("objects").path))
    }
}
