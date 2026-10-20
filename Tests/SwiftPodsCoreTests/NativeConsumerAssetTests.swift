import XCTest

@testable import SwiftPodsCore

final class NativeConsumerAssetTests: XCTestCase {
    private func engine() throws -> NativeXcode {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try NativeXcode(
            project: root, manifest: [:], resolution: NativeResolution(specs: [:], requests: []),
            integrateUserProjects: false)
    }
    private func copyBundles(_ engine: NativeXcode, roots: Set<String>, target: String, user: NativePBX) throws {
        let copies = try engine.consumerBundleCopies(roots: roots, platform: "osx")
        try engine.consumerCopyPhase(
            ["Debug": copies], kind: "resources", label: "Pods-" + target, target: target, user: user)
    }
    func testExclusionsKeepSharedResourcesAndOtherPlatformsSeparate() throws {
        let engine = try engine()
        let shared = engine.project.appendingPathComponent("Shared/direct.txt")
        let conditional = engine.project.appendingPathComponent("Debug Bits/direct.txt")
        engine.staticResources["Always:osx"] = [shared]
        engine.staticResources["Debug:osx"] = [shared, conditional]
        engine.staticResources["Debug:ios"] = [engine.project.appendingPathComponent("iOS/direct.txt")]
        let product = engine.graph.add(
            "bundle", ["isa": "PBXFileReference", "path": "Debug.bundle", "explicitFileType": "wrapper.cfbundle"])
        engine.products = [product]
        engine.productPlatforms[product] = "osx"
        engine.resourceBundleRoots[product] = "Debug"
        XCTAssertEqual(
            try engine.consumerAssetExclusions(eligible: ["Always", "Debug"], enabled: ["Always"], platform: "osx"),
            ["$(BUILT_PRODUCTS_DIR)/Debug.bundle", conditional.path].sorted())
        XCTAssertTrue(
            try engine.consumerAssetExclusions(
                eligible: ["Always", "Debug"], enabled: ["Always", "Debug"], platform: "osx"
            ).isEmpty)
        XCTAssertEqual(
            try engine.consumerAssetExclusions(eligible: ["Debug"], enabled: [], platform: "ios"),
            [engine.project.appendingPathComponent("iOS/direct.txt").path])
    }
    func testResourceCopyScriptCanBeRemovedWithoutTouchingUserPhases() throws {
        let engine = try engine()
        let user = try NativePBX(engine.project.appendingPathComponent("Demo.xcodeproj/project.pbxproj"))
        let custom = user.add("custom", ["isa": "PBXShellScriptBuildPhase", "name": "User"])
        let target = user.add("target", ["isa": "PBXNativeTarget", "buildPhases": [custom]])
        let product = engine.graph.add(
            "bundle",
            [
                "isa": "PBXFileReference", "path": "Kit.bundle", "explicitFileType": "wrapper.cfbundle",
                "sourceTree": "BUILT_PRODUCTS_DIR",
            ])
        engine.products = [product]
        engine.productPlatforms[product] = "osx"
        engine.resourceBundleRoots[product] = "Kit"
        try copyBundles(engine, roots: ["Kit"], target: target, user: user)
        let phase = NativePBX.identifier("swiftpods:resources:" + target)
        XCTAssertEqual(user.objects[phase]?["isa"] as? String, "PBXShellScriptBuildPhase")
        XCTAssertEqual((user.objects[phase]?["inputFileListPaths"] as? [String])?.count, 1)
        XCTAssertEqual(user.objects[phase]?["files"] as? [String], [])
        try copyBundles(engine, roots: [], target: target, user: user)
        XCTAssertNil(user.objects[phase])
        XCTAssertEqual(user.objects[target]?["buildPhases"] as? [String], [custom])
    }
    func testHardenedConfigurationsAcceptOnlyStringArrays() throws {
        let engine = try engine()
        let path = engine.project.appendingPathComponent("Podfile.json")
        var pod: [String: Any] = ["name": "Kit", "path": "Modules/Kit", "configurations": ["Debug", "Staging"]]
        func write() throws {
            try jsonData([
                "schema_version": 1, "platform": ["name": "osx", "deployment_target": "13.0"],
                "project": "Demo.xcodeproj", "targets": [["name": "Demo", "pods": [pod]]],
            ]).write(to: path)
        }
        try write()
        XCTAssertNoThrow(try ExecutionPolicy.hardenedManifest(path))
        for invalid in ["Debug" as Any, [1] as Any, ["Debug", true] as Any] {
            pod["configurations"] = invalid
            try write()
            XCTAssertThrowsError(try ExecutionPolicy.hardenedManifest(path))
        }
    }

    func testManagedCopiesPrecedePostBuildScriptsWithoutMovingPreBuildScripts() throws {
        let engine = try engine()
        let user = try NativePBX(engine.project.appendingPathComponent("Demo.xcodeproj/project.pbxproj"))
        let pre = user.add("pre", ["isa": "PBXShellScriptBuildPhase", "name": "PreBuild"])
        let sources = user.add("sources", ["isa": "PBXSourcesBuildPhase"])
        let resources = user.add("resources", ["isa": "PBXResourcesBuildPhase"])
        let post = user.add("post", ["isa": "PBXShellScriptBuildPhase", "name": "PostBuild"])
        let copy = user.add("copy", ["isa": "PBXCopyFilesBuildPhase"])
        let embed = user.add("embed", ["isa": "PBXCopyFilesBuildPhase"])
        var phases = [pre, sources, resources, post]
        engine.insertConsumerCopyPhase(copy, into: &phases, user: user)
        engine.insertConsumerCopyPhase(embed, into: &phases, user: user)
        XCTAssertEqual(phases, [pre, sources, resources, embed, copy, post])
    }

    func testBundleProductsKeepOwnershipWhenDeclaredNamesMatch() throws {
        let root = try engine().project
        try Data("payload".utf8).write(to: root.appendingPathComponent("payload.txt"))
        let targets: [[String: Any]] = [
            ["name": "First", "platform": ["name": "osx"], "dependencies": [["name": "KitA"]]],
            ["name": "Second", "platform": ["name": "osx"], "dependencies": [["name": "KitB"]]],
        ]
        let names = ["KitA", "KitB"]
        let specs = try Dictionary(
            uniqueKeysWithValues: names.map { name in
                (
                    name,
                    try NativeSpec(
                        data: ["name": name, "version": "1.0", "resource_bundles": ["Shared": "payload.txt"]],
                        directory: root)
                )
            })
        let requests = try names.map { try NativeDependency(["name": $0], platform: "osx", deployment: "13.0") }
        let generated = try NativeXcode(
            project: root, manifest: ["targets": targets],
            resolution: NativeResolution(specs: specs, requests: requests),
            integrateUserProjects: false)
        try generated.generate()
        let bundles = generated.products.filter {
            generated.graph.objects[$0]?["explicitFileType"] as? String == "wrapper.cfbundle"
        }
        XCTAssertEqual(bundles.count, 2)
        XCTAssertEqual(Set(bundles.compactMap { generated.resourceBundleRoots[$0] }), Set(names))
        XCTAssertEqual(Set(bundles.map { generated.productBuildPath($0) }).count, 2)
        for (index, name) in names.enumerated() {
            generated.selectConsumer(targets[index])
            let matching = bundles.filter { generated.matchesProduct($0, roots: [name], platform: "osx") }
            XCTAssertEqual(matching.count, 1)
            XCTAssertEqual(generated.resourceBundleRoots[try XCTUnwrap(matching.first)], name)
            XCTAssertEqual(
                try generated.consumerAssetExclusions(eligible: [name], enabled: [], platform: "osx"),
                matching.map { generated.productBuildPath($0) })
        }
        generated.activeVariants = [:]
        XCTAssertThrowsError(try generated.consumerBundleCopies(roots: Set(names), platform: "osx"))
        for name in names {
            XCTAssertNoThrow(try generated.consumerBundleCopies(roots: [name], platform: "osx"))
        }
    }

    func testSharedBundleUsesSeparateFileListsForEachConsumer() throws {
        let engine = try engine()
        let user = try NativePBX(engine.project.appendingPathComponent("Demo.xcodeproj/project.pbxproj"))
        let product = engine.graph.add(
            "bundle", ["isa": "PBXFileReference", "path": "Shared.bundle", "explicitFileType": "wrapper.cfbundle"])
        engine.products = [product]
        engine.productPlatforms[product] = "osx"
        engine.resourceBundleRoots[product] = "Kit"
        var lists: [String] = []
        for name in ["First", "Second"] {
            let target = user.add(name, ["isa": "PBXNativeTarget", "buildPhases": []])
            try copyBundles(engine, roots: ["Kit"], target: target, user: user)
            let phase = try XCTUnwrap((user.objects[target]?["buildPhases"] as? [String])?.first)
            lists += user.objects[phase]?["inputFileListPaths"] as? [String] ?? []
        }
        XCTAssertEqual(lists.count, 2)
        XCTAssertEqual(Set(lists).count, 2)
        XCTAssertFalse(user.objects.values.contains { $0["isa"] as? String == "PBXBuildFile" })
    }

    func testMappedFrameworkHeadersKeepPublicPrivateAndProjectVisibility() throws {
        let root = try engine().project
        for path in ["Headers/Public/Common.h", "Headers/Private/Common.h", "Headers/Flat.h", "Headers/Project.h"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("// header\n".utf8).write(to: url)
        }
        let spec = try NativeSpec(
            data: [
                "name": "Kit", "version": "1.0", "source_files": "Headers/**/*.h", "header_mappings_dir": "Headers",
                "public_header_files": "Headers/Public/*.h",
                "private_header_files": ["Headers/Private/*.h", "Headers/Flat.h"],
                "project_header_files": "Headers/Project.h",
            ], directory: root)
        let request = try NativeDependency(["name": "Kit"], platform: "osx", deployment: "13.0")
        let generated = try NativeXcode(
            project: root,
            manifest: [
                "targets": [
                    [
                        "name": "Demo", "platform": ["name": "osx"], "frameworks": "static",
                        "dependencies": [["name": "Kit"]],
                    ]
                ]
            ],
            resolution: NativeResolution(specs: ["Kit": spec], requests: [request]), integrateUserProjects: false)
        try generated.generate()
        let library = try XCTUnwrap(generated.libraryTargets["Kit:osx"])
        let phases = generated.graph.objects[library]?["buildPhases"] as? [String] ?? []
        let copies = phases.compactMap { generated.graph.objects[$0] }.filter {
            $0["isa"] as? String == "PBXCopyFilesBuildPhase"
        }
        XCTAssertEqual(
            Set(copies.compactMap { $0["dstPath"] as? String }),
            [
                "$(PUBLIC_HEADERS_FOLDER_PATH)/Public", "$(PRIVATE_HEADERS_FOLDER_PATH)/Private",
            ])
        let headers = phases.compactMap { generated.graph.objects[$0] }.filter {
            $0["isa"] as? String == "PBXHeadersBuildPhase"
        }
        .flatMap { $0["files"] as? [String] ?? [] }
        let retained = Dictionary(
            uniqueKeysWithValues: headers.compactMap { id -> (String, [String])? in
                guard let reference = generated.graph.objects[id]?["fileRef"] as? String,
                    let path = generated.graph.objects[reference]?["path"] as? String
                else { return nil }
                let attributes =
                    (generated.graph.objects[id]?["settings"] as? [String: Any])?["ATTRIBUTES"] as? [String] ?? []
                return (URL(fileURLWithPath: path).lastPathComponent, attributes)
            })
        XCTAssertEqual(retained["Flat.h"], ["Private"])
        XCTAssertEqual(retained["Project.h"], [])
        XCTAssertNil(retained["Common.h"])
    }
    func testDynamicLibraryOwnsItsBundlesWhileStaticLibraryCopiesToConsumer() throws {
        let engine = try engine()
        let root = engine.project
        try Data("payload".utf8).write(to: root.appendingPathComponent("payload.txt"))
        let spec = try NativeSpec(
            data: ["name": "Kit", "version": "1.0", "resource_bundles": ["KitAssets": "payload.txt"]], directory: root)
        let request = try NativeDependency(["name": "Kit"], platform: "osx", deployment: "13.0")
        for linkage in ["static", "dynamic"] {
            let manifest: [String: Any] = [
                "targets": [
                    [
                        "name": "Demo", "platform": ["name": "osx"], "frameworks": linkage,
                        "dependencies": [["name": "Kit"]],
                    ]
                ]
            ]
            let generated = try NativeXcode(
                project: root, manifest: manifest,
                resolution: NativeResolution(specs: ["Kit": spec], requests: [request]), integrateUserProjects: false)
            try generated.generate()
            let bundle = try XCTUnwrap(
                generated.products.first { generated.graph.objects[$0]?["path"] as? String == "KitAssets.bundle" })
            let library = try XCTUnwrap(generated.libraryTargets["Kit:osx"])
            let phases = generated.graph.objects[library]?["buildPhases"] as? [String] ?? []
            let resources = phases.filter { generated.graph.objects[$0]?["isa"] as? String == "PBXResourcesBuildPhase" }
                .flatMap { generated.graph.objects[$0]?["files"] as? [String] ?? [] }
            XCTAssertEqual(
                resources.contains {
                    generated.graph.objects[$0]?["fileRef"] as? String == generated.buildReference(bundle)
                },
                linkage == "dynamic")
            XCTAssertEqual(generated.frameworkResourceBundles.contains(bundle), linkage == "dynamic")
            let user = try NativePBX(root.appendingPathComponent("Demo.xcodeproj/project.pbxproj"))
            let target = user.add("consumer", ["isa": "PBXNativeTarget", "buildPhases": []])
            try copyBundles(generated, roots: ["Kit"], target: target, user: user)
            XCTAssertEqual((user.objects[target]?["buildPhases"] as? [String] ?? []).isEmpty, linkage == "dynamic")
        }
    }
}
