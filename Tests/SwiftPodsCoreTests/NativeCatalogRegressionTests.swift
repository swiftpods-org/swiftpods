import XCTest

@testable import SwiftPodsCore

final class NativeCatalogRegressionTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testRegisteredCatalogKeepsOneRevisionWhileAnotherOperationRefreshesIt() throws {
        let root = try directory()
        let repository = root.appendingPathComponent("specs")
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try command("/usr/bin/git", ["init", "-b", "main", repository.path])
        func publish(_ name: String, _ version: String) throws {
            let path = repository.appendingPathComponent(name + "/" + version + "/" + name + ".podspec.json")
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try jsonData(["name": name, "version": version]).write(to: path)
            try command("/usr/bin/git", ["-C", repository.path, "add", "."])
            try command(
                "/usr/bin/git",
                [
                    "-C", repository.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@swiftpods.org",
                    "-c", "commit.gpgsign=false", "commit", "-m", "catalog",
                ])
        }
        try publish("Kit", "1.0")
        try publish("Helper", "1.0")
        _ = try NativeRepositories(cache: cache).add(name: "catalog", url: repository.path, branch: "main")
        let first = try NativeSources(
            project: root, cache: cache, sources: [repository.path], dsl: nil,
            offline: false, refreshRepositories: false, hardened: false)
        XCTAssertEqual(try first.candidates(NativeDependency(["name": "Kit"])).map(\.version.description), ["1.0"])
        try publish("Helper", "2.0")
        let second = try NativeSources(
            project: root, cache: cache, sources: [repository.path], dsl: nil,
            offline: false, refreshRepositories: true, hardened: false)
        XCTAssertEqual(
            Set(try second.candidates(NativeDependency(["name": "Helper"])).map(\.version.description)), ["1.0", "2.0"])
        XCTAssertEqual(try first.candidates(NativeDependency(["name": "Helper"])).map(\.version.description), ["1.0"])
    }

    func testRepositoryRefreshPreservesCachedPayloadOfUnchangedRoots() throws {
        let root = try directory()
        let cache = root.appendingPathComponent("cache")
        let location = "http://127.0.0.1:1/Kit.zip"
        let archive = root.appendingPathComponent("archive")
        let bytes = Data("locked source bytes".utf8)
        try bytes.write(to: archive)
        _ = try ContentStore(cacheRoot: cache).put(
            file: archive,
            origin: [
                "url": location, "request_identity": digest(Data(location.utf8)),
                "kind": "native-download", "pod": "Kit",
            ])
        let catalog = try NativeSources(
            project: root, cache: cache, sources: [], dsl: nil,
            offline: false, refreshRepositories: true, hardened: false)
        XCTAssertEqual(try Data(contentsOf: catalog.download(location, pod: "Kit")), bytes)
        catalog.updating = true
        catalog.updateRoots = ["Other"]
        XCTAssertEqual(try Data(contentsOf: catalog.download(location, pod: "Kit")), bytes)
    }

    func testGlobBraceOrderNeverSelectsImplicitDotfiles() throws {
        let root = try directory()
        for name in ["Kit.c", "Other.c", ".hidden.c", "Prefix.hidden.c"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        let visible = Set(["Kit.c", "Other.c", "Prefix.hidden.c"])
        for pattern in ["{Kit,*}.c", "{*,Kit}.c", "{,Kit}*.c", "{{Kit,Other},*}.c", "{Kit,{Other,*}}.c"] {
            XCTAssertEqual(Set(try nativeGlob(pattern, root: root).map(\.lastPathComponent)), visible, pattern)
        }
        XCTAssertEqual(Set(try nativeGlob("{Kit,.*}.c", root: root).map(\.lastPathComponent)), ["Kit.c", ".hidden.c"])
        XCTAssertEqual(try nativeGlob("Prefix*.c", root: root).map(\.lastPathComponent), ["Prefix.hidden.c"])
    }

    func testGlobAlternativesRespectNestedDirectoryBoundaries() throws {
        let root = try directory()
        for name in ["Sources/Kit.h", "Sources/.hidden.h", "Other/Other.h", ".hidden/Private.h"] {
            let path = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: path)
        }
        for pattern in ["{Sources,Other}/**/{Kit,*}.h", "{Sources,Other}/**/{*,Kit}.h", "**/{Kit,*}.h"] {
            XCTAssertEqual(Set(try nativeGlob(pattern, root: root).map(\.lastPathComponent)), ["Kit.h", "Other.h"])
        }
    }

    func testSchemaRejectsTypesInUnselectedChildrenAndPlatformAttributes() throws {
        let invalid: [[String: Any]] = [
            ["subspecs": [["name": "Core", "source_files": 42]]],
            ["subspecs": [["name": "Core", "subspecs": [["name": "Nested", "resources": 42]]]]],
            ["testspecs": [["name": "Tests", "test_type": ["invalid": true]]]],
            ["appspecs": [["name": "App", "osx": ["source_files": false]]]],
        ]
        for item in invalid {
            let data: [String: Any] = ["name": "Kit", "version": "1.0"]
            XCTAssertThrowsError(try NativeSpec(data: data.merging(item) { _, value in value })) { error in
                XCTAssertEqual((error as? Diagnostic)?.code, "SP-SPEC-ATTRIBUTE-TYPE")
                XCTAssertTrue((error as? Diagnostic)?.file?.hasPrefix("Kit/") == true)
            }
        }
        XCTAssertNoThrow(
            try NativeSpec(data: [
                "name": "Kit", "version": "1.0",
                "subspecs": [["name": "Core", "source_files": ["Core.c"]]],
                "testspecs": [["name": "Tests", "test_type": "ui"]],
            ]))
    }

    func testUnicodePodIdentityDoesNotRelaxPathValidation() throws {
        for name in ["École", "E\u{301}cole", "東京", "Kit-2.0+Core"] {
            XCTAssertEqual(try NativeSpec(data: ["name": name, "version": "1.0"]).name, name)
            XCTAssertEqual(try NativeDependency(["name": name + "/子"]).root, name)
        }
        for name in ["", "..", "Kit/..", "Kit//Core", "Kit/", "/Kit", "Kit/Core Two", "Kit\\Core", "Kit\nOther"] {
            XCTAssertThrowsError(try NativeDependency(["name": name]), name)
        }
        XCTAssertThrowsError(try NativeSpec(data: ["name": "Kit/Core", "version": "1.0"]))
    }

    func testGeneratedRubyStringRoundTripsQuotesBackslashesAndInterpolation() throws {
        let values = ["Demo's App", "slash\\'quote", "trailing\\", "#{raise 'interpolated'}", "École\nCore"]
        let ruby = try ToolProcess.run(
            "/usr/bin/ruby",
            ["-rjson", "-e", "puts JSON.generate(ARGV.map { |value| eval(value) })", "--"]
                + values.map(NativeRubyString.quote))
        XCTAssertEqual(ruby.status, 0, String(decoding: ruby.error, as: UTF8.self))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: ruby.output) as? [String], values)
        XCTAssertEqual(NativeLock.quote("Demo's App"), "'Demo''s App'")
    }

    func testShellFlagsPreserveApostrophesAndLiteralSubstitutionText() throws {
        for value in ["User's Library", "a\\b", "$(printf expanded)", "`printf expanded`", "a\nb"] {
            let result = try ToolProcess.run("/bin/sh", ["-c", "printf '%s' " + NativeShellString.quote(value)])
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.output, Data(value.utf8))
        }
    }

    func testOutdatedDistinguishesManifestConstraintFromLatestVersion() throws {
        let root = try directory()
        let repository = root.appendingPathComponent("specs")
        for version in ["1.0", "2.0", "3.0.pre"] {
            let path = repository.appendingPathComponent("Kit/" + version + "/Kit.podspec.json")
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try jsonData(["name": "Kit", "version": version]).write(to: path)
        }
        let lockPath = root.appendingPathComponent("Podfile.lock")
        try Data("PODS:\n  - Kit (1.0)\n".utf8).write(to: lockPath)
        let catalog = try NativeSources(
            project: root, cache: root.appendingPathComponent("cache"), sources: [repository.path], dsl: nil,
            offline: true, refreshRepositories: false, hardened: false)
        let request = try NativeDependency(["name": "Kit", "requirements": ["< 2"]])
        let spec = try NativeSpec(data: ["name": "Kit", "version": "1.0"], repository: repository.path)
        let resolution = NativeResolution(specs: ["Kit": spec], requests: [request])
        let lock = try NativeLock(lockPath)
        let all = try NativeOutdated.pods(lock: lock, resolution: resolution, catalog: catalog, ignorePrerelease: false)
        XCTAssertEqual(all, [["name": "Kit", "installed": "1.0", "available": "1.0", "latest": "3.0.pre"]])
        let stable = try NativeOutdated.pods(
            lock: lock, resolution: resolution, catalog: catalog, ignorePrerelease: true)
        XCTAssertEqual(stable.first?["latest"], "2.0")
        try Data("PODS:\n  - Kit (3.0.pre)\n".utf8).write(to: lockPath)
        XCTAssertTrue(
            try NativeOutdated.pods(
                lock: NativeLock(lockPath), resolution: resolution, catalog: catalog, ignorePrerelease: true
            ).isEmpty)
    }
}
