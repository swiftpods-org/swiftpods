import XCTest

@testable import SwiftPodsCore

final class NativeLifecycleRegressionTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func project() throws -> NativePBX {
        let graph = try NativePBX(directory().appendingPathComponent("App.xcodeproj/project.pbxproj"))
        graph.objects = [
            "ROOT": ["isa": "PBXProject", "mainGroup": "GROUP", "targets": ["APP", "TESTS"], "packageReferences": []],
            "GROUP": ["isa": "PBXGroup", "children": []],
            "APP": ["isa": "PBXNativeTarget", "name": "App", "buildPhases": ["LINK"], "dependencies": []],
            "TESTS": ["isa": "PBXNativeTarget", "name": "Tests", "buildPhases": ["TEST_LINK"], "dependencies": []],
            "LINK": ["isa": "PBXFrameworksBuildPhase", "files": []],
            "TEST_LINK": ["isa": "PBXFrameworksBuildPhase", "files": []],
        ]
        graph.root = ["rootObject": "ROOT", "archiveVersion": "1", "objectVersion": "56"]
        return graph
    }

    private func package(_ version: String = "1.0.0") -> [String: Any] {
        ["git": "https://example.invalid/Net.git", "exact": version, "products": ["Net"]]
    }

    func testManagedPackageCanBeUpdatedAndRemovedWhileUserPackageSurvives() throws {
        let user = try project()
        let external: [String: Any] = [
            "isa": "XCRemoteSwiftPackageReference", "repositoryURL": "https://example.invalid/User.git",
            "requirement": ["kind": "branch", "branch": "main"],
        ]
        user.objects["USER_PACKAGE"] = external
        user.objects["ROOT"]?["packageReferences"] = ["USER_PACKAGE"]
        var record: [String: Any]?
        for version in ["1.0.0", "2.0.0"] {
            let packages = NativeSwiftPackageIntegrator()
            try packages.prepare(user, record: record)
            try packages.integrate([package(version)], targetID: "APP", user: user, installedModules: [])
            record = packages.finish(user)
            let own = user.objects.values.first { $0["repositoryURL"] as? String == package()["git"] as? String }
            XCTAssertEqual((own?["requirement"] as? [String: String])?["version"], version)
            XCTAssertEqual((user.objects["LINK"]?["files"] as? [String])?.count, 1)
            XCTAssertEqual(try jsonData(user.objects["USER_PACKAGE"]!), try jsonData(external))
        }
        let removal = NativeSwiftPackageIntegrator()
        try removal.prepare(user, record: record)
        _ = removal.finish(user)
        XCTAssertEqual(user.objects["ROOT"]?["packageReferences"] as? [String], ["USER_PACKAGE"])
        XCTAssertEqual(user.objects["APP"]?["packageProductDependencies"] as? [String], [])
        XCTAssertEqual(user.objects["LINK"]?["files"] as? [String], [])
        XCTAssertFalse(user.objects.values.contains { $0["isa"] as? String == "XCSwiftPackageProductDependency" })
    }

    func testPackageRemovalIsScopedToItsRecordedTargetAttachments() throws {
        let user = try project()
        let first = NativeSwiftPackageIntegrator()
        try first.prepare(user, record: nil)
        try first.integrate([package()], targetID: "APP", user: user, installedModules: [])
        let record = first.finish(user)
        let products = user.objects["APP"]?["packageProductDependencies"] as? [String] ?? []
        // A user attaches the same product to a different target after install.
        user.objects["TESTS"]?["packageProductDependencies"] = products
        let removal = NativeSwiftPackageIntegrator()
        try removal.prepare(user, record: record)
        _ = removal.finish(user)
        XCTAssertEqual(user.objects["TESTS"]?["packageProductDependencies"] as? [String], products)
        XCTAssertNotNil(user.objects[products[0]])
        XCTAssertEqual(user.objects["APP"]?["packageProductDependencies"] as? [String], [])
    }

    func testPackageConflictsProtectUserRequirementsAndExternalEdits() throws {
        let user = try project()
        let first = NativeSwiftPackageIntegrator()
        try first.prepare(user, record: nil)
        try first.integrate([package()], targetID: "APP", user: user, installedModules: [])
        let record = first.finish(user)
        let reference = NativePBX.identifier("swiftpods:package:" + (package()["git"] as! String))
        user.objects[reference]?["requirement"] = ["kind": "branch", "branch": "user-edit"]
        let second = NativeSwiftPackageIntegrator()
        XCTAssertThrowsError(try second.prepare(user, record: record))
        let manual = try project()
        manual.objects["MANUAL"] = user.objects[reference]
        manual.objects["ROOT"]?["packageReferences"] = ["MANUAL"]
        let conflict = NativeSwiftPackageIntegrator()
        try conflict.prepare(manual, record: nil)
        XCTAssertThrowsError(try conflict.integrate([package()], targetID: "APP", user: manual, installedModules: []))
        XCTAssertEqual((manual.objects["MANUAL"]?["requirement"] as? [String: String])?["branch"], "user-edit")
    }

    func testLegacyPackageOwnershipMigratesAndConflictingTargetsAreRejected() throws {
        let user = try project()
        let first = NativeSwiftPackageIntegrator()
        try first.prepare(user, record: nil)
        try first.integrate([package()], targetID: "APP", user: user, installedModules: [])
        _ = first.finish(user)
        let next = NativeSwiftPackageIntegrator()
        try next.prepare(user, record: nil)
        try next.integrate([package("2.0.0")], targetID: "APP", user: user, installedModules: [])
        XCTAssertThrowsError(
            try next.integrate([package("3.0.0")], targetID: "TESTS", user: user, installedModules: []))
        let record = next.finish(user)
        XCTAssertFalse((record["objects"] as? [String: Any] ?? [:]).isEmpty)
    }

    func testBuildSettingExpansionUsesFinalOverridesAndRejectsCycles() throws {
        let project: [String: Any] = [
            "MY_MIN": "12.0", "MIN_ALIAS": "${MY_MIN}", "MACOSX_DEPLOYMENT_TARGET": "$(MIN_ALIAS)",
        ]
        let merged = NativeBuildSettings.merge(project, ["MY_MIN": "13.0"])
        XCTAssertEqual(try NativeBuildSettings.expandedValue("MACOSX_DEPLOYMENT_TARGET", settings: merged), "13.0")
        XCTAssertEqual(
            try NativeBuildSettings.expandedValue("PATH", settings: ["PATH": "$(UNKNOWN)/local"]), "$(UNKNOWN)/local")
        XCTAssertThrowsError(try NativeBuildSettings.expandedValue("A", settings: ["A": "$(B)", "B": "${A}"]))
    }

    func testConditionalSDKUsesFinalValueAcrossIncludesAndMacros() throws {
        let root = try directory()
        let config = root.appendingPathComponent("Base.xcconfig")
        let child = root.appendingPathComponent("Child.xcconfig")
        try Data("MINIMUM = 13.0\nMINIMUM[sdk=macosx*] = 14.0\nFLAGS = $(inherited) child\n".utf8).write(to: child)
        try Data("FLAGS = base\n#include \"Child.xcconfig\"\nSDKROOT = $(SDK_NAME)\nSDK_NAME = macosx\n".utf8)
            .write(to: config)
        var inputs = Set<String>()
        let values = try NativeBuildSettings.xcconfig(config, inputs: &inputs)
        XCTAssertEqual(values["MINIMUM"] as? String, "14.0")
        XCTAssertEqual(values["FLAGS"] as? String, "base child")
        XCTAssertEqual(inputs, [config.path, child.path])
        let override = try NativeBuildSettings.xcconfig(config, context: ["sdk": "iphoneos"], inputs: &inputs)
        XCTAssertEqual(override["MINIMUM"] as? String, "13.0")
    }

    func testSDKReevaluationPreservesAssignmentOrderAndRejectsCycles() throws {
        let config = try directory().appendingPathComponent("Base.xcconfig")
        var inputs = Set<String>()
        try Data("MINIMUM[sdk=macosx*] = 14.0\nMINIMUM = 13.0\nSDKROOT = macosx\n".utf8).write(to: config)
        XCTAssertEqual(try NativeBuildSettings.xcconfig(config, inputs: &inputs)["MINIMUM"] as? String, "13.0")
        try Data("SDKROOT = macosx\nSDKROOT[sdk=macosx*] = iphoneos\nSDKROOT[sdk=iphoneos*] = macosx\n".utf8)
            .write(to: config)
        XCTAssertThrowsError(try NativeBuildSettings.xcconfig(config, inputs: &inputs)) { error in
            XCTAssertEqual((error as? Diagnostic)?.code, "SP-XCCONFIG-CYCLE")
        }
    }

    func testTargetConditionsUseSDKFromBaseConfiguration() throws {
        let user = try project()
        let path = user.url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
            "Base.xcconfig")
        try Data("SDKROOT = macosx\n".utf8).write(to: path)
        user.objects["CONFIG_FILE"] = ["isa": "PBXFileReference", "path": path.path, "sourceTree": "<absolute>"]
        let resolved = try NativeBuildSettings.resolved(
            [
                "name": "Debug", "baseConfigurationReference": "CONFIG_FILE",
                "buildSettings": ["MINIMUM": "13.0", "MINIMUM[sdk=macosx*]": "14.0"],
            ], graph: user)
        XCTAssertEqual(resolved["MINIMUM"] as? String, "14.0")
    }

    func testNamedCleanupRecoversLegacyAliasOwnersWithoutDeletingSharedSources() throws {
        let cache = try directory()
        var paths: [URL] = []
        for (key, names) in [("a", ["Kit"]), ("b", ["Another"]), ("c", [String]())] {
            let path = cache.appendingPathComponent("git/" + String(repeating: key, count: 64))
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try Data("source".utf8).write(to: path.appendingPathComponent("File.c"))
            try NativeGitCache.write(
                path,
                metadata: [
                    "commit": String(repeating: "d", count: 40), "origin_identity": String(repeating: "e", count: 64),
                    "pod_names": names,
                ])
            paths.append(path)
        }
        let entries = try NativeMaintenance.run(["cache", "list", "Kit"], cache: cache)["entries"] as? [[String: Any]]
        XCTAssertEqual(entries?.count, 3)
        _ = try NativeMaintenance.run(["cache", "clean", "Kit"], cache: cache)
        for path in paths { XCTAssertEqual(try NativeGitCache.verify(path)["pod_names"] as? [String], ["Another"]) }
        _ = try NativeMaintenance.run(["cache", "clean", "Another"], cache: cache)
        for path in paths { XCTAssertFalse(FileManager.default.fileExists(atPath: path.path)) }
    }

    func testConsumerFlagsCombinePodsAndPreserveExplicitUserOverrides() throws {
        var settings = NativeBuildSettings.addingConsumerSettings(
            ["OTHER_CFLAGS": "$(inherited) -DFIRST=1"], to: [:], original: [:])
        settings = NativeBuildSettings.addingConsumerSettings(
            ["OTHER_CFLAGS": "${inherited} -DSECOND=1"], to: settings, original: [:])
        XCTAssertEqual(settings["OTHER_CFLAGS"] as? String, "$(inherited) -DFIRST=1 -DSECOND=1")
        let original = ["OTHER_CFLAGS": "-DUSER=1"]
        XCTAssertEqual(
            NativeBuildSettings.addingConsumerSettings(settings, to: original, original: original)["OTHER_CFLAGS"]
                as? String, "-DUSER=1")
    }

    func testGitReceiptBindsRevisionButAllowsSharedPodOwnership() throws {
        let cache = try directory()
        let checkout = cache.appendingPathComponent("git/" + String(repeating: "a", count: 64))
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: checkout.appendingPathComponent("File.c"))
        var metadata: [String: Any] = [
            "commit": String(repeating: "b", count: 40), "origin_identity": String(repeating: "c", count: 64),
        ]
        try NativeGitCache.write(checkout, metadata: metadata)
        XCTAssertEqual(try NativeCacheIntegrity.verify(cache)["status"] as? String, "passed")
        metadata["pod_names"] = ["Kit", "Another"]
        try jsonData(metadata).write(to: checkout.appendingPathExtension("origin.json"))
        XCTAssertNoThrow(try NativeGitCache.verify(checkout))
        metadata["commit"] = String(repeating: "f", count: 40)
        try jsonData(metadata).write(to: checkout.appendingPathExtension("origin.json"))
        XCTAssertThrowsError(try NativeGitCache.verify(checkout))
        XCTAssertThrowsError(try NativeCacheIntegrity.verify(cache))
    }

    func testLegacyGitCacheCanBeRemovedWithoutTrustingItsProvenance() throws {
        let cache = try directory()
        let checkout = cache.appendingPathComponent("git/" + String(repeating: "a", count: 64))
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let source = checkout.appendingPathComponent("File.c")
        try Data("source".utf8).write(to: source)
        let fingerprint = try FileFingerprint.tree(checkout, requireContainedLinks: true)
        try Data(fingerprint.utf8).write(to: checkout.appendingPathExtension("sha256"))
        try jsonData(["commit": "unverified", "pod_names": ["Kit", "KitUI"]])
            .write(to: checkout.appendingPathExtension("origin.json"))
        XCTAssertThrowsError(try NativeGitCache.verify(checkout))
        let entries = try NativeMaintenance.run(["cache", "list", "Kit"], cache: cache)["entries"] as? [[String: Any]]
        XCTAssertEqual(entries?.count, 1)
        XCTAssertEqual(entries?.first?["revision"] as? String, "unknown")
        XCTAssertEqual(try NativeMaintenance.run(["cache", "clean", "Kit"], cache: cache)["removed"] as? Int, 0)
        XCTAssertEqual(try NativeGitCache.maintenanceMetadata(checkout)["pod_names"] as? [String], ["KitUI"])
        try Data("changed".utf8).write(to: source)
        XCTAssertThrowsError(try NativeMaintenance.run(["cache", "clean", "--all"], cache: cache))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        try Data("source".utf8).write(to: source)
        XCTAssertEqual(try NativeMaintenance.run(["cache", "clean", "--all"], cache: cache)["removed"] as? Int, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkout.path))
    }

    func testNamedCacheCleanupUsesExactPodOwnershipNotURLOrPrefix() throws {
        let cache = try directory()
        let source = cache.appendingPathComponent("source.zip")
        try Data("shared content".utf8).write(to: source)
        do {
            let store = try ContentStore(cacheRoot: cache)
            for pod in ["Kit", "KitUI", "Foo"] {
                _ = try store.put(file: source, origin: ["pod": pod, "url": "https://example.invalid/Kit.tar"])
            }
        }
        XCTAssertEqual(try NativeMaintenance.run(["cache", "clean", "Kit"], cache: cache)["removed"] as? Int, 1)
        let remaining = try NativeMaintenance.run(["cache", "list"], cache: cache)["entries"] as? [[String: Any]] ?? []
        XCTAssertEqual(Set(remaining.compactMap { ($0["origin"] as? [String: String])?["pod"] }), ["KitUI", "Foo"])
        XCTAssertEqual(try NativeMaintenance.run(["cache", "clean", "Kit"], cache: cache)["removed"] as? Int, 0)
    }

    func testRemovedConsumerCleanupLeavesOtherTargetsAndUserEditsIntact() throws {
        let user = try project()
        let product = "PRODUCT"
        let ref = user.add("swiftpods:product:" + product, ["isa": "PBXFileReference", "path": "libKit.a"])
        let build = user.add("swiftpods:build:" + product, ["isa": "PBXBuildFile", "fileRef": ref])
        user.objects["LINK"]?["files"] = [build]
        user.objects["TEST_LINK"]?["files"] = [build]
        user.objects["APP"]?["buildConfigurationList"] = "CONFIGS"
        user.objects["CONFIGS"] = ["isa": "XCConfigurationList", "buildConfigurations": ["DEBUG"]]
        user.objects["DEBUG"] = [
            "isa": "XCBuildConfiguration", "buildSettings": ["PODS_ROOT": "Pods", "CUSTOM": "edited"],
        ]
        let record = try NativeIntegrationSettings.record(
            before: ["CUSTOM": "original"], after: ["PODS_ROOT": "Pods", "CUSTOM": "written"])
        try NativeDeintegrator.restore(
            user, settings: [user.url.path + ":DEBUG": record], products: [product], targets: ["APP"])
        XCTAssertEqual(user.objects["LINK"]?["files"] as? [String], [])
        XCTAssertEqual(user.objects["TEST_LINK"]?["files"] as? [String], [build])
        XCTAssertNotNil(user.objects[ref])
        XCTAssertEqual(user.objects["DEBUG"]?["buildSettings"] as? [String: String], ["CUSTOM": "edited"])
    }
}
