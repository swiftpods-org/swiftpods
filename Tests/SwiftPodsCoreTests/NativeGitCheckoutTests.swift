import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeGitCheckoutTests: XCTestCase {
    func testRemoteBranchCheckoutPreservesItsCommitForOfflineUse() throws {
        let (root, repository) = try repository()
        let cache = root.appendingPathComponent("cache")
        try git(repository, ["checkout", "-b", "sdk/release"])
        try Data("release".utf8).write(to: repository.appendingPathComponent("value"))
        try git(repository, ["commit", "-am", "Release"])
        let revision = try git(repository, ["rev-parse", "HEAD"])
        try git(repository, ["checkout", "main"])

        let online = try sources(root: root, cache: cache, offline: false)
        let checkout = try online.checkout(repository.path, selector: "sdk/release", pod: "Kit")
        XCTAssertEqual(try String(contentsOf: checkout.appendingPathComponent("value"), encoding: .utf8), "release")
        XCTAssertEqual(try NativeGitCache.verify(checkout)["commit"] as? String, revision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkout.appendingPathComponent(".git").path))
        XCTAssertEqual(try git(repository, ["branch", "--show-current"]), "main")

        let offline = try sources(root: root, cache: cache, offline: true)
        XCTAssertEqual(
            try offline.checkout(repository.path, selector: "sdk/release", pod: "Kit").standardizedFileURL.path,
            checkout.standardizedFileURL.path)
        let pinned = try offline.checkout(repository.path, selector: revision, pod: "Kit")
        XCTAssertEqual(try String(contentsOf: pinned.appendingPathComponent("value"), encoding: .utf8), "release")
    }

    func testTagKeepsPriorityOverARemoteBranchWithTheSameName() throws {
        let (root, repository) = try repository()
        try git(repository, ["tag", "release"])
        try git(repository, ["checkout", "-b", "release"])
        try Data("branch".utf8).write(to: repository.appendingPathComponent("value"))
        try git(repository, ["commit", "-am", "Branch"])
        try git(repository, ["checkout", "main"])

        let sources = try sources(root: root, cache: root.appendingPathComponent("cache"), offline: false)
        let checkout = try sources.checkout(repository.path, selector: "release", pod: "Kit")
        XCTAssertEqual(try String(contentsOf: checkout.appendingPathComponent("value"), encoding: .utf8), "main")
    }

    func testMissingRevisionDoesNotPublishAPartialCheckout() throws {
        let (root, repository) = try repository()
        let cache = root.appendingPathComponent("cache")
        let sources = try sources(root: root, cache: cache, offline: false)
        XCTAssertThrowsError(try sources.checkout(repository.path, selector: "missing", pod: "Kit")) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-SOURCE-REVISION")
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: cache.appendingPathComponent("git").path), [])
    }

    private func repository() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try git(repository, ["init", "-b", "main"])
        try git(repository, ["config", "user.name", "Fixture"])
        try git(repository, ["config", "user.email", "fixture@example.invalid"])
        try Data("main".utf8).write(to: repository.appendingPathComponent("value"))
        try git(repository, ["add", "value"])
        try git(repository, ["commit", "-m", "Main"])
        return (root, repository)
    }

    private func sources(root: URL, cache: URL, offline: Bool) throws -> NativeSources {
        try NativeSources(
            project: root, cache: cache, sources: [], dsl: nil, offline: offline,
            refreshRepositories: false, hardened: false)
    }

    @discardableResult
    private func git(_ directory: URL, _ arguments: [String]) throws -> String {
        let result = try ToolProcess.run(
            "/usr/bin/git", ["-c", "commit.gpgSign=false", "-C", directory.path] + arguments)
        guard result.status == 0 else {
            throw Diagnostic(
                "SP-TEST-GIT", stage: "test", String(decoding: result.error, as: UTF8.self))
        }
        return String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
