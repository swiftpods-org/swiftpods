import XCTest

@testable import SwiftPodsCore

final class NativeGeneratedNameCollisionTests: XCTestCase {
    private func fixture(name: String, consumer: String = "App", bundle: String? = nil) throws -> NativeXcode {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try Data("int value(void) { return 7; }\n".utf8).write(to: root.appendingPathComponent("Source.c"))
        try Data("resource\n".utf8).write(to: root.appendingPathComponent("Data.txt"))
        var attributes: [String: Any] = [
            "name": name, "version": "1.0", "source_files": "Source.c", "resources": "Data.txt",
            "pod_target_xcconfig": ["GCC_PREPROCESSOR_DEFINITIONS": ["$(inherited)", "LIBRARY_MARKER=1"]],
        ]
        if let bundle {
            try Data("bundled\n".utf8).write(to: root.appendingPathComponent("Bundle.txt"))
            attributes["resource_bundles"] = [bundle: "Bundle.txt"]
        }
        let spec = try NativeSpec(data: attributes, directory: root)
        return try NativeXcode(
            project: root,
            manifest: [
                "targets": [
                    [
                        "name": consumer, "platform": ["name": "osx", "deployment_target": "13.0"],
                        "dependencies": [["name": name]],
                    ]
                ]
            ], resolution: NativeResolution(specs: [name: spec], requests: []), integrateUserProjects: false)
    }

    func testLibraryNamesCannotShareProjectAggregateOrResourceConfigurations() throws {
        for name in ["Pods", "Pods-App", "Pods-App-Resources", "pods", "pods-app"] {
            let engine = try fixture(name: name)
            try engine.generate()
            let library = try XCTUnwrap(engine.libraryTargets[name + ":osx"])
            let root = try XCTUnwrap(engine.graph.root["rootObject"] as? String)
            let owners = [library, root] + engine.targetIDs.filter { $0 != library }
            let lists = try owners.map { try XCTUnwrap(engine.graph.objects[$0]?["buildConfigurationList"] as? String) }
            XCTAssertEqual(Set(lists).count, lists.count, name)
            let labels = engine.targetIDs.compactMap { engine.graph.objects[$0]?["name"] as? String }
            XCTAssertEqual(Set(labels).count, labels.count, name)
            let label = try XCTUnwrap(engine.graph.objects[library]?["name"] as? String)
            let hook = try XCTUnwrap(engine.hookTargets.first { $0["name"] as? String == label })
            XCTAssertNotNil(hook["build_configurations"])
        }
    }

    func testCaseVariantsKeepDistinctArchivesConfigurationsAndSupportPaths() throws {
        let original = try fixture(name: "Foo")
        let upper = try XCTUnwrap(original.resolution.specs["Foo"])
        let lower = try NativeSpec(
            data: upper.data.merging(["name": "foo", "module_name": "LowerAPI"]) { _, new in new },
            directory: original.project)
        var manifest = original.manifest
        var targets = try XCTUnwrap(manifest["targets"] as? [[String: Any]])
        targets[0]["dependencies"] = [["name": "Foo"], ["name": "foo"]]
        manifest["targets"] = targets
        let engine = try NativeXcode(
            project: original.project, manifest: manifest,
            resolution: NativeResolution(specs: ["Foo": upper, "foo": lower], requests: []),
            integrateUserProjects: false)
        try engine.generate()
        let labels = ["Foo:osx", "foo:osx"].compactMap { engine.variantPlan?.variants[$0]?.label }
        XCTAssertEqual(Set(labels.map { $0.lowercased() }).count, 2)
        let products = try ["Foo:osx", "foo:osx"].map {
            let target = try XCTUnwrap(engine.libraryTargets[$0])
            let product = try XCTUnwrap(engine.graph.objects[target]?["productReference"] as? String)
            return try XCTUnwrap(engine.graph.objects[product]?["path"] as? String)
        }
        XCTAssertEqual(Set(products.map { $0.lowercased() }).count, 2)
        let paths = try labels.map {
            let config = try XCTUnwrap(engine.configurations[$0]?["Debug"])
            let file = try XCTUnwrap(engine.graph.objects[config]?["baseConfigurationReference"] as? String)
            return try NativeBuildSettings.file(file, graph: engine.graph).path.lowercased()
        }
        XCTAssertEqual(Set(paths).count, 2)
    }

    func testGeneratedSuffixCannotOverwriteAnUnambiguousLiteralName() {
        let literal = "Kit-" + String(digest(Data("a".utf8)).prefix(16))
        let preferred = ["a": "Kit", "b": "kit", "c": literal]
        let labels = NativeTargetNames.assign(preferred, reserved: [])
        XCTAssertEqual(labels["c"], literal)
        XCTAssertNotEqual(labels["a"], literal)
        XCTAssertEqual(Set(labels.values.map { $0.lowercased() }).count, 3)
        XCTAssertEqual(labels, NativeTargetNames.assign(preferred, reserved: []))
    }

    func testConsumerSupportConfigurationCannotOverwritePodSettings() throws {
        let engine = try fixture(name: "Pods-App")
        try engine.generate()
        let label = try XCTUnwrap(engine.variantPlan?.variants["Pods-App:osx"]?.label)
        let config = try XCTUnwrap(engine.configurations[label]?["Debug"])
        let reference = try XCTUnwrap(engine.graph.objects[config]?["baseConfigurationReference"] as? String)
        let path = try NativeBuildSettings.file(reference, graph: engine.graph)
        let before = try Data(contentsOf: path)
        let consumer = try engine.supportConfiguration(
            label: "Pods-App", name: "Debug", settings: ["OTHER_LDFLAGS": "-ObjC"])
        XCTAssertNotEqual(path, consumer)
        XCTAssertEqual(try Data(contentsOf: path), before)
        XCTAssertTrue(String(decoding: before, as: UTF8.self).contains("LIBRARY_MARKER=1"))
    }

    func testResourceBundlesCannotShareConsumerResourceConfigurationsOrPhases() throws {
        let engine = try fixture(name: "Pods-A", consumer: "A-B", bundle: "B-Resources")
        try engine.generate()
        let bundle = try XCTUnwrap(engine.resourceBundleTargets["Pods-A:osx"]?.first)
        let consumer = try XCTUnwrap(engine.consumerResourceTargets["A-B"])
        let label = try XCTUnwrap(engine.graph.objects[bundle]?["name"] as? String)
        XCTAssertNotEqual(label, "Pods-A-B-Resources")
        XCTAssertNotEqual(
            engine.graph.objects[bundle]?["buildConfigurationList"] as? String,
            engine.graph.objects[consumer]?["buildConfigurationList"] as? String)
        let bundlePhases = try XCTUnwrap(engine.graph.objects[bundle]?["buildPhases"] as? [String])
        let consumerPhases = try XCTUnwrap(engine.graph.objects[consumer]?["buildPhases"] as? [String])
        XCTAssertTrue(Set(bundlePhases).isDisjoint(with: consumerPhases))
        for (target, expected) in [(bundle, "Bundle.txt"), (consumer, "Data.txt")] {
            let phases = engine.graph.objects[target]?["buildPhases"] as? [String] ?? []
            let builds = phases.flatMap { engine.graph.objects[$0]?["files"] as? [String] ?? [] }
            let paths = builds.compactMap { engine.graph.objects[$0]?["fileRef"] as? String }.compactMap {
                engine.graph.objects[$0]?["path"] as? String
            }
            XCTAssertEqual(paths.map { URL(fileURLWithPath: $0).lastPathComponent }, [expected])
        }
        let config = try XCTUnwrap(engine.configurations[label]?["Debug"])
        let settings = try XCTUnwrap(engine.graph.objects[config]?["buildSettings"] as? [String: Any])
        XCTAssertEqual(settings["PRODUCT_NAME"] as? String, "B-Resources")
        XCTAssertTrue((settings["CONFIGURATION_BUILD_DIR"] as? String)?.hasSuffix("/Pods-A") == true)
        let reference = try XCTUnwrap(engine.graph.objects[config]?["baseConfigurationReference"] as? String)
        let path = try NativeBuildSettings.file(reference, graph: engine.graph)
        let consumerConfig = try XCTUnwrap(engine.configurations["Pods-A-B-Resources"]?["Debug"])
        let consumerReference = try XCTUnwrap(
            engine.graph.objects[consumerConfig]?["baseConfigurationReference"] as? String)
        XCTAssertNotEqual(path, try NativeBuildSettings.file(consumerReference, graph: engine.graph))
    }

    func testDisambiguatedNamesAreStableAndKeepTheModuleIdentity() throws {
        let engine = try fixture(name: "Pods")
        try engine.generate()
        let label = try XCTUnwrap(engine.variantPlan?.variants["Pods:osx"]?.label)
        XCTAssertNotEqual(label, "Pods")
        let next = try NativeXcode(
            project: engine.project, manifest: engine.manifest, resolution: engine.resolution,
            integrateUserProjects: false)
        XCTAssertEqual(next.variantPlan?.variants["Pods:osx"]?.label, label)
        XCTAssertEqual(next.resolution.specs["Pods"]?.moduleName, "Pods")
    }
}
