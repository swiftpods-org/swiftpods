import XCTest
@testable import SwiftPodsCore

final class NativeConsumerAssetTests: XCTestCase {
    private func engine() throws -> NativeXcode {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try NativeXcode(project: root, manifest: [:], resolution: NativeResolution(specs: [:], requests: []), integrateUserProjects: false)
    }
    func testExclusionsKeepSharedResourcesAndOtherPlatformsSeparate() throws {
        let engine = try engine()
        let shared = engine.project.appendingPathComponent("Shared/direct.txt")
        let conditional = engine.project.appendingPathComponent("Debug Bits/direct.txt")
        engine.staticResources["Always:osx"] = [shared]
        engine.staticResources["Debug:osx"] = [shared, conditional]
        engine.staticResources["Debug:ios"] = [engine.project.appendingPathComponent("iOS/direct.txt")]
        let product = engine.graph.add("bundle", ["isa": "PBXFileReference", "path": "Debug.bundle", "explicitFileType": "wrapper.cfbundle"])
        engine.products = [product]; engine.productPlatforms[product] = "osx"; engine.resourceRoots["Debug.bundle"] = "Debug"
        XCTAssertEqual(try engine.consumerAssetExclusions(eligible: ["Always", "Debug"], enabled: ["Always"], platform: "osx"), ["$(BUILT_PRODUCTS_DIR)/Debug.bundle", conditional.path].sorted())
        XCTAssertTrue(try engine.consumerAssetExclusions(eligible: ["Always", "Debug"], enabled: ["Always", "Debug"], platform: "osx").isEmpty)
        XCTAssertEqual(try engine.consumerAssetExclusions(eligible: ["Debug"], enabled: [], platform: "ios"), [engine.project.appendingPathComponent("iOS/direct.txt").path])
    }
    func testNativeBundleCopyPhaseCanBeRemovedWithoutTouchingUserPhases() throws {
        let engine = try engine(), user = try NativePBX(engine.project.appendingPathComponent("Demo.xcodeproj/project.pbxproj"))
        let custom = user.add("custom", ["isa": "PBXShellScriptBuildPhase", "name": "User"])
        let target = user.add("target", ["isa": "PBXNativeTarget", "buildPhases": [custom]])
        let product = engine.graph.add("bundle", ["isa": "PBXFileReference", "path": "Kit.bundle", "explicitFileType": "wrapper.cfbundle", "sourceTree": "BUILT_PRODUCTS_DIR"])
        engine.products = [product]; engine.productPlatforms[product] = "osx"; engine.resourceRoots["Kit.bundle"] = "Kit"
        engine.copyResourceBundles(roots: ["Kit"], platform: "osx", target: target, user: user)
        let phase = NativePBX.identifier("swiftpods:resources:" + target)
        XCTAssertEqual(user.objects[phase]?["isa"] as? String, "PBXCopyFilesBuildPhase")
        XCTAssertEqual(user.objects[phase]?["dstSubfolderSpec"] as? String, "7")
        XCTAssertEqual((user.objects[phase]?["files"] as? [String])?.count, 1)
        engine.copyResourceBundles(roots: [], platform: "osx", target: target, user: user)
        XCTAssertNil(user.objects[phase])
        XCTAssertEqual(user.objects[target]?["buildPhases"] as? [String], [custom])
    }
    func testHardenedConfigurationsAcceptOnlyStringArrays() throws {
        let engine = try engine(), path = engine.project.appendingPathComponent("Podfile.json")
        var pod: [String: Any] = ["name": "Kit", "path": "Modules/Kit", "configurations": ["Debug", "Staging"]]
        func write() throws {
            try jsonData(["schema_version": 1, "platform": ["name": "osx", "deployment_target": "13.0"], "project": "Demo.xcodeproj", "targets": [["name": "Demo", "pods": [pod]]]]).write(to: path)
        }
        try write(); XCTAssertNoThrow(try ExecutionPolicy.hardenedManifest(path))
        for invalid in ["Debug" as Any, [1] as Any, ["Debug", true] as Any] {
            pod["configurations"] = invalid; try write()
            XCTAssertThrowsError(try ExecutionPolicy.hardenedManifest(path))
        }
    }
    func testDynamicLibraryOwnsItsBundlesWhileStaticLibraryCopiesToConsumer() throws {
        let engine = try engine(), root = engine.project
        try Data("payload".utf8).write(to: root.appendingPathComponent("payload.txt"))
        let spec = try NativeSpec(data: ["name": "Kit", "version": "1.0", "resource_bundles": ["KitAssets": "payload.txt"]], directory: root)
        let request = try NativeDependency(["name": "Kit"], platform: "osx", deployment: "13.0")
        for linkage in ["static", "dynamic"] {
            let manifest: [String: Any] = ["targets": [["name": "Demo", "platform": ["name": "osx"], "frameworks": linkage, "dependencies": [["name": "Kit"]]]]]
            let generated = try NativeXcode(project: root, manifest: manifest, resolution: NativeResolution(specs: ["Kit": spec], requests: [request]), integrateUserProjects: false)
            try generated.generate()
            let bundle = try XCTUnwrap(generated.products.first { generated.graph.objects[$0]?["path"] as? String == "KitAssets.bundle" })
            let library = try XCTUnwrap(generated.libraryTargets["Kit:osx"])
            let phases = generated.graph.objects[library]?["buildPhases"] as? [String] ?? []
            let resources = phases.filter { generated.graph.objects[$0]?["isa"] as? String == "PBXResourcesBuildPhase" }.flatMap { generated.graph.objects[$0]?["files"] as? [String] ?? [] }
            XCTAssertEqual(resources.contains { generated.graph.objects[$0]?["fileRef"] as? String == bundle }, linkage == "dynamic")
            XCTAssertEqual(generated.frameworkResourceBundles.contains(bundle), linkage == "dynamic")
            let user = try NativePBX(root.appendingPathComponent("Demo.xcodeproj/project.pbxproj"))
            let target = user.add("consumer", ["isa": "PBXNativeTarget", "buildPhases": []])
            generated.copyResourceBundles(roots: ["Kit"], platform: "osx", target: target, user: user)
            XCTAssertEqual((user.objects[target]?["buildPhases"] as? [String] ?? []).isEmpty, linkage == "dynamic")
        }
    }
}
