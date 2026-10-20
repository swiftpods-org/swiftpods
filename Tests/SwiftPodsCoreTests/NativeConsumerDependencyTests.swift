import XCTest

@testable import SwiftPodsCore

final class NativeConsumerDependencyTests: XCTestCase {
    private func fixture(multiple: Bool = false) throws -> NativeXcode {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try Data("int kit(void) { return 1; }\n".utf8).write(to: root.appendingPathComponent("kit.c"))
        try Data("payload".utf8).write(to: root.appendingPathComponent("payload.txt"))
        let user = try NativePBX(root.appendingPathComponent("Demo.xcodeproj/project.pbxproj"))
        user.root = ["archiveVersion": "1", "objectVersion": "60", "rootObject": "PROJECT"]
        user.objects = [
            "PROJECT": ["isa": "PBXProject", "mainGroup": "GROUP", "targets": ["Library", "Static", "Dynamic"]],
            "GROUP": ["isa": "PBXGroup", "children": [], "sourceTree": "<group>"],
        ]
        var targets: [[String: Any]] = []
        for name in ["Library", "Static", "Dynamic"] {
            user.objects[name] = [
                "isa": "PBXNativeTarget", "name": name, "buildPhases": [], "buildConfigurationList": name + "List",
            ]
            user.objects[name + "List"] = ["isa": "XCConfigurationList", "buildConfigurations": [name + "Config"]]
            user.objects[name + "Config"] = ["isa": "XCBuildConfiguration", "name": "Debug", "buildSettings": [:]]
            var target: [String: Any] = [
                "name": name, "platform": ["name": "osx", "deployment_target": "13.0"],
                "dependencies": [["name": "Kit"]],
            ]
            if name != "Library" { target["frameworks"] = name.lowercased() }
            targets.append(target)
        }
        try user.save()
        let kit = try NativeSpec(
            data: [
                "name": "Kit", "version": "1.0", "source_files": "kit.c", "dependencies": ["Peer": [">= 0"]],
                "resource_bundles": ["KitResources": "payload.txt"],
            ], directory: root)
        let peer = try NativeSpec(
            data: ["name": "Peer", "version": "1.0", "resource_bundles": ["PeerResources": "payload.txt"]],
            directory: root)
        let engine = try NativeXcode(
            project: root,
            manifest: ["options": ["generate_multiple_pod_projects": multiple], "targets": targets],
            resolution: NativeResolution(specs: ["Kit": kit, "Peer": peer], requests: []))
        try engine.generate()
        _ = try engine.savePods()
        return engine
    }

    @discardableResult private func legacyDependencies(_ engine: NativeXcode, target: String) throws -> Set<String> {
        let user = try XCTUnwrap(engine.userProjects.values.first)
        let consumer = try XCTUnwrap(
            (engine.manifest["targets"] as? [[String: Any]])?.first { $0["name"] as? String == target })
        engine.selectConsumer(consumer)
        var dependencies = user.objects[target]?["dependencies"] as? [String] ?? []
        var added = Set<String>()
        for product in engine.products where engine.matchesProduct(product, roots: ["Kit", "Peer"], platform: "osx") {
            let producer = try XCTUnwrap(
                engine.graph.objects.first { $0.value["productReference"] as? String == product })
            let owner = try XCTUnwrap(engine.targetOwners[producer.key])
            let path =
                engine.multipleProjects ? engine.projectForPod(owner) : engine.graph.url.deletingLastPathComponent()
            let portal = user.add(
                "swiftpods:variant-project:" + owner, user.relativeFileReference(path, type: "wrapper.pb-project"))
            let key = "swiftpods:variant-dependency:" + target + ":" + product
            let proxy = user.add(
                key + ":proxy",
                [
                    "isa": "PBXContainerItemProxy", "containerPortal": portal, "proxyType": "1",
                    "remoteGlobalIDString": producer.key,
                ])
            let dependency = user.add(key, ["isa": "PBXTargetDependency", "targetProxy": proxy])
            dependencies.append(dependency)
            added.formUnion([portal, proxy, dependency])
        }
        user.objects[target]?["dependencies"] = dependencies
        let children = user.objects["GROUP"]?["children"] as? [String] ?? []
        let portals = added.filter { user.objects[$0]?["isa"] as? String == "PBXFileReference" }
        user.objects["GROUP"]?["children"] = Set(children).union(portals).sorted()
        return added
    }

    func testEachConsumerUsesOnlyTheAggregateInSingleAndMultipleProjects() throws {
        for multiple in [false, true] {
            let engine = try fixture(multiple: multiple)
            _ = try engine.integrate()
            let user = try XCTUnwrap(engine.userProjects.values.first)
            let portals = user.objects.filter { $0.value["lastKnownFileType"] as? String == "wrapper.pb-project" }
            XCTAssertEqual(portals.count, 1)
            let portal = try XCTUnwrap(portals.keys.first)
            XCTAssertEqual(
                try NativeBuildSettings.file(portal, graph: user), engine.graph.url.deletingLastPathComponent())
            for consumer in engine.manifest["targets"] as? [[String: Any]] ?? [] {
                let name = try XCTUnwrap(consumer["name"] as? String)
                let dependencies = try XCTUnwrap(user.objects[name]?["dependencies"] as? [String])
                XCTAssertEqual(dependencies.count, 1, "\(name), multiple projects: \(multiple)")
                let dependency = try XCTUnwrap(dependencies.first)
                let proxy = try XCTUnwrap(user.objects[dependency]?["targetProxy"] as? String)
                let aggregate = try XCTUnwrap(engine.aggregateTargets[nativeConsumerKey(consumer)])
                XCTAssertEqual(user.objects[proxy]?["remoteGlobalIDString"] as? String, aggregate)
                XCTAssertEqual(user.objects[proxy]?["containerPortal"] as? String, portal)

                engine.selectConsumer(consumer)
                XCTAssertFalse(
                    engine.consumerProductLinkerFlags(["Kit", "Peer"], platform: "osx").contains("-framework"))
                let reachable = NativeProjectProjection.reachable(engine.graph.objects, from: [aggregate])
                for product in engine.products {
                    let producer = try XCTUnwrap(
                        engine.graph.objects.first { $0.value["productReference"] as? String == product })
                    XCTAssertEqual(
                        reachable.contains(producer.key),
                        engine.matchesProduct(product, roots: ["Kit", "Peer"], platform: "osx"),
                        "\(name): \(producer.value["name"] ?? product)")
                }
                if multiple {
                    for dependency in engine.podsProject.objects[aggregate]?["dependencies"] as? [String] ?? [] {
                        if let local = engine.podsProject.objects[dependency]?["target"] as? String {
                            XCTAssertNotNil(engine.podsProject.objects[local])
                            continue
                        }
                        let remoteProxy = try XCTUnwrap(
                            engine.podsProject.objects[dependency]?["targetProxy"] as? String)
                        let remote = try XCTUnwrap(
                            engine.podsProject.objects[remoteProxy]?["remoteGlobalIDString"] as? String)
                        let owner = try XCTUnwrap(engine.targetOwners[remote])
                        XCTAssertNotNil(engine.generatedProjects[engine.projectForPod(owner).path]?.objects[remote])
                    }
                }
            }
        }
    }

    func testReinstallRemovesLegacyDependenciesProxiesAndPortalsAndIsStable() throws {
        for multiple in [false, true] {
            let engine = try fixture(multiple: multiple)
            var legacy = Set<String>()
            for name in ["Library", "Static", "Dynamic"] {
                legacy.formUnion(try legacyDependencies(engine, target: name))
            }
            let user = try XCTUnwrap(engine.userProjects.values.first)
            var links: [String] = []
            var bundleBuilds: [String] = []
            for product in engine.products {
                let reference = user.add("swiftpods:product:" + product, engine.consumerProduct(product))
                let build = user.add("swiftpods:build:" + product, ["isa": "PBXBuildFile", "fileRef": reference])
                let bundleBuild = user.add(
                    "swiftpods:bundle-build:Library:" + product, ["isa": "PBXBuildFile", "fileRef": reference])
                links.append(build)
                bundleBuilds.append(bundleBuild)
                legacy.formUnion([reference, build, bundleBuild])
            }
            let vendorKey = "swiftpods:vendor:Pods/PreviousSDK.xcframework"
            let vendor = user.add(
                vendorKey,
                ["isa": "PBXFileReference", "path": "Pods/PreviousSDK.xcframework", "sourceTree": "SOURCE_ROOT"])
            let vendorBuild = user.add(vendorKey + ":link", ["isa": "PBXBuildFile", "fileRef": vendor])
            legacy.formUnion([vendor, vendorBuild])
            let userReference = user.add(
                "user-sdk", ["isa": "PBXFileReference", "path": "User.framework", "sourceTree": "SOURCE_ROOT"])
            let userBuild = user.add("user-build", ["isa": "PBXBuildFile", "fileRef": userReference])
            let frameworkPhase = user.add(
                "old-frameworks", ["isa": "PBXFrameworksBuildPhase", "files": links + [vendorBuild, userBuild]])
            let bundlePhase = user.add(
                "swiftpods:resources:Library", ["isa": "PBXCopyFilesBuildPhase", "files": bundleBuilds])
            user.objects["Library"]?["buildPhases"] = [frameworkPhase, bundlePhase]
            try NativeResources.apply(
                [engine.project.appendingPathComponent("payload.txt")], target: "Library", graph: user)
            let stale = "previously-removed-product"
            engine.previousProducts.insert(stale)
            let staleKey = "swiftpods:variant-dependency:Library:" + stale
            let staleProxy = user.add(
                staleKey + ":proxy", ["isa": "PBXContainerItemProxy", "containerPortal": "OLD-PORTAL"])
            let staleDependency = user.add(staleKey, ["isa": "PBXTargetDependency", "targetProxy": staleProxy])
            user.objects["OLD-PORTAL"] = [
                "isa": "PBXFileReference", "path": "Pods/Old.xcodeproj", "sourceTree": "SOURCE_ROOT",
            ]
            let dependencies = user.objects["Library"]?["dependencies"] as? [String] ?? []
            user.objects["Library"]?["dependencies"] = dependencies + [staleDependency]
            legacy.formUnion([staleDependency, staleProxy, "OLD-PORTAL"])
            _ = try engine.integrate()
            for id in legacy { XCTAssertNil(user.objects[id], id) }
            XCTAssertNotNil(user.objects[userBuild])
            XCTAssertNotNil(user.objects[userReference])
            XCTAssertTrue(Set(user.objects["GROUP"]?["children"] as? [String] ?? []).isDisjoint(with: legacy))
            let bytes = try Data(contentsOf: user.url)
            let reinstalled = try NativeXcode(
                project: engine.project, manifest: engine.manifest, resolution: engine.resolution)
            try reinstalled.generate()
            _ = try reinstalled.savePods()
            _ = try reinstalled.integrate()
            XCTAssertEqual(try Data(contentsOf: user.url), bytes)
        }
    }

    func testRemovingOneConsumerPreservesTheSharedPortalForOtherConsumers() throws {
        let engine = try fixture()
        _ = try engine.integrate()
        let user = try XCTUnwrap(engine.userProjects.values.first)
        let portal = NativePBX.identifier("swiftpods:pods-project")
        try NativeDeintegrator.restore(
            user, settings: engine.integrationSettings, products: Set(engine.products), targets: ["Library"])
        XCTAssertNotNil(user.objects[portal])
        XCTAssertEqual(user.objects["Library"]?["dependencies"] as? [String], [])
        for name in ["Static", "Dynamic"] {
            XCTAssertEqual((user.objects[name]?["dependencies"] as? [String])?.count, 1)
        }
        try NativeDeintegrator.restore(user, settings: engine.integrationSettings, products: Set(engine.products))
        XCTAssertNil(user.objects[portal])
        XCTAssertFalse((user.objects["GROUP"]?["children"] as? [String] ?? []).contains(portal))
    }

    func testLegacyCleanupPreservesObjectsStillUsedByAnotherTargetOrProjectReference() throws {
        let engine = try fixture()
        let legacy = try legacyDependencies(engine, target: "Library")
        let user = try XCTUnwrap(engine.userProjects.values.first)
        let dependencies = try XCTUnwrap(user.objects["Library"]?["dependencies"] as? [String])
        user.objects["UserTarget"] = ["isa": "PBXNativeTarget", "dependencies": dependencies]
        engine.removePreviousVariantDependencies(user, target: "Library")
        for id in legacy { XCTAssertNotNil(user.objects[id], id) }
        let portal = try XCTUnwrap(legacy.first { user.objects[$0]?["isa"] as? String == "PBXFileReference" })
        user.objects["PROJECT"]?["projectReferences"] = [["ProjectRef": portal, "ProductGroup": "GROUP"]]
        user.objects["UserTarget"]?["dependencies"] = []
        engine.removePreviousVariantDependencies(user, target: "Library")
        for id in legacy where id != portal { XCTAssertNil(user.objects[id], id) }
        XCTAssertNotNil(user.objects[portal])
        XCTAssertTrue((user.objects["GROUP"]?["children"] as? [String] ?? []).contains(portal))
    }
}
