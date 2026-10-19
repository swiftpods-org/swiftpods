import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeRuntimePathBoundaryTests: XCTestCase {
    private func bundle(_ extra: String) throws -> RuntimeBundle {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var files: [String: [String: String]] = [:]
        for name in ["host/dsl.rb", extra] {
            let file = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let contents = Data("fixture".utf8)
            try contents.write(to: file)
            files[name] = ["sha256": digest(contents)]
        }
        #if arch(arm64)
            let architecture = "arm64"
        #else
            let architecture = "x86_64"
        #endif
        let manifest: [String: Any] = [
            "schema_version": 1, "engine": "swift", "status": "prototype", "files": files,
            "runtime": ["mode": "external"], "minimum_macos": "13.0", "native_ruby_libraries": [],
            "build_host": ["architecture": architecture],
        ]
        try jsonData(manifest).write(to: root.appendingPathComponent("compatibility.json"))
        return try RuntimeBundle(root: root)
    }

    func testRuntimeInventoryAcceptsAnOrdinaryUnicodeFile() throws {
        XCTAssertNoThrow(try bundle("\u{301}payload.txt").verify())
    }

    func testCachePathPreservesExplicitValuesAndTheirPriority() throws {
        let runtime = try bundle("payload.txt")
        for path in ["relative cache", "", "/tmp/cache-$literal", "\u{301}cache"] {
            let environment = ["SWIFTPODS_CACHE_ROOT": path, "CP_CACHE_DIR": "legacy", "HOME": "/tmp/home"]
            XCTAssertEqual(runtime.cacheRootPath(from: environment), path)
            XCTAssertEqual(runtime.environment(from: environment)["SWIFTPODS_CACHE_ROOT"], path)
        }
    }

    func testCachePathUsesLegacyOverrideBeforeHomeDirectory() throws {
        let runtime = try bundle("payload.txt")
        let environment = ["CP_CACHE_DIR": "relative legacy", "HOME": "/tmp/home"]
        XCTAssertEqual(runtime.cacheRootPath(from: environment), "relative legacy")
        XCTAssertEqual(runtime.environment(from: environment)["SWIFTPODS_CACHE_ROOT"], "relative legacy")
    }

    func testDefaultCachePathUsesHomeAndRuntimeProfile() throws {
        let runtime = try bundle("payload.txt")
        var manifest = runtime.manifest
        manifest["id"] = "selected-profile"
        try jsonData(manifest).write(to: runtime.root.appendingPathComponent("compatibility.json"))
        let selected = try RuntimeBundle(root: runtime.root)
        let environment = ["HOME": "/tmp/user home"]
        XCTAssertEqual(runtime.cacheRootPath(from: environment), "/tmp/user home/Library/Caches/SwiftPods/baseline")
        XCTAssertEqual(
            selected.cacheRootPath(from: environment), "/tmp/user home/Library/Caches/SwiftPods/selected-profile")
        XCTAssertEqual(
            selected.environment(from: environment)["SWIFTPODS_CACHE_ROOT"], selected.cacheRootPath(from: environment))
    }

    func testRuntimeDirectoryCannotHideFilesBehindCombiningMarks() throws {
        XCTAssertThrowsError(try bundle("runtime/\u{301}ruby").verify()) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-RUNTIME-PROFILE")
        }
    }

    func testVendorDirectoryCannotHideFilesBehindCombiningMarks() throws {
        XCTAssertThrowsError(try bundle("vendor/\u{301}engine.rb").verify()) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-RUNTIME-ENGINE")
        }
    }

    func testGemsDirectoryCannotHideFilesBehindCombiningMarks() throws {
        XCTAssertThrowsError(try bundle("gems/\u{301}engine.rb").verify()) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-RUNTIME-ENGINE")
        }
    }

    func testBundledRubyIsRejectedBeforeItsProbeCanRun() throws {
        let fixture = try bundle("\u{301}ruby")
        let executable = fixture.root.appendingPathComponent("\u{301}ruby")
        let marker = fixture.root.appendingPathComponent("probe-ran")
        #if arch(arm64)
            let architecture = "arm64"
        #else
            let architecture = "x86_64"
        #endif
        let metadata = String(
            decoding: try jsonData([
                "engine": "ruby", "version": "3.4.11", "abi": "3.4.0", "architecture": architecture,
                "platform": "fixture", "library": "",
            ]), as: UTF8.self)
        let script =
            "#!/bin/sh\nprintf ran > " + NativeShellString.quote(marker.path) + "\nprintf '%s\\n' "
            + NativeShellString.quote(metadata) + "\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let policy: [String: Any] = [
            "runtime": [
                "mode": "external", "minimum_version": "3.4.0", "maximum_version_exclusive": "3.5.0", "abi": "3.4.0",
            ],
            "build_host": ["architecture": architecture], "native_ruby_libraries": [],
        ]
        XCTAssertThrowsError(
            try ExternalRuby.locate(
                manifest: policy, environment: ["SWIFTPODS_RUBY": executable.path], bundleRoot: fixture.root)
        ) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-RUBY-PATH")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}
