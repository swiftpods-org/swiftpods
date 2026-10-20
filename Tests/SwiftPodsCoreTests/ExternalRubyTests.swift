import Foundation
import XCTest

@testable import SwiftPodsCore

final class ExternalRubyTests: XCTestCase {
    private var architecture: String {
        #if arch(arm64)
            return "arm64"
        #else
            return "x86_64"
        #endif
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("bundle"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func manifest(_ runtime: [String: String]? = nil) -> [String: Any] {
        [
            "runtime": runtime ?? ["mode": "external", "minimum_version": "2.6.0"],
            "build_host": ["architecture": architecture], "native_ruby_libraries": [],
        ]
    }

    private func ruby(
        _ root: URL, directory: String = "interpreter", version: String = "2.6.10",
        metadata extra: [String: String] = [:], prelude: String = ""
    ) throws -> URL {
        let executable = root.appendingPathComponent(directory + "/ruby")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let metadata = [
            "engine": "ruby", "version": version, "abi": "2.6.0", "architecture": architecture,
            "platform": "fixture", "library": "",
        ].merging(extra) { _, new in new }
        let output = String(decoding: try jsonData(metadata), as: UTF8.self)
        let script = "#!/bin/sh\n" + prelude + "printf '%s\\n' " + NativeShellString.quote(output) + "\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private func locate(_ ruby: URL, root: URL, policy: [String: String]? = nil) throws -> ExternalRuby {
        try ExternalRuby.locate(
            manifest: manifest(policy), environment: ["SWIFTPODS_RUBY": ruby.path],
            bundleRoot: root.appendingPathComponent("bundle"))
    }

    func testRuby26DoesNotNeedTheBuildInterpretersABI() throws {
        let root = try root()
        let selected = try locate(ruby(root), root: root)
        XCTAssertEqual(selected.metadata["version"], "2.6.10")
        XCTAssertEqual(selected.metadata["abi"], "2.6.0")
    }

    func testNewerMajorVersionHasNoImplicitUpperBound() throws {
        let root = try root()
        let interpreter = try ruby(root, version: "4.0.5", metadata: ["abi": "4.0.0"])
        XCTAssertEqual(try locate(interpreter, root: root).metadata["version"], "4.0.5")
    }

    func testRubyBelow26IsRejected() throws {
        let root = try root()
        let interpreter = try ruby(root, version: "2.5.9")
        XCTAssertThrowsError(try locate(interpreter, root: root)) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-RUBY-VERSION")
        }
    }

    func testAnOlderProfileStillEnforcesItsExplicitUpperBoundAndABI() throws {
        let root = try root()
        let policy = [
            "mode": "external", "minimum_version": "3.4.11",
            "maximum_version_exclusive": "3.5.0", "abi": "3.4.0",
        ]
        let accepted = try ruby(root, version: "3.4.11", metadata: ["abi": "3.4.0"])
        XCTAssertNoThrow(try locate(accepted, root: root, policy: policy))
        for (version, abi) in [("3.5.0", "3.4.0"), ("3.4.11", "2.6.0")] {
            let rejected = try ruby(root, version: version, metadata: ["abi": abi])
            XCTAssertThrowsError(try locate(rejected, root: root, policy: policy)) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-RUBY-VERSION")
            }
        }
    }

    func testSystemRubyCPUAliasesMatchTheDistributionArchitecture() throws {
        let root = try root()
        let alias = architecture == "arm64" ? "aarch64" : "amd64"
        let interpreter = try ruby(root, metadata: ["architecture": alias])
        XCTAssertEqual(try locate(interpreter, root: root).metadata["architecture"], architecture)
    }

    func testAnExplicitInterpreterWithTheWrongArchitectureIsRejected() throws {
        let root = try root()
        let interpreter = try ruby(root, metadata: ["architecture": "wrong-arch"])
        XCTAssertThrowsError(try locate(interpreter, root: root)) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-RUBY-ARCH")
        }
    }

    func testAutomaticSelectionPrefersTheFirstCompatibleRubyFromPATH() throws {
        let root = try root()
        let first = try ruby(root, directory: "first")
        let second = try ruby(root, directory: "second", version: "4.0.5")
        let selected = try ExternalRuby.locate(
            manifest: manifest(),
            environment: [
                "PATH": first.deletingLastPathComponent().path + ":" + second.deletingLastPathComponent().path
            ],
            bundleRoot: root.appendingPathComponent("bundle"))
        XCTAssertEqual(selected.executable, first)
    }

    func testAutomaticSelectionSkipsAnUnsupportedRubyBeforeACompatibleOne() throws {
        let root = try root()
        let first = try ruby(root, directory: "first", version: "2.5.9")
        let second = try ruby(root, directory: "second")
        let selected = try ExternalRuby.locate(
            manifest: manifest(),
            environment: [
                "PATH": first.deletingLastPathComponent().path + ":" + second.deletingLastPathComponent().path
            ],
            bundleRoot: root.appendingPathComponent("bundle"))
        XCTAssertEqual(selected.executable, second)
    }

    func testAnExplicitUnsupportedRubyNeverFallsBackToPATH() throws {
        let root = try root()
        let rejected = try ruby(root, directory: "explicit", version: "2.5.9")
        let fallback = try ruby(root, directory: "fallback")
        XCTAssertThrowsError(
            try ExternalRuby.locate(
                manifest: manifest(),
                environment: ["SWIFTPODS_RUBY": rejected.path, "PATH": fallback.deletingLastPathComponent().path],
                bundleRoot: root.appendingPathComponent("bundle"))
        ) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-RUBY-VERSION")
        }
    }

    func testBundlerEnvironmentDoesNotReachTheExternalRubyProbe() throws {
        let root = try root()
        let prelude = """
            [ -z "${BUNDLER_SETUP+x}" ] || exit 21
            [ -z "${BUNDLE_GEMFILE+x}" ] || exit 22
            [ -z "${GEM_HOME+x}" ] || exit 23
            [ -z "${RUBYOPT+x}" ] || exit 24

            """
        let interpreter = try ruby(root, prelude: prelude)
        let selected = try ExternalRuby.locate(
            manifest: manifest(),
            environment: [
                "SWIFTPODS_RUBY": interpreter.path, "BUNDLER_SETUP": "/unavailable/setup.rb",
                "BUNDLE_GEMFILE": "/unavailable/Gemfile", "GEM_HOME": "/unavailable/gems", "RUBYOPT": "-rmissing",
            ], bundleRoot: root.appendingPathComponent("bundle"))
        XCTAssertEqual(selected.executable, interpreter)
    }
}
