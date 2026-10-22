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
