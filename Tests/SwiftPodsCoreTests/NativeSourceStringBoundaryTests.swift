import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeSourceStringBoundaryTests: XCTestCase {
    func testDependencySourceStringsRejectNulBeforePathInterpretation() {
        for key in [
            "path", "podspec", "git", "http", "svn", "hg", "branch", "tag", "commit", "revision", "folder",
            "source", "project_name", "sha1", "sha256", "type",
        ] {
            var options: [String: Any] = ["git": "https://example.invalid/Kit.git"]
            options[key] = "before\0after"
            XCTAssertThrowsError(try NativeDependency(["name": "Kit", "options": options]), key) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-DSL-POD-OPTION")
            }
        }
    }

    func testPodspecSourceStringsRejectNulBeforePathInterpretation() {
        for key in [
            "git", "http", "svn", "hg", "branch", "tag", "commit", "revision", "folder", "sha1", "sha256", "type",
        ] {
            var source: [String: Any] = ["git": "https://example.invalid/Kit.git"]
            source[key] = "before\0after"
            XCTAssertThrowsError(try NativeSpec(data: ["name": "Kit", "version": "1.0", "source": source]), key) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-DSL-POD-OPTION")
            }
        }
    }

    func testSourceHeaderNamesAndValuesRejectNul() {
        for headers in [["X-Field\0Ignored": "value"], ["X-Field": "before\0after"]] {
            let source: [String: Any] = ["git": "https://example.invalid/Kit.git", "headers": headers]
            XCTAssertThrowsError(try NativeDependency(["name": "Kit", "options": source])) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-DSL-POD-OPTION")
            }
            XCTAssertThrowsError(try NativeSpec(data: ["name": "Kit", "version": "1.0", "source": source])) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-DSL-POD-OPTION")
            }
        }
    }

    func testGlobalSpecRepositoryRejectsNulBeforeCacheWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("cache")
        XCTAssertThrowsError(
            try NativeSources(
                project: directory, cache: cache, sources: ["./Specs\0Ignored"], dsl: nil,
                offline: true, refreshRepositories: false, hardened: false)
        ) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-DSL-POD-OPTION")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }

    func testLiteralPercentUnicodeAndNumericSelectorsRemainValid() throws {
        let path = "./Kit%00Ignored/\u{301}Folder"
        let dependency = try NativeDependency(["name": "Kit", "options": ["path": path]])
        XCTAssertEqual(dependency.options["path"] as? String, path)
        _ = try NativeSpec(data: [
            "name": "Kit", "version": "1.0",
            "source": ["git": "./Repo%00/\u{301}Kit", "tag": 1.0, "headers": ["X-Field": "literal%00=value"]],
        ])
        XCTAssertEqual(NativeSourceOptions.gitSelector(1.0), "1.0")
        XCTAssertEqual(try NativeSourceOptions.revision(42, file: "Kit"), "42")
    }
}
