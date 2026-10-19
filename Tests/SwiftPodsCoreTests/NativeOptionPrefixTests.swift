import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeOptionPrefixTests: XCTestCase {
    private let flag = "-\u{301}fixture"

    func testLintRejectsCombiningMarkFlagsBeforeLoadingRuby() throws {
        try withFixture { _, project, _, bundle in
            for action in ["spec", "lib"] {
                XCTAssertThrowsError(
                    try NativeValidation(bundle: bundle, environment: [:], overrides: [:]).run(
                        action: action, arguments: [flag], project: project)
                ) { XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-CLI-ARGUMENT") }
            }
        }
    }

    func testExplicitRelativeHyphenFilenameStillReachesTheRuntime() throws {
        try withFixture { _, project, _, bundle in
            XCTAssertThrowsError(
                try NativeValidation(bundle: bundle, environment: [:], overrides: [:]).run(
                    action: "spec", arguments: ["./" + flag], project: project)
            ) { XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-RUNTIME-PROFILE") }
        }
    }

    func testUpdateRejectsCombiningMarkFlagsBeforeReadingThePodfile() throws {
        try withFixture { _, project, _, bundle in
            let result = NativeEngine(bundle: bundle).run(
                arguments: ["update", flag], environment: [:], machine: true, project: project)
            XCTAssertEqual(result.status, 1)
            XCTAssertEqual(
                result.events.first { $0["kind"] as? String == "diagnostic" }?["code"] as? String,
                "SP-CLI-ARGUMENT")
        }
    }

    func testPublicationRejectsInvalidOptionsBeforeReadingSpecsOrRepositories() throws {
        try withFixture { _, project, cache, bundle in
            for options in [["--unknown"], [flag], ["--platforms", "--local-only", "osx"]] {
                XCTAssertThrowsError(
                    try NativePublication.push(
                        arguments: ["fixture"] + options, project: project, bundle: bundle,
                        environment: ["SWIFTPODS_CACHE_ROOT": cache.path], overrides: [:])
                ) { XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-CLI-ARGUMENT") }
            }
        }
    }

    func testCacheActionsRejectCombiningMarkFlags() throws {
        try withFixture { _, _, cache, _ in
            for action in ["list", "clean"] {
                XCTAssertThrowsError(try NativeMaintenance.run(["cache", action, flag], cache: cache)) {
                    XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-CLI-ARGUMENT")
                }
            }
        }
    }

    func testRepositoryURLFlagsAreRejectedBeforeCreatingARegistry() throws {
        try withFixture { _, _, cache, _ in
            let repositories = NativeRepositories(cache: cache)
            XCTAssertThrowsError(try repositories.add(name: "fixture", url: flag, branch: nil)) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-REPO-URL")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: repositories.root.path))
        }
    }

    func testRepositoryBranchFlagsAreRejectedBeforeWritingAMetadataRecord() throws {
        try withFixture { _, _, cache, _ in
            let repositories = NativeRepositories(cache: cache)
            XCTAssertThrowsError(
                try repositories.add(name: "fixture", url: "https://example.invalid/", branch: flag, cdn: true)
            ) { XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-REPO-URL") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: repositories.root.path))
        }
    }

    func testRepositoryRecordsRejectFlagURLs() throws {
        try withFixture { _, _, cache, _ in
            let repositories = NativeRepositories(cache: cache)
            try repositories.write(["name": "fixture", "url": flag, "kind": "cdn"])
            XCTAssertThrowsError(try repositories.records()) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-REPO-RECORD")
            }
        }
    }

    func testGitCheckoutRejectsLocationFlagsBeforeLookingInTheCache() throws {
        try withSources { sources in
            XCTAssertThrowsError(try sources.checkout(flag, selector: "HEAD")) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-SOURCE-URL")
            }
        }
    }

    func testGitCheckoutRejectsRevisionFlagsBeforeLookingInTheCache() throws {
        try withSources { sources in
            XCTAssertThrowsError(try sources.checkout("./Kit", selector: flag)) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-SOURCE-URL")
            }
        }
    }

    func testExplicitRelativeGitPathsAndOrdinaryUnicodeSelectorsRemainValues() throws {
        try withSources { sources in
            for selector in ["HEAD", "\u{301}branch", "−branch"] {
                XCTAssertThrowsError(try sources.checkout("./" + flag, selector: selector)) {
                    XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-OFFLINE-MISSING")
                }
            }
        }
    }

    func testMercurialSnapshotRejectsLocationFlagsBeforeLookingInTheCache() throws {
        try withSources { sources in
            XCTAssertThrowsError(try sources.sourceSnapshot(["hg": flag], pod: "Kit")) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-SOURCE-URL")
            }
        }
    }

    func testVCSExportsRejectLocationFlagsBeforeInvokingTheTools() throws {
        try withFixture { root, _, _, _ in
            for kind in ["svn", "hg"] {
                let target = root.appendingPathComponent(kind)
                XCTAssertThrowsError(try NativeVCS.export([kind: flag], destination: target)) {
                    XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-SOURCE-URL")
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            }
        }
    }

    private func withSources(_ body: (NativeSources) throws -> Void) throws {
        try withFixture { _, project, cache, _ in
            let sources = try NativeSources(
                project: project, cache: cache, sources: [], dsl: nil, offline: true,
                refreshRepositories: false, hardened: false)
            try body(sources)
        }
    }

    private func withFixture(_ body: (URL, URL, URL, RuntimeBundle) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let cache = root.appendingPathComponent("cache")
        for directory in [project, cache] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        try jsonData(["schema_version": 1, "files": [String: [String: String]]()])
            .write(to: root.appendingPathComponent("compatibility.json"))
        try body(root, project, cache, RuntimeBundle(root: root))
    }
}
