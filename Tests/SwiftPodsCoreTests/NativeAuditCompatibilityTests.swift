import XCTest

@testable import SwiftPodsCore

final class NativeAuditCompatibilityTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testPrereleaseComponentsKeepZerosAndOrderNumbersBeforeText() throws {
        let alpha = try PodVersion("1.0.0-alpha")
        let zero = try PodVersion("1.0.0-alpha.0")
        XCTAssertNotEqual(alpha, zero)
        XCTAssertLessThan(alpha, zero)
        XCTAssertEqual(Set([alpha, zero]).count, 2)
        XCTAssertFalse(try PodRequirement(["= 1.0.0-alpha.0"]).accepts(alpha))
        XCTAssertLessThan(try PodVersion("1.0.0-alpha.2"), try PodVersion("1.0.0-alpha.beta"))
        XCTAssertEqual(alpha, try PodVersion("1.0.alpha+build.7"))
        XCTAssertGreaterThan(try PodVersion("1.0.0-1"), alpha)
        XCTAssertEqual(try PodVersion("1.0.0-1").release, try PodVersion("1.0.0.1"))
        XCTAssertLessThan(try PodVersion("1.0.0-alpha.0"), try PodVersion("1.0.0"))
        XCTAssertLessThan(try PodVersion("1.0.0-alpha"), try PodVersion("1.0.0-alpha.0.beta"))
    }

    func testResolverRejectsMissingExactPrereleaseAndSelectsTheLatestCandidate() throws {
        let alpha = try NativeSpec(data: ["name": "Kit", "version": "1.0.0-alpha"])
        let exact = try NativeDependency(["name": "Kit", "requirements": ["= 1.0.0-alpha.0"]])
        XCTAssertThrowsError(try NativeResolver(candidates: { _ in [alpha] }).resolve([exact]))
        let versions = try ["1.0.0-alpha.2", "1.0.0-alpha.beta"].map {
            try NativeSpec(data: ["name": "Kit", "version": $0])
        }
        let request = try NativeDependency(["name": "Kit", "requirements": [">= 1.0.0-alpha.0"]])
        XCTAssertEqual(
            try NativeResolver(candidates: { _ in versions }).resolve([request]).specs["Kit"]?.version.description,
            "1.0.0-alpha.beta")
    }

    func testLocalPreparationRepeatsOnlyWhenExplicitlyInvalidated() throws {
        let project = try directory()
        let checkout = project.appendingPathComponent("Kit")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let count = checkout.appendingPathComponent("count")
        let spec = try NativeSpec(
            data: ["name": "Kit", "version": "1.0", "prepare_command": "printf p >> count"],
            directory: checkout, local: true)
        let sources = try NativeSources(
            project: project, cache: project.appendingPathComponent("cache"), sources: [], dsl: nil,
            offline: false, refreshRepositories: false, hardened: false)
        _ = try sources.install(spec)
        let userFile = checkout.appendingPathComponent("User.c")
        try Data("user edit".utf8).write(to: userFile)
        _ = try sources.install(spec)
        sources.updating = true
        sources.updateRoots = ["Other"]
        _ = try sources.install(spec)
        XCTAssertEqual(try String(contentsOf: count, encoding: .utf8), "p")
        sources.updateRoots = ["Kit"]
        _ = try sources.install(spec)
        sources.updating = false
        sources.cleanInstall = true
        _ = try sources.install(spec)
        sources.cleanInstall = false
        let changed = try NativeSpec(
            data: ["name": "Kit", "version": "1.1", "prepare_command": "printf q >> count"],
            directory: checkout, local: true)
        _ = try sources.install(changed)
        _ = try sources.install(changed)
        XCTAssertEqual(try String(contentsOf: count, encoding: .utf8), "pppq")
        XCTAssertEqual(try String(contentsOf: userFile, encoding: .utf8), "user edit")
        let hardened = try NativeSources(
            project: project, cache: project.appendingPathComponent("cache"), sources: [], dsl: nil,
            offline: true, refreshRepositories: false, hardened: true)
        XCTAssertThrowsError(try hardened.install(changed))
        XCTAssertEqual(try String(contentsOf: count, encoding: .utf8), "pppq")
    }

    func testFailedLocalPreparationNeverRecordsSuccess() throws {
        let project = try directory()
        let checkout = project.appendingPathComponent("Kit")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let sources = try NativeSources(
            project: project, cache: project.appendingPathComponent("cache"), sources: [], dsl: nil,
            offline: false, refreshRepositories: false, hardened: false)
        let spec = try NativeSpec(
            data: ["name": "Kit", "version": "1.0", "prepare_command": "printf x >> count; exit 9"],
            directory: checkout, local: true)
        for _ in 0..<2 { XCTAssertThrowsError(try sources.install(spec)) }
        XCTAssertEqual(try String(contentsOf: checkout.appendingPathComponent("count"), encoding: .utf8), "xx")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: project.appendingPathComponent("Pods/Target Support Files/Kit/local-prepare-state.json").path))
    }

    func testGitCommandsIsolateRepositoryStorageAndKeepTransportConfiguration() throws {
        let root = try directory()
        let selected = root.appendingPathComponent("selected")
        let foreign = root.appendingPathComponent("foreign")
        for path in [selected, foreign] {
            try command("/usr/bin/git", ["init", "--", path.path])
            try Data("initial".utf8).write(to: path.appendingPathComponent("README"))
            try command("/usr/bin/git", ["add", "."], directory: path)
            try command(
                "/usr/bin/git",
                ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial"],
                directory: path)
        }
        let before = try FileFingerprint.tree(foreign)
        try Data("new".utf8).write(to: selected.appendingPathComponent("New.txt"))
        var environment = ProcessInfo.processInfo.environment
        for (key, relative) in [
            "GIT_DIR": ".git", "GIT_COMMON_DIR": ".git", "GIT_WORK_TREE": ".",
            "GIT_INDEX_FILE": ".git/index", "GIT_OBJECT_DIRECTORY": ".git/objects",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES": ".git/objects",
        ] { environment[key] = foreign.appendingPathComponent(relative).path }
        environment["GIT_CONFIG_COUNT"] = "1"
        environment["GIT_CONFIG_KEY_0"] = "http.extraHeader"
        environment["GIT_CONFIG_VALUE_0"] = "X-Audit: preserved"
        let auth = try ToolProcess.run(
            "/usr/bin/git", ["config", "--get", "http.extraHeader"], directory: selected, environment: environment)
        XCTAssertEqual(auth.status, 0)
        XCTAssertEqual(
            String(decoding: auth.output, as: UTF8.self).trimmingCharacters(in: .newlines), "X-Audit: preserved")
        for args in [
            ["add", "--", "New.txt"],
            ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "new"],
        ] {
            let result = try ToolProcess.run("/usr/bin/git", args, directory: selected, environment: environment)
            XCTAssertEqual(result.status, 0, String(decoding: result.error, as: UTF8.self))
        }
        XCTAssertEqual(try FileFingerprint.tree(foreign), before)
        let committed = try ToolProcess.run("/usr/bin/git", ["show", "HEAD:New.txt"], directory: selected)
        XCTAssertEqual(committed.status, 0)
        XCTAssertEqual(String(decoding: committed.output, as: UTF8.self), "new")
    }

    func testBuildMetadataPreservesSpellingWithoutAffectingRequirementsOrPrerelease() throws {
        let version = try PodVersion("1.2.3+build.7")
        XCTAssertEqual(version.description, "1.2.3+build.7")
        XCTAssertFalse(version.isPrerelease)
        XCTAssertEqual(version, try PodVersion("1.2.3+another"))
        XCTAssertEqual(Set(try ["1.2.3", "1.2.3+another", "1.2.3+build.7"].map(PodVersion.init)).count, 1)
        XCTAssertTrue(try PodRequirement(["= 1.2.3"]).accepts(version))
        XCTAssertTrue(try PodRequirement([">= 1.2.3+build.8", "<= 1.2.3"]).accepts(version))
        XCTAssertFalse(try PodRequirement(["> 1.2.3"]).accepts(version))
        XCTAssertTrue(try PodRequirement(["~> 1.2.3+build.7"]).accepts(PodVersion("1.2.9")))
        XCTAssertFalse(try PodRequirement(["~> 1.2.3+build.7"]).accepts(PodVersion("1.3.0")))
        let prerelease = try PodVersion("1.2.3-alpha-beta+git.7")
        XCTAssertTrue(prerelease.isPrerelease)
        XCTAssertLessThan(prerelease, version)
        for invalid in ["1.2.3+", "1.2.3+../payload", "1.2.3+bad/value", "1.2.3-alpha..beta"] {
            XCTAssertThrowsError(try PodVersion(invalid), invalid)
        }
        let started = Date()
        XCTAssertThrowsError(try PodVersion("1" + String(repeating: "-a", count: 20) + "/"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "Malformed versions caused excessive backtracking")
    }

    func testLockfileReadsAndPreservesMetadataVersion() throws {
        let lock = try directory().appendingPathComponent("Podfile.lock")
        try Data("PODS:\n  - Kit (1.2.3+build.7)\nDEPENDENCIES:\n  - Kit (= 1.2.3+build.7)\n".utf8).write(to: lock)
        let parsed = try NativeLock(lock)
        XCTAssertEqual(parsed.versions["Kit"], "1.2.3+build.7")
        XCTAssertEqual(parsed.declarations["Kit"], ["= 1.2.3+build.7"])
    }

    func testResolverOrdersMetadataVariantsAndRetainsExactLockedSpelling() throws {
        let specs = try ["1.2.3+build.7", "1.2.3+build.8"].map {
            try NativeSpec(data: ["name": "Kit", "version": $0])
        }
        let request = try NativeDependency(["name": "Kit", "requirements": ["= 1.2.3"]])
        let resolver = NativeResolver(candidates: { _ in specs })
        XCTAssertEqual(try resolver.resolve([request]).specs["Kit"]?.version.description, "1.2.3+build.8")
        let pinned = NativeResolver(candidates: resolver.candidates, locked: ["Kit": "1.2.3+build.7"])
        XCTAssertEqual(try pinned.resolve([request]).specs["Kit"]?.version.description, "1.2.3+build.7")
    }

    func testTargetSDKOverridesInheritedSDKButDirectSettingsKeepTheirPriority() throws {
        let root = try directory()
        let path = root.appendingPathComponent("Base.xcconfig")
        try Data("SDKROOT = macosx\nMINIMUM = 13.0\nMINIMUM[sdk=macosx*] = 14.0\n".utf8).write(to: path)
        let graph = try NativePBX(root.appendingPathComponent("App.xcodeproj/project.pbxproj"))
        graph.objects["CONFIG"] = ["isa": "PBXFileReference", "path": path.path, "sourceTree": "<absolute>"]
        var config: [String: Any] = ["name": "Debug", "baseConfigurationReference": "CONFIG", "buildSettings": [:]]
        let inherited = ["SDKROOT": "iphoneos"]
        var settings = try NativeBuildSettings.resolved(config, graph: graph, base: inherited)
        XCTAssertEqual(settings["SDKROOT"] as? String, "macosx")
        XCTAssertEqual(settings["MINIMUM"] as? String, "14.0")
        config["buildSettings"] = ["SDKROOT": "iphoneos"]
        settings = try NativeBuildSettings.resolved(config, graph: graph, base: inherited)
        XCTAssertEqual(settings["MINIMUM"] as? String, "13.0")
        config["buildSettings"] = ["SDKROOT": "$(CUSTOM_SDK)"]
        try Data("CUSTOM_SDK = macosx\nSDKROOT = iphoneos\nMINIMUM = 13.0\nMINIMUM[sdk=macosx*] = 14.0\n".utf8)
            .write(to: path)
        settings = try NativeBuildSettings.resolved(config, graph: graph, base: inherited)
        XCTAssertEqual(settings["MINIMUM"] as? String, "14.0")
    }

    func testProjectDirectoryResolvesGroupsAndSourceRootMacros() throws {
        let root = try directory()
        let graph = try NativePBX(root.appendingPathComponent("App.xcodeproj/project.pbxproj"))
        graph.root["rootObject"] = "ROOT"
        graph.objects = [
            "ROOT": ["isa": "PBXProject", "mainGroup": "MAIN", "projectDirPath": "ActualRoot"],
            "MAIN": ["isa": "PBXGroup", "sourceTree": "<group>", "children": ["CONFIGS"]],
            "CONFIGS": ["isa": "PBXGroup", "sourceTree": "<group>", "path": "Configs", "children": ["FILE"]],
            "FILE": ["isa": "PBXFileReference", "sourceTree": "<group>", "path": "Base.xcconfig"],
            "MACRO": ["isa": "PBXFileReference", "sourceTree": "SOURCE_ROOT", "path": "$(PROJECT_DIR)/Flags.xcconfig"],
        ]
        XCTAssertEqual(graph.sourceRoot.path, root.appendingPathComponent("ActualRoot").path)
        XCTAssertEqual(
            try NativeBuildSettings.file("FILE", graph: graph).path,
            root.appendingPathComponent("ActualRoot/Configs/Base.xcconfig").path)
        XCTAssertEqual(
            try NativeBuildSettings.file("MACRO", graph: graph).path,
            root.appendingPathComponent("ActualRoot/Flags.xcconfig").path)
        graph.objects["ROOT"]?["projectDirPath"] = root.appendingPathComponent("AbsoluteRoot").path
        XCTAssertEqual(graph.sourceRoot.path, root.appendingPathComponent("AbsoluteRoot").path)
    }

    func testRejectedPublicationPromotionRestoresOriginalCheckout() throws {
        let cache = try directory()
        let repositories = NativeRepositories(cache: cache)
        let checkout = repositories.root.appendingPathComponent("private")
        try FileManager.default.createDirectory(
            at: checkout.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("original".utf8).write(to: checkout.appendingPathComponent("README"))
        // A directory in place of the record forces an actual metadata write failure.
        try FileManager.default.createDirectory(
            at: repositories.root.appendingPathComponent("private.json"),
            withIntermediateDirectories: true)
        let before = try FileFingerprint.tree(checkout)
        let transaction = try NativeRepositoryPublication(directory: checkout)
        try Data("new specification".utf8).write(to: transaction.staging.appendingPathComponent("New.podspec.json"))
        XCTAssertThrowsError(try transaction.publish(["name": "private"], repositories: repositories))
        XCTAssertEqual(try FileFingerprint.tree(checkout), before)
    }

    func testPublicationRejectsAnExternalEditBeforePromotion() throws {
        let cache = try directory()
        let checkout = cache.appendingPathComponent("repositories/private")
        try FileManager.default.createDirectory(
            at: checkout.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let transaction = try NativeRepositoryPublication(directory: checkout)
        let file = checkout.appendingPathComponent("User.txt")
        try Data("user edit".utf8).write(to: file)
        XCTAssertThrowsError(
            try transaction.publish(["name": "private"], repositories: NativeRepositories(cache: cache)))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "user edit")
    }
}
