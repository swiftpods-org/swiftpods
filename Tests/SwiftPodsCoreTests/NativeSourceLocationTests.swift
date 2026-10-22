import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeSourceLocationTests: XCTestCase {
    func testSVNRevisionPinsPathIdentityAndPreservesExplicitPegs() {
        for (url, expected) in [
            ("file:///repo/trunk", "file:///repo/trunk@2"),
            ("https://user@example.invalid/repo/trunk", "https://user@example.invalid/repo/trunk@2"),
            ("file:///repo/trunk@", "file:///repo/trunk@2"),
            ("file:///repo/name@literal@", "file:///repo/name@literal@2"),
            ("file:///repo/trunk@5", "file:///repo/trunk@5"),
            ("file:///repo/trunk@HEAD", "file:///repo/trunk@HEAD"),
            ("file:///repo/trunk@\u{301}5", "file:///repo/trunk@\u{301}5"),
        ] {
            XCTAssertEqual(NativeVCS.svnPeggedURL(url, revision: "2"), expected)
        }
    }

    func testLocalGitSourcesUseProjectIdentityAndRemoteSyntaxIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = try NativeSources(
            project: root, cache: root.appendingPathComponent("cache"), sources: [], dsl: nil, offline: true,
            refreshRepositories: false, hardened: false)
        XCTAssertEqual(sources.gitLocation("./Kit"), root.appendingPathComponent("Kit").path)
        XCTAssertEqual(sources.gitLocation("Sub/../Kit"), root.appendingPathComponent("Kit").path)
        XCTAssertEqual(sources.gitLocation("./Kit:Local"), root.appendingPathComponent("Kit:Local").path)
        for remote in [
            "https://example.invalid/Kit.git", "ssh://git@example.invalid/Kit.git", "git@example.invalid:Kit.git",
            "file:///tmp/Kit.git",
        ] {
            XCTAssertEqual(sources.gitLocation(remote), remote)
        }
    }

    func testHardenedManifestDiscoveryIgnoresRubyFilesAndDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Podfile.json"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("Podfile"))
        XCTAssertNil(NativePodfilePath.find(in: root, hardened: true))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Podfile.json"))
        try Data().write(to: root.appendingPathComponent("Podfile.json"))
        XCTAssertEqual(NativePodfilePath.find(in: root, hardened: true)?.lastPathComponent, "Podfile.json")
    }
}
