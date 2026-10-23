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
        func filesystemKey(_ value: String) -> String {
            value.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        }
        for (first, second) in [("Foo", "foo"), ("Σ", "ς"), ("Straße", "STRASSE"), ("ﬀ", "ff")] {
            let original = try fixture(name: first)
            let upper = try XCTUnwrap(original.resolution.specs[first])
            let lower = try NativeSpec(
                data: upper.data.merging(["name": second, "module_name": "LowerAPI"]) { _, new in new },
                directory: original.project)
            var manifest = original.manifest
            var targets = try XCTUnwrap(manifest["targets"] as? [[String: Any]])
            targets[0]["dependencies"] = [["name": first], ["name": second]]
            manifest["targets"] = targets
            let engine = try NativeXcode(
                project: original.project, manifest: manifest,
                resolution: NativeResolution(specs: [first: upper, second: lower], requests: []),
                integrateUserProjects: false)
            try engine.generate()
            let keys = [first + ":osx", second + ":osx"]
            let labels = keys.compactMap { engine.variantPlan?.variants[$0]?.label }
            XCTAssertEqual(Set(labels.map(filesystemKey)).count, 2, first + "/" + second)
            let products = try keys.map {
                let target = try XCTUnwrap(engine.libraryTargets[$0])
                let product = try XCTUnwrap(engine.graph.objects[target]?["productReference"] as? String)
                return try XCTUnwrap(engine.graph.objects[product]?["path"] as? String)
            }
            XCTAssertEqual(Set(products.map(filesystemKey)).count, 2, first + "/" + second)
            let paths = try labels.map {
                let config = try XCTUnwrap(engine.configurations[$0]?["Debug"])
                let file = try XCTUnwrap(engine.graph.objects[config]?["baseConfigurationReference"] as? String)
                return filesystemKey(try NativeBuildSettings.file(file, graph: engine.graph).path)
            }
            XCTAssertEqual(Set(paths).count, 2, first + "/" + second)
            let outputs = products.map { engine.project.appendingPathComponent($0) }
            try Data("first archive".utf8).write(to: outputs[0])
            try Data("second archive".utf8).write(to: outputs[1])
            XCTAssertEqual(try Data(contentsOf: outputs[0]), Data("first archive".utf8))
        }
    }

    func testUnicodeAliasesOfReservedTargetLabelsAreDisambiguated() {
        let labels = NativeTargetNames.assign(["pod": "Straße"], reserved: ["STRASSE"])
        XCTAssertNotEqual(
            labels["pod"]?.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")), "strasse")
    }

    func testConsumerAggregatesAndResourceTargetsKeepDistinctNamesAndConfigurations() throws {
        for (first, second) in [("App", "app"), ("A", "A-Resources"), ("Straße", "STRASSE")] {
            let original = try fixture(name: "Kit", consumer: first)
            var manifest = original.manifest
            var targets = try XCTUnwrap(manifest["targets"] as? [[String: Any]])
            var peer = targets[0]
            peer["name"] = second
            targets.append(peer)
            manifest["targets"] = targets
            let engine = try NativeXcode(
                project: original.project, manifest: manifest, resolution: original.resolution,
                integrateUserProjects: false)
            try engine.generate()
            let names = try engine.targetIDs.map { try XCTUnwrap(engine.graph.objects[$0]?["name"] as? String) }
            let keys = names.map { $0.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")) }
            XCTAssertEqual(Set(keys).count, keys.count, first + "/" + second)
            let lists = try engine.targetIDs.map {
                try XCTUnwrap(engine.graph.objects[$0]?["buildConfigurationList"] as? String)
            }
            XCTAssertEqual(Set(lists).count, lists.count)
        }
    }

    func testConsumerLabelsAreStableAcrossOrderingAndIndependentProjects() throws {
        let root = FileManager.default.temporaryDirectory
        let targets: [[String: Any]] = [
            ["name": "App", "project": "First.xcodeproj"], ["name": "App", "project": "Second.xcodeproj"],
        ]
        let first = try NativeConsumerLabels.normalized(["targets": targets], project: root)
        let repeated = try NativeConsumerLabels.normalized(first, project: root)
        XCTAssertEqual(try jsonData(first), try jsonData(repeated))
        let reordered = try NativeConsumerLabels.normalized(["targets": Array(targets.reversed())], project: root)
        let entries = try XCTUnwrap(first["targets"] as? [[String: Any]])
        let reversed = try XCTUnwrap(reordered["targets"] as? [[String: Any]])
        XCTAssertEqual(try jsonData(entries), try jsonData(Array(reversed.reversed())))
        XCTAssertEqual(Set(entries.compactMap { $0["label"] as? String }).count, 2)
        XCTAssertThrowsError(try NativeConsumerLabels.normalized(["targets": [targets[0], targets[0]]], project: root)) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCODE-TARGET")
        }
    }

    func testConsumerLabelsRejectPathComponentsBeforeGeneration() throws {
        let root = FileManager.default.temporaryDirectory
        for name in ["x/../../../../escaped", "/Absolute", "Nested/App", "Bad\0Name"] {
            XCTAssertThrowsError(
                try NativeConsumerLabels.normalized(["targets": [["name": name]]], project: root)
            ) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCODE-TARGET")
            }
        }
        for label in ["", ".", "..", "Nested/Label", "Bad\0Label"] {
            XCTAssertThrowsError(
                try NativeConsumerLabels.normalized(
                    ["targets": [["name": "App", "label": label]]], project: root)
            ) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCODE-TARGET")
            }
        }
    }

    func testUnsafeConsumerCannotWriteAResourcePlistOutsideTheProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("Project")
        let escaped = root.appendingPathComponent("escaped-Resources/Info.plist")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: escaped.deletingLastPathComponent(), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let original = Data("user-owned plist".utf8)
        try original.write(to: escaped)
        try Data("resource".utf8).write(to: project.appendingPathComponent("Data.txt"))
        let spec = try NativeSpec(
            data: ["name": "Kit", "version": "1.0", "resources": "Data.txt"], directory: project)
        XCTAssertThrowsError(
            try {
                let engine = try NativeXcode(
                    project: project,
                    manifest: [
                        "targets": [[
                            "name": "x/../../../../escaped",
                            "platform": ["name": "osx", "deployment_target": "13.0"],
                            "dependencies": [["name": "Kit"]],
                        ]]
                    ],
                    resolution: NativeResolution(specs: ["Kit": spec], requests: []), integrateUserProjects: false)
                try engine.generate()
            }()
        ) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCODE-TARGET")
        }
        XCTAssertEqual(try Data(contentsOf: escaped), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("Pods").path))
    }

    func testConfigurationPathsRejectSeparatorsAndNullsBeforeWriting() throws {
        let engine = try fixture(name: "Kit")
        for (label, name) in [("Pods-App", "Nested/Debug"), ("../Label", "Debug"),
            ("Pods-App", "Bad\0Configuration")]
        {
            XCTAssertThrowsError(try engine.supportConfiguration(label: label, name: name, settings: [:])) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCODE-CONFIG")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: engine.project.appendingPathComponent("Pods").path))
        var manifest = engine.manifest
        manifest["configurations"] = ["Nested/Debug": "debug"]
        XCTAssertThrowsError(
            try NativeXcode(
                project: engine.project, manifest: manifest, resolution: engine.resolution, integrateUserProjects: false)
        ) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCODE-CONFIG")
        }
    }

    func testSupplementaryCaseVariantsKeepDistinctTargetsAndProducts() throws {
        let original = try fixture(name: "Kit")
        let base = try XCTUnwrap(original.resolution.specs["Kit"])
        let spec = try NativeSpec(
            data: base.data.merging(["appspecs": [["name": "Example"], ["name": "example"]]]) { _, new in new },
            directory: original.project)
        var manifest = original.manifest
        var targets = try XCTUnwrap(manifest["targets"] as? [[String: Any]])
        targets[0]["dependencies"] = [["name": "Kit", "options": ["appspecs": ["Example", "example"]]]]
        manifest["targets"] = targets
        let engine = try NativeXcode(
            project: original.project, manifest: manifest,
            resolution: NativeResolution(specs: ["Kit": spec], requests: []), integrateUserProjects: false)
        try engine.generate()
        let products = try engine.supplementaryTargets.values.flatMap(\.values).map {
            let product = try XCTUnwrap(engine.graph.objects[$0]?["productReference"] as? String)
            return try XCTUnwrap(engine.graph.objects[product]?["path"] as? String)
                .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        }
        XCTAssertEqual(products.count, 2)
        XCTAssertEqual(Set(products).count, 2)
    }

    func testDefaultAppHostCannotCollideWithALibraryTarget() throws {
        let original = try fixture(name: "Kit")
        let base = try XCTUnwrap(original.resolution.specs["Kit"])
        let spec = try NativeSpec(
            data: base.data.merging(["testspecs": [["name": "Tests", "requires_app_host": true]]]) { _, new in new },
            directory: original.project)
        let literal = "AppHost-Kit-Unit-Tests"
        let peer = try NativeSpec(data: ["name": literal, "version": "1.0"], directory: original.project)
        var manifest = original.manifest
        var targets = try XCTUnwrap(manifest["targets"] as? [[String: Any]])
        targets[0]["dependencies"] = [
            ["name": "Kit", "options": ["testspecs": ["Tests"]]], ["name": literal],
        ]
        manifest["targets"] = targets
        let engine = try NativeXcode(
            project: original.project, manifest: manifest,
            resolution: NativeResolution(specs: ["Kit": spec, literal: peer], requests: []),
            integrateUserProjects: false)
        try engine.generate()
        let names = engine.targetIDs.compactMap { engine.graph.objects[$0]?["name"] as? String }
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(names.contains(literal))
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
