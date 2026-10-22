import XCTest

@testable import SwiftPodsCore

final class NativeCacheCleanupTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func tree(_ cache: URL, _ kind: String, _ key: Character) throws -> URL {
        let path = cache.appendingPathComponent(kind + "/" + String(repeating: String(key), count: 64))
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: path.appendingPathComponent("Kit.c"))
        return path
    }

    func testCorruptPreparedPodDoesNotBlockOtherPodsAndCanBeRemoved() throws {
        let cache = try directory()
        let broken = try tree(cache, "prepared", "a")
        let healthy = try tree(cache, "prepared", "b")
        for (path, name) in [(broken, "Broken"), (healthy, "Healthy")] {
            try jsonData(["name": name, "version": "1.0", "fingerprint": FileFingerprint.tree(path)])
                .write(to: path.appendingPathExtension("json"))
        }
        try Data("corrupt".utf8).write(to: broken.appendingPathComponent("Kit.c"))
        XCTAssertThrowsError(try NativeCacheIntegrity.verify(cache))
        XCTAssertEqual(try NativeMaintenance.run(["cache", "clean", "Healthy"], cache: cache)["removed"] as? Int, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: broken.path))
        XCTAssertEqual(try NativeMaintenance.run(["cache", "clean", "Broken"], cache: cache)["removed"] as? Int, 1)
        XCTAssertEqual(try NativeCacheIntegrity.verify(cache)["status"] as? String, "passed")
    }

    func testCorruptSharedGitAndSnapshotPayloadsRetainOtherOwnersUntilTheirCleanup() throws {
        let cache = try directory()
        for kind in ["git", "snapshots"] {
            let path = try tree(cache, kind, "a")
            if kind == "git" {
                try NativeGitCache.write(path, metadata: [
                    "commit": String(repeating: "b", count: 40), "origin_identity": String(repeating: "c", count: 64),
                    "pod_names": ["Kit", "Peer"],
                ])
            } else {
                try NativeSnapshotCache.write(path, metadata: [
                    "checkout": ["http": "https://example.invalid/source.zip"], "pod_names": ["Kit", "Peer"],
                ])
            }
            try Data("corrupt".utf8).write(to: path.appendingPathComponent("Kit.c"))
        }
        XCTAssertEqual(try NativeMaintenance.run(["cache", "clean", "Kit"], cache: cache)["removed"] as? Int, 0)
        for kind in ["git", "snapshots"] {
            let path = cache.appendingPathComponent(kind + "/" + String(repeating: "a", count: 64))
            XCTAssertEqual(try readObject(path.appendingPathExtension("origin.json"))["pod_names"] as? [String], ["Peer"])
        }
        XCTAssertThrowsError(try NativeCacheIntegrity.verify(cache))
        XCTAssertEqual(try NativeMaintenance.run(["cache", "clean", "Peer"], cache: cache)["removed"] as? Int, 2)
        XCTAssertEqual(try NativeCacheIntegrity.verify(cache)["status"] as? String, "passed")
    }

    func testAllCleanupDiscardsUnreadableReceiptsButPreservesRepositoriesAndExternalSymlinkTargets() throws {
        let cache = try directory()
        for kind in ["git", "prepared", "snapshots"] {
            let path = try tree(cache, kind, "a")
            try Data("invalid receipt".utf8).write(to: path.appendingPathExtension("origin.json"))
        }
        let repository = cache.appendingPathComponent("repositories/private")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let external = try directory()
        try Data("keep".utf8).write(to: external.appendingPathComponent("keep"))
        try FileManager.default.createSymbolicLink(at: cache.appendingPathComponent("podspecs"), withDestinationURL: external)
        XCTAssertEqual(try NativeMaintenance.run(["cache", "clean", "--all"], cache: cache)["removed"] as? Int, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.path))
        XCTAssertEqual(try String(contentsOf: external.appendingPathComponent("keep"), encoding: .utf8), "keep")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: cache.appendingPathComponent("podspecs").path))
        XCTAssertEqual(try NativeCacheIntegrity.verify(cache)["status"] as? String, "passed")
    }

    func testSnapshotCleanupRecoversOwnersAcrossSelectorAndRevisionCopies() throws {
        for vcs in ["hg", "svn"] {
            let cache = try directory()
            let selector = try tree(cache, "snapshots", "a")
            let revision = try tree(cache, "snapshots", "b")
            let unrelated = try tree(cache, "snapshots", "c")
            for (path, owners, version) in [
                (selector, ["Kit", "Peer"], "1"), (revision, ["Kit"], "1"), (unrelated, ["Kit"], "2"),
            ] {
                try NativeSnapshotCache.write(path, metadata: [
                    "checkout": [vcs: "https://example.invalid/source", "revision": version], "pod_names": owners,
                ])
            }
            XCTAssertEqual(try NativeCacheCleanup.run(cache: cache, pod: "Kit"), 1)
            for path in [selector, revision] {
                XCTAssertEqual(try NativeSnapshotCache.verify(path)["pod_names"] as? [String], ["Peer"])
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: unrelated.path))
            XCTAssertEqual(try NativeCacheCleanup.run(cache: cache, pod: "Peer"), 2)
            XCTAssertEqual(try NativeCacheIntegrity.verify(cache)["status"] as? String, "passed")
        }
    }

    func testCorruptSharedArchiveCanBeRemovedWithoutDeletingAnotherPodsContent() throws {
        let cache = try directory()
        let file = cache.appendingPathComponent("source.zip")
        try Data("archive".utf8).write(to: file)
        let object: URL
        do {
            let store = try ContentStore(cacheRoot: cache)
            let first = try store.put(file: file, origin: ["pod": "Kit"])
            _ = try store.put(file: file, origin: ["pod": "Peer"])
            object = cache.appendingPathComponent("content/objects/" + (first["sha256"] as! String))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: object.path)
        try Data("corrupt".utf8).write(to: object)
        XCTAssertThrowsError(try NativeCacheIntegrity.verify(cache))
        XCTAssertEqual(try NativeMaintenance.run(["cache", "clean", "Kit"], cache: cache)["removed"] as? Int, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: object.path))
        XCTAssertEqual(try NativeMaintenance.run(["cache", "clean", "Peer"], cache: cache)["removed"] as? Int, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: object.path))
        XCTAssertEqual(try NativeCacheIntegrity.verify(cache)["status"] as? String, "passed")
    }
}
