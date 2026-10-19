import XCTest

@testable import SwiftPodsCore

final class NativeResolutionInputTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testExplicitSymbolicGitCommitUsesLockUntilItsRootIsUpdated() throws {
        let root = try directory()
        let sources = try NativeSources(
            project: root, cache: root.appendingPathComponent("cache"), sources: [], dsl: nil,
            offline: false, refreshRepositories: false, hardened: false)
        let revision = String(repeating: "a", count: 40)
        let source: [String: Any] = ["git": "repository", "commit": "main"]
        sources.pinnedCheckouts = ["Kit": ["git": "repository", "commit": revision]]
        XCTAssertEqual(sources.pinnedSelector("Kit", source: source), revision)
        sources.updating = true
        sources.updateRoots = ["Other"]
        XCTAssertEqual(sources.pinnedSelector("Kit", source: source), revision)
        sources.updateRoots = ["Kit"]
        XCTAssertEqual(sources.pinnedSelector("Kit", source: source), "main")
        sources.updating = false
        XCTAssertEqual(sources.pinnedSelector("Kit", source: ["git": "different", "commit": "main"]), "main")
    }

    func testArchiveDefaultsFollowDeclaredFormatAndExplicitFlattenWins() throws {
        let root = try directory()
        let input = root.appendingPathComponent("input")
        let payload = input.appendingPathComponent("Package/Kit.h")
        try FileManager.default.createDirectory(
            at: payload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("int kit_value(void);\n".utf8).write(to: payload)
        let zip = root.appendingPathComponent("opaque-zip")
        try command("/usr/bin/ditto", ["-c", "-k", "--keepParent", payload.deletingLastPathComponent().path, zip.path])
        let tar = root.appendingPathComponent("opaque-tar")
        try command("/usr/bin/tar", ["-czf", tar.path, "-C", input.path, "Package"])
        let cases: [(URL, [String: Any], String)] = [
            (zip, ["http": "https://example.invalid/kit.zip?token=value"], "Package/Kit.h"),
            (zip, ["type": "zip"], "Package/Kit.h"),
            (zip, ["type": "zip", "flatten": true], "Kit.h"),
            (tar, ["http": "https://example.invalid/kit.tar.gz"], "Kit.h"),
            (tar, ["type": "tgz"], "Kit.h"),
            (tar, ["type": "tgz", "flatten": false], "Package/Kit.h"),
        ]
        for (index, item) in cases.enumerated() {
            let destination = root.appendingPathComponent("output-\(index)")
            try NativeArchive.extract(item.0, source: item.1, destination: destination, pod: "Kit")
            XCTAssertEqual(
                try Data(contentsOf: destination.appendingPathComponent(item.2)), try Data(contentsOf: payload))
        }
    }

    func testLegacyHTTPDownloadMigratesOfflineOnlyWhenItsChecksumMatches() throws {
        for owned in [false, true] {
            let root = try directory()
            let cache = root.appendingPathComponent("cache")
            let location = "https://example.invalid/Kit.zip"
            let file = root.appendingPathComponent("archive")
            let content = Data("original archive bytes".utf8)
            try content.write(to: file)
            var origin: [String: Any] = [
                "url": location, "request_identity": digest(Data(location.utf8)), "kind": "native-download",
            ]
            if owned { origin["pod"] = "Kit" }
            _ = try ContentStore(cacheRoot: cache).put(file: file, origin: origin)
            let sources = try NativeSources(
                project: root, cache: cache, sources: [], dsl: nil, offline: true, refreshRepositories: false,
                hardened: false)
            let migrated = try sources.download(location, pod: "Kit", checksums: ["sha256": digest(content)])
            XCTAssertEqual(try Data(contentsOf: migrated), content)
            XCTAssertThrowsError(try sources.download(location, pod: "Kit", checksums: ["sha256": "different"])) {
                error in
                XCTAssertEqual((error as? Diagnostic)?.code, "SP-OFFLINE-MISSING")
            }
        }
    }

    func testXcconfigIncludeStopsBeforeQuotesInItsComment() throws {
        let root = try directory()
        let base = root.appendingPathComponent("Base.xcconfig")
        try Data("SDKROOT = macosx\nVALUE = BASE\n".utf8).write(to: base)
        let config = root.appendingPathComponent("Debug.xcconfig")
        try Data(
            "#include \"Base.xcconfig\" // Keep \"defaults\"\n#include? \"Missing.xcconfig\" // \"optional\"\nVALUE = $(inherited) CHILD\n"
                .utf8
        ).write(to: config)
        var inputs = Set<String>()
        let settings = try NativeBuildSettings.xcconfig(config, inputs: &inputs)
        XCTAssertEqual(settings["VALUE"] as? String, "BASE CHILD")
        XCTAssertEqual(settings["SDKROOT"] as? String, "macosx")
        XCTAssertEqual(inputs, [base.path, config.path])
    }

    func testXcconfigContinuationAcceptsBothLFAndCRLF() throws {
        let root = try directory()
        for newline in ["\n", "\r\n"] {
            let path = root.appendingPathComponent(UUID().uuidString + ".xcconfig")
            let text = "GCC_PREPROCESSOR_DEFINITIONS = FIRST=1 \\" + newline + " SECOND" + newline
            try Data(text.utf8).write(to: path)
            var inputs = Set<String>()
            let settings = try NativeBuildSettings.xcconfig(path, inputs: &inputs)
            XCTAssertEqual(settings["GCC_PREPROCESSOR_DEFINITIONS"] as? String, "FIRST=1   SECOND")
            XCTAssertNil(settings["SECOND"])
        }
    }

    func testModuleIdentifierUsesFixedLatinApproximationsAndScalarBoundaries() {
        for (input, expected) in [
            ("École", "Ecole"), ("Straße", "Strasse"), ("Æther-Œuvre", "AEther_OEuvre"), ("Łódź", "Lodz"),
            ("ĐÞĲŊŉ×ẞ", "DThIJNG_nxSS"), ("東京", "_"), ("E\u{301}cole", "E_cole"),
        ] {
            XCTAssertEqual(NativeModuleIdentifier.normalize(input), expected, input)
        }
    }

    func testLintVisitsNestedAndNondefaultLibrariesWithPlatformSpecificTests() throws {
        let spec = try NativeSpec(data: [
            "name": "Kit", "version": "1.0", "default_subspecs": ["Core"],
            "platforms": ["osx": "13.0", "ios": "15.0"],
            "testspecs": [["name": "RootChecks", "platforms": ["ios": "15.0"]]],
            "subspecs": [
                ["name": "Core"],
                [
                    "name": "Optional", "platforms": ["osx": "14.0"],
                    "subspecs": [["name": "Nested"]], "testspecs": [["name": "Checks"]],
                ],
                ["name": "Mobile", "platforms": ["ios": "16.0"]],
            ],
        ])
        let selections = try NativeLintSelection.plan(spec, platforms: ["osx", "ios"], skipTests: false)
        XCTAssertEqual(
            selections.filter { $0.platform == "osx" }.map(\.name),
            ["Kit", "Kit/Core", "Kit/Optional", "Kit/Optional/Nested"])
        XCTAssertEqual(selections.filter { $0.platform == "ios" }.map(\.name), ["Kit", "Kit/Core", "Kit/Mobile"])
        XCTAssertEqual(selections.first { $0.name == "Kit/Optional" }?.deployment, "14.0")
        XCTAssertEqual(selections.first { $0.name == "Kit/Optional" }?.tests, ["Kit/Optional/Checks"])
        XCTAssertEqual(selections.first { $0.name == "Kit" && $0.platform == "osx" }?.tests, [])
        XCTAssertEqual(selections.first { $0.name == "Kit" && $0.platform == "ios" }?.tests, ["Kit/RootChecks"])
        XCTAssertTrue(
            try NativeLintSelection.plan(spec, platforms: ["osx"], skipTests: true).allSatisfy { $0.tests.isEmpty })
    }
}
