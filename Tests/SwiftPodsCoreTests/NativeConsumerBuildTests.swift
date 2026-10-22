import XCTest

@testable import SwiftPodsCore

final class NativeConsumerBuildTests: XCTestCase {
    func testUnambiguousSupplementaryBundlesKeepCompatibleTargetNames() throws {
        let root = try directory()
        let spec = try NativeSpec(
            data: [
                "name": "Kit", "version": "1.0",
                "appspecs": [["name": "Example", "resource_bundles": ["AppResources": "*.txt"]]],
                "testspecs": [["name": "Tests", "resource_bundles": ["TestResources": "*.txt"]]],
            ], directory: root)
        let engine = try engine(
            root, specs: [spec],
            dependencies: [
                ["name": "Kit", "options": ["appspecs": ["Example"], "testspecs": ["Tests"]]]
            ])
        try engine.generate()
        let bundles = engine.graph.objects.values.filter {
            $0["productType"] as? String == "com.apple.product-type.bundle"
        }
        XCTAssertEqual(Set(bundles.compactMap { $0["name"] as? String }), ["Kit-AppResources", "Kit-TestResources"])
    }
    func testDisabledAutomaticMapPreservesAnAuthorsExplicitBuildSetting() throws {
        let root = try directory()
        try Data().write(to: root.appendingPathComponent("Kit.h"))
        let map = root.appendingPathComponent("Author.modulemap")
        try Data("module Kit { header \"Kit.h\" export * }\n".utf8).write(to: map)
        let spec = try NativeSpec(
            data: [
                "name": "Kit", "version": "1.0", "source_files": "*.h", "module_map": false,
                "pod_target_xcconfig": ["MODULEMAP_FILE": map.path],
            ], directory: root)
        let engine = try engine(
            root, specs: [spec], dependencies: [["name": "Kit", "options": ["modular_headers": true]]])
        try engine.generate()
        XCTAssertEqual(try settings(engine, target: "Kit")["MODULEMAP_FILE"] as? String, map.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: map.path))
    }
    func testExplicitModuleMapDisableWinsOverModularHeaders() throws {
        let root = try directory()
        try Data().write(to: root.appendingPathComponent("Kit.h"))
        let spec = try NativeSpec(
            data: ["name": "Kit", "version": "1.0", "source_files": "*.h", "module_map": false], directory: root)
        let engine = try engine(
            root, specs: [spec], dependencies: [["name": "Kit", "options": ["modular_headers": true]]])
        try engine.generate()
        let values = try settings(engine, target: "Kit")
        XCTAssertEqual(values["DEFINES_MODULE"] as? String, "YES")
        XCTAssertNil(values["MODULEMAP_FILE"])
        let publicRoot = root.appendingPathComponent("Pods/Headers/Public")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: publicRoot, includingPropertiesForKeys: nil))
        XCTAssertFalse(enumerator.allObjects.contains { ($0 as? URL)?.lastPathComponent == "module.modulemap" })
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func engine(_ root: URL, specs: [NativeSpec], dependencies: [[String: Any]]) throws -> NativeXcode {
        let catalog = Dictionary(uniqueKeysWithValues: specs.map { ($0.name, $0) })
        let requests = try dependencies.flatMap {
            try NativeDependency($0, platform: "osx", deployment: "14.0").expandedSelections()
        }
        let resolution = try NativeResolver(candidates: { catalog[$0.root].map { [$0] } ?? [] }).resolve(requests)
        return try NativeXcode(
            project: root,
            manifest: [
                "targets": [
                    [
                        "name": "Demo", "platform": ["name": "osx", "deployment_target": "14.0"],
                        "dependencies": dependencies,
                    ]
                ]
            ], resolution: resolution, integrateUserProjects: false)
    }

    private func settings(_ engine: NativeXcode, target name: String) throws -> [String: Any] {
        let target = try XCTUnwrap(
            engine.graph.objects.values.first {
                $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == name
            })
        let list = try XCTUnwrap(target["buildConfigurationList"] as? String)
        let configurations = try XCTUnwrap(engine.graph.objects[list]?["buildConfigurations"] as? [String])
        let debug = try XCTUnwrap(configurations.first { engine.graph.objects[$0]?["name"] as? String == "Debug" })
        return try NativeBuildSettings.resolved(XCTUnwrap(engine.graph.objects[debug]), graph: engine.graph)
    }

    func testStaticArchivesKeepPodIdentityWhenModuleNamesMatch() throws {
        let root = try directory()
        let specs = try ["Kit", "Peer"].map {
            try NativeSpec(data: ["name": $0, "version": "1.0", "module_name": "Shared"], directory: root)
        }
        let engine = try engine(root, specs: specs, dependencies: [["name": "Kit"], ["name": "Peer"]])
        try engine.generate()
        XCTAssertEqual(
            Set(engine.products.compactMap { engine.graph.objects[$0]?["path"] as? String }),
            [
                "libKit.a", "libPeer.a",
            ])
        XCTAssertEqual(Set(engine.products.map { engine.productBuildPath($0) }).count, 2)
        for name in ["Kit", "Peer"] {
            let settings = try settings(engine, target: name)
            XCTAssertEqual(settings["PRODUCT_NAME"] as? String, name)
            XCTAssertEqual(settings["PRODUCT_MODULE_NAME"] as? String, "Shared")
        }
    }

    func testMatchingPublicPatternsStillHideUnselectedAndPrivateHeaders() throws {
        let root = try directory()
        let files = ["Public.h", "Internal.h", "Private.h"].map { root.appendingPathComponent($0) }
        for file in files { try Data().write(to: file) }
        let rules = try NativeFileRules(
            ["public_header_files": "Public.h", "private_header_files": "Private.h"], root: root, files: files)
        XCTAssertEqual(rules.headers, Set(files))
        XCTAssertEqual(rules.publicHeaders, [files[0]])
        XCTAssertEqual(rules.privateHeaders, [files[2]])
    }

    func testSupplementaryConsumersReceiveCustomMapsAndKeepUserCompilerFlags() throws {
        let root = try directory()
        let map = root.appendingPathComponent("Custom.modulemap")
        try Data("module Feature { header \"Feature.h\" export * }\n".utf8).write(to: map)
        try Data().write(to: root.appendingPathComponent("Feature.h"))
        let options: [String: Any] = ["pod_target_xcconfig": ["OTHER_CFLAGS": "$(inherited) -DUSER=1"]]
        let spec = try NativeSpec(
            data: [
                "name": "Kit", "version": "1.0", "source_files": "*.h", "module_map": "Custom.modulemap",
                "appspecs": [options.merging(["name": "Example"]) { _, new in new }],
                "testspecs": [options.merging(["name": "Tests", "test_type": "unit"]) { _, new in new }],
            ], directory: root)
        let engine = try engine(
            root, specs: [spec],
            dependencies: [["name": "Kit", "options": ["appspecs": ["Example"], "testspecs": ["Tests"]]]])
        try engine.generate()
        let flag = "-fmodule-map-file=" + NativeBuildSetting.quoted(map.path)
        for name in ["Kit-Example", "Kit-Unit-Tests"] {
            let settings = try settings(engine, target: name)
            XCTAssertTrue(nativeStrings(settings["OTHER_CFLAGS"]).joined(separator: " ").contains(flag))
            XCTAssertTrue(nativeStrings(settings["OTHER_CFLAGS"]).joined(separator: " ").contains("-DUSER=1"))
            XCTAssertTrue(nativeStrings(settings["OTHER_CPLUSPLUSFLAGS"]).joined(separator: " ").contains(flag))
            XCTAssertEqual(nativeStrings(settings["OTHER_SWIFT_FLAGS"]), ["$(inherited)", "-Xcc", flag])
        }
    }

    func testIndependentAppsKeepSameNamedBundlesInSeparateOutputDirectories() throws {
        let root = try directory()
        let spec = try NativeSpec(
            data: [
                "name": "Kit", "version": "1.0",
                "appspecs": ["First", "Second"].map { ["name": $0, "resource_bundles": ["Shared": "*.txt"]] },
            ], directory: root)
        let engine = try engine(
            root, specs: [spec], dependencies: [["name": "Kit", "options": ["appspecs": ["First", "Second"]]]])
        try engine.generate()
        let bundles = engine.graph.objects.values.filter {
            $0["productType"] as? String == "com.apple.product-type.bundle"
        }
        XCTAssertEqual(bundles.count, 2)
        let products = try bundles.map { try XCTUnwrap($0["productReference"] as? String) }
        XCTAssertEqual(Set(products).count, 2)
        XCTAssertEqual(Set(products.map { engine.productBuildPath($0) }).count, 2)
        XCTAssertTrue(products.allSatisfy { engine.graph.objects[$0]?["path"] as? String == "Shared.bundle" })
    }

    func testSameAppRejectsBundleCollisionsFromOwnOrTransitiveLibraries() throws {
        for transitive in [false, true] {
            let root = try directory()
            var data: [String: Any] = [
                "name": "Kit", "version": "1.0", "resource_bundles": ["Shared": "*.txt"],
                "appspecs": [["name": "Example", "resource_bundles": transitive ? [:] : ["Shared": "*.txt"]]],
            ]
            var specs: [NativeSpec] = []
            if transitive {
                data["dependencies"] = ["Peer": []]
                specs.append(
                    try NativeSpec(
                        data: ["name": "Peer", "version": "1.0", "resource_bundles": ["Shared": "*.txt"]],
                        directory: root))
            }
            specs.append(try NativeSpec(data: data, directory: root))
            let engine = try engine(
                root, specs: specs, dependencies: [["name": "Kit", "options": ["appspecs": ["Example"]]]])
            XCTAssertThrowsError(try engine.generate()) { error in
                XCTAssertEqual((error as? Diagnostic)?.code, "SP-XCODE-RESOURCE")
            }
        }
    }

    func testLibraryRejectsCaseVariantBundleProductsInTheSameOutputDirectory() throws {
        let root = try directory()
        let spec = try NativeSpec(
            data: ["name": "Kit", "version": "1.0", "resource_bundles": ["Shared": "*.txt", "shared": "*.txt"]],
            directory: root)
        let engine = try engine(root, specs: [spec], dependencies: [["name": "Kit"]])
        XCTAssertThrowsError(try engine.generate()) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCODE-RESOURCE")
        }
    }

    func testConsumerRejectsCaseVariantBundlesFromDifferentLibraries() throws {
        let root = try directory()
        let specs = try [("Kit", "Shared"), ("Peer", "shared")].map { name, bundle in
            try NativeSpec(
                data: ["name": name, "version": "1.0", "resource_bundles": [bundle: "*.txt"]], directory: root)
        }
        let engine = try engine(root, specs: specs, dependencies: [["name": "Kit"], ["name": "Peer"]])
        try engine.generate()
        XCTAssertThrowsError(try engine.consumerBundleCopies(roots: ["Kit", "Peer"], platform: "osx")) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCODE-RESOURCE")
        }
    }

    func testSupplementaryConsumerRejectsCaseVariantOwnAndTransitiveBundles() throws {
        for transitive in [false, true] {
            let root = try directory()
            var data: [String: Any] = [
                "name": "Kit", "version": "1.0", "resource_bundles": ["Shared": "*.txt"],
                "appspecs": [["name": "Example", "resource_bundles": transitive ? [:] : ["shared": "*.txt"]]],
            ]
            var specs: [NativeSpec] = []
            if transitive {
                data["dependencies"] = ["Peer": []]
                specs.append(
                    try NativeSpec(
                        data: ["name": "Peer", "version": "1.0", "resource_bundles": ["shared": "*.txt"]],
                        directory: root))
            }
            specs.append(try NativeSpec(data: data, directory: root))
            let engine = try engine(
                root, specs: specs, dependencies: [["name": "Kit", "options": ["appspecs": ["Example"]]]])
            XCTAssertThrowsError(try engine.generate()) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCODE-RESOURCE")
            }
        }
    }
}
