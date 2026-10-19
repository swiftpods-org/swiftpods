import XCTest

@testable import SwiftPodsCore

final class NativeResolverAuditTests: XCTestCase {
    func testInvalidJSONPodspecsDoNotPoisonTheTypedCache() throws {
        let cache = try directory()
        let podspecs = NativePodspecCache(cache: cache)
        for text in ["{", "{}", "[]", "{\"name\": 42}"] {
            XCTAssertThrowsError(try podspecs.project(Data(text.utf8))) { error in
                XCTAssertEqual((error as? Diagnostic)?.code, "SP-SPEC-SCHEMA")
            }
        }
        XCTAssertTrue(try podspecs.entries().isEmpty)
        XCTAssertEqual(try NativeCacheIntegrity.verify(cache)["status"] as? String, "passed")
        let listed = try NativeMaintenance.run(["cache", "list"], cache: cache)
        XCTAssertTrue((listed["entries"] as? [[String: Any]] ?? []).isEmpty)
        let cleaned = try NativeMaintenance.run(["cache", "clean", "--all"], cache: cache)
        XCTAssertEqual(cleaned["removed"] as? Int, 0)
    }

    func testMalformedEmptyRequirementClausesCannotRemoveConstraints() throws {
        for text in ["", ",", ">= 1,", ", >= 1", ">= 1,, < 3"] {
            XCTAssertThrowsError(try PodRequirement([text]), text) { error in
                XCTAssertEqual((error as? Diagnostic)?.code, "SP-SPEC-REQUIREMENT")
            }
        }
        XCTAssertTrue(try PodRequirement([]).accepts(PodVersion("0")))
        XCTAssertTrue(try PodRequirement([">= 1, < 3"]).accepts(PodVersion("2")))
        XCTAssertFalse(try PodRequirement([">= 1, < 3"]).accepts(PodVersion("3")))
    }

    func testSourceChecksumsAndArchiveTypeRejectNonStringValues() throws {
        for key in ["sha1", "sha256", "type"] {
            for value: Any in [true, 42, ["invalid"]] {
                XCTAssertThrowsError(try NativeDependency(["name": "Kit", "options": [key: value]])) { error in
                    XCTAssertEqual((error as? Diagnostic)?.code, "SP-DSL-POD-OPTION")
                }
                XCTAssertThrowsError(try NativeSpec(data: ["name": "Kit", "version": "1.0", "source": [key: value]]))
            }
        }
        _ = try NativeSpec(data: ["name": "Kit", "version": "1.0", "source": ["sha256": NSNull()]])
    }

    func testVCSRevisionNormalizesIntegersAndRejectsBooleansAndFractions() throws {
        let numeric = try NativeDependency(["name": "Kit", "options": ["revision": 0]])
        XCTAssertEqual(numeric.options["revision"] as? String, "0")
        let large = try NativeSourceOptions.revision(NSNumber(value: UInt64.max), file: "Kit")
        XCTAssertEqual(large, "18446744073709551615")
        for value: Any in [true, 0.5, Double.nan, ["invalid"], ["invalid": 1]] {
            XCTAssertThrowsError(try NativeDependency(["name": "Kit", "options": ["revision": value]]))
            XCTAssertThrowsError(
                try NativeSpec(data: ["name": "Kit", "version": "1.0", "source": ["revision": value]]))
        }
        let absent = try NativeDependency(["name": "Kit", "options": ["revision": NSNull()]])
        XCTAssertNil(absent.options["revision"])
    }

    func testPrereleaseVersionsIgnoreTrailingReleaseZeros() throws {
        let versions = try ["1.a", "1.0.a", "01.00.0.a"].map(PodVersion.init)
        XCTAssertEqual(Set(versions).count, 1)
        XCTAssertEqual(versions[0], versions[1])
        XCTAssertEqual(versions[1], versions[2])
        XCTAssertNotEqual(versions[2], try PodVersion("01.00.0.a.0"))
        XCTAssertLessThan(try PodVersion("1.0.a"), try PodVersion("1.0.b"))
        XCTAssertLessThan(try PodVersion("1.0.a"), try PodVersion("1.0"))
    }

    func testPessimisticRequirementsExcludePrereleasesOfTheUpperRelease() throws {
        let requirement = try PodRequirement(["~> 1.2.3.a"])
        XCTAssertTrue(try requirement.accepts(PodVersion("1.2.3.b")))
        XCTAssertTrue(try requirement.accepts(PodVersion("1.2.9")))
        XCTAssertFalse(try requirement.accepts(PodVersion("1.3.a")))
        XCTAssertFalse(try requirement.accepts(PodVersion("1.3.0.a")))
        XCTAssertFalse(try requirement.accepts(PodVersion("1.3")))
    }

    func testPessimisticRequirementsCountDigitsAttachedToPrereleaseLetters() throws {
        let requirement = try PodRequirement(["~> 1.2.3a"])
        XCTAssertTrue(try requirement.accepts(PodVersion("1.2.9")))
        XCTAssertFalse(try requirement.accepts(PodVersion("1.3")))
        XCTAssertFalse(try requirement.accepts(PodVersion("1.9")))
    }

    func testPessimisticUpperBoundPreservesZeroPrecisionAndLargeComponents() throws {
        let zeroPrecision = try PodRequirement(["~> 1.2.0.0.a"])
        XCTAssertTrue(try zeroPrecision.accepts(PodVersion("1.2.0.9")))
        XCTAssertFalse(try zeroPrecision.accepts(PodVersion("1.2.1.a")))
        let large = try PodRequirement(["~> 1.9999999999999999999999999.0.a"])
        XCTAssertTrue(try large.accepts(PodVersion("1.9999999999999999999999999.9")))
        XCTAssertFalse(try large.accepts(PodVersion("1.10000000000000000000000000.a")))
    }

    func testResolverDoesNotSelectAPrereleaseAtThePessimisticUpperRelease() throws {
        let preview = try NativeSpec(data: ["name": "Kit", "version": "1.3.a"])
        let stable = try NativeSpec(data: ["name": "Kit", "version": "1.2.9"])
        let request = try NativeDependency(["name": "Kit", "requirements": ["~> 1.2.3.a"]])
        let result = try NativeResolver(candidates: { _ in [preview, stable] }).resolve([request])
        XCTAssertEqual(result.specs["Kit"]?.version.description, "1.2.9")
    }

    func testRemoteJSONPodspecRecognizesTheURLPathWithAQuery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        let url = "https://specs.example.org/Kit.podspec.json?token=example"
        let specFile = root.appendingPathComponent("Kit.podspec.json")
        try jsonData(["name": "Kit", "version": "1.0"]).write(to: specFile)
        do {
            let store = try ContentStore(cacheRoot: cache)
            _ = try store.put(
                file: specFile,
                origin: [
                    "url": Redactor(environment: ProcessInfo.processInfo.environment).scrub(url),
                    "request_identity": digest(Data(url.utf8)),
                    "kind": "native-download",
                ])
        }
        let sources = try NativeSources(
            project: root, cache: cache, sources: [], dsl: nil, offline: true, refreshRepositories: false,
            hardened: true)
        let request = try NativeDependency(["name": "Kit", "options": ["podspec": url]])
        try sources.register([request])
        let result = try sources.candidates(request)
        XCTAssertEqual(result.first?.name, "Kit")
        XCTAssertEqual(result.first?.version.description, "1.0")
    }

    func testTypedJSONPodspecCacheParticipatesInInspectionAndCleanup() throws {
        let cache = try directory()
        let podspecs = NativePodspecCache(cache: cache)
        let file = try podspecs.project(jsonData(["name": "Kit", "version": "1.0"]))
        XCTAssertEqual(file.pathExtension, "json")
        XCTAssertEqual(try readObject(file)["name"] as? String, "Kit")
        let verified = try NativeCacheIntegrity.verify(cache)
        XCTAssertEqual((verified["source_snapshots"] as? [String: Int])?["podspecs"], 1)
        let listed = try NativeMaintenance.run(["cache", "list", "Kit"], cache: cache)
        XCTAssertEqual((listed["entries"] as? [[String: Any]])?.count, 1)
        let cleaned = try NativeMaintenance.run(["cache", "clean", "Kit"], cache: cache)
        XCTAssertEqual(cleaned["removed"] as? Int, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testTypedJSONPodspecCacheRejectsExternalChanges() throws {
        let cache = try directory()
        let podspecs = NativePodspecCache(cache: cache)
        let content = try jsonData(["name": "Kit", "version": "1.0"])
        let file = try podspecs.project(content)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try jsonData(["name": "Kit", "version": "2.0"]).write(to: file)
        XCTAssertThrowsError(try podspecs.project(content)) { error in
            XCTAssertEqual((error as? Diagnostic)?.code, "SP-CACHE-INTEGRITY")
        }
        XCTAssertThrowsError(try NativeCacheIntegrity.verify(cache))
    }

    func testTypedJSONPodspecCacheRejectsSymlinksEvenWithMatchingContent() throws {
        let cache = try directory()
        let podspecs = NativePodspecCache(cache: cache)
        let content = try jsonData(["name": "Kit", "version": "1.0"])
        let file = try podspecs.project(content)
        let outside = try directory().appendingPathComponent("Outside.podspec.json")
        try content.write(to: outside)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        XCTAssertThrowsError(try podspecs.project(content))
        XCTAssertThrowsError(try NativeCacheIntegrity.verify(cache))
    }

    func testArchiveFlattensAWrapperWithAChildOfTheSameName() throws {
        let root = try directory()
        let input = root.appendingPathComponent("input")
        let payload = input.appendingPathComponent("release/release/Kit.swift")
        try FileManager.default.createDirectory(
            at: payload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("public struct Kit {}".utf8).write(to: payload)
        let archive = root.appendingPathComponent("Kit.tar")
        try command("/usr/bin/tar", ["-cf", archive.path, "-C", input.path, "release"])
        let destination = root.appendingPathComponent("extracted")
        try NativeArchive.extract(archive, source: [:], destination: destination, pod: "Kit")
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("release/Kit.swift"), encoding: .utf8),
            "public struct Kit {}")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.appendingPathComponent("release/release").path))
        let wrapped = root.appendingPathComponent("wrapped")
        try NativeArchive.extract(archive, source: ["flatten": false], destination: wrapped, pod: "Kit")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: wrapped.appendingPathComponent("release/release/Kit.swift").path))
    }

    func testArchiveRejectsInvalidChecksumBeforeCreatingTheDestination() throws {
        let root = try directory()
        let archive = root.appendingPathComponent("Kit.tar")
        try Data("not-an-archive".utf8).write(to: archive)
        for key in ["sha256", "sha1"] {
            let destination = root.appendingPathComponent(key)
            XCTAssertThrowsError(
                try NativeArchive.extract(archive, source: [key: "invalid"], destination: destination, pod: "Kit")
            ) { error in
                XCTAssertEqual((error as? Diagnostic)?.code, "SP-SOURCE-CHECKSUM")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }
}
