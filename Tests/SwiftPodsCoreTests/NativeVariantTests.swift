import XCTest
@testable import SwiftPodsCore

final class NativeVariantTests: XCTestCase {
    private func spec(staticFramework: Bool = false) throws -> NativeSpec {
        try NativeSpec(data: ["name": "Kit", "version": "1.0", "default_subspecs": ["A"], "static_framework": staticFramework, "subspecs": [["name": "A", "source_files": "A/*.c"], ["name": "B", "source_files": "B/*.c"]], "testspecs": [["name": "Tests"]], "appspecs": [["name": "Example"]]])
    }
    private func target(_ name: String, mode: String? = nil, deployment: String = "13.0", selection: String = "Kit/A", extra: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = ["name": name, "platform": ["name": "osx", "deployment_target": deployment], "dependencies": [["name": selection, "options": extra]]]
        if let mode { value["frameworks"] = mode }; return value
    }
    func testEquivalentSelectionsDeduplicateWithoutUnioningOtherConsumers() throws {
        let resolved = NativeResolution(specs: ["Kit": try spec()], requests: [])
        let plan = try NativeVariantPlan(manifest: ["targets": [target("A"), target("Same"), target("B", selection: "Kit/B")]], resolution: resolved)
        XCTAssertEqual(plan.variants.count, 2)
        XCTAssertEqual(plan.consumers["A"], plan.consumers["Same"])
        XCTAssertNotEqual(plan.consumers["A"], plan.consumers["B"])
        XCTAssertEqual(Set(plan.variants.values.map { Set($0.names) }), [Set(["Kit/A"]), Set(["Kit/B"])])
    }
    func testScopeLabelsPreserveDefaultSelectionAndBuildTypeNames() throws {
        let resolved = NativeResolution(specs: ["Kit": try spec()], requests: [])
        let selected = try NativeVariantPlan(manifest: ["targets": [target("Default", selection: "Kit"), target("Other", selection: "Kit/B")]], resolution: resolved)
        XCTAssertEqual(Set(selected.variants.values.map(\.label)), ["Kit", "Kit-B"])
        let modes = try NativeVariantPlan(manifest: ["targets": [target("Lib"), target("Static", mode: "static"), target("Dynamic", mode: "dynamic")]], resolution: resolved)
        XCTAssertEqual(Set(modes.variants.values.map(\.label)), ["Kit-library", "Kit-framework-static", "Kit-framework-dynamic"])
    }
    func testSameNamedConsumersInDifferentDefinitionsKeepTheirSelections() throws {
        let resolved = NativeResolution(specs: ["Kit": try spec()], requests: [])
        var first = target("App"), second = target("App", selection: "Kit/B")
        first["label"] = "Pods-First-App"; second["label"] = "Pods-Second-App"
        let plan = try NativeVariantPlan(manifest: ["targets": [first, second]], resolution: resolved)
        XCTAssertNotEqual(plan.consumers["Pods-First-App"], plan.consumers["Pods-Second-App"])
    }
    func testPackagingLinkageAndDeploymentAreIndependentVariantDimensions() throws {
        let resolved = NativeResolution(specs: ["Kit": try spec()], requests: [])
        let targets = [target("Library"), target("Static", mode: "static"), target("Dynamic", mode: "dynamic"), target("Newer", mode: "static", deployment: "14.0")]
        let plan = try NativeVariantPlan(manifest: ["targets": targets], resolution: resolved)
        XCTAssertEqual(plan.variants.count, 4)
        XCTAssertEqual(Set(plan.variants.values.map(\.label)).count, 4)
        XCTAssertEqual(Set(plan.variants.values.map(\.headerScope)).count, 4)
        XCTAssertTrue(plan.variants.values.allSatisfy(\.scoped))
        let reordered = try NativeVariantPlan(manifest: ["targets": Array(targets.reversed())], resolution: resolved)
        XCTAssertEqual(plan.consumers, reordered.consumers)
        XCTAssertEqual(plan.variants.mapValues(\.label), reordered.variants.mapValues(\.label))
    }
    func testStaticFrameworkOverrideStillPreservesLibraryPackaging() throws {
        let resolved = NativeResolution(specs: ["Kit": try spec(staticFramework: true)], requests: [])
        let plan = try NativeVariantPlan(manifest: ["targets": [target("Library"), target("Static", mode: "static"), target("Dynamic", mode: "dynamic")]], resolution: resolved)
        XCTAssertEqual(plan.variants.count, 2)
        XCTAssertEqual(plan.consumers["Static"], plan.consumers["Dynamic"])
        XCTAssertNotEqual(plan.consumers["Library"], plan.consumers["Static"])
    }
    func testSupplementarySelectionsShareLibraryVariantAndRetainBothSelections() throws {
        let resolved = NativeResolution(specs: ["Kit": try spec()], requests: [])
        let plan = try NativeVariantPlan(manifest: ["targets": [target("Tests", selection: "Kit", extra: ["testspecs": ["Tests"]]), target("Apps", selection: "Kit", extra: ["appspecs": ["Example"]])]], resolution: resolved)
        XCTAssertEqual(plan.variants.count, 1)
        let variant = try XCTUnwrap(plan.variants.values.first)
        XCTAssertEqual(variant.names, ["Kit", "Kit/A"])
        XCTAssertEqual(Set(variant.supplementary.map(\.name)), ["Kit/Tests", "Kit/Example"])
    }
    func testTransitiveVariantsFollowTheirConsumersBuildType() throws {
        let kit = try NativeSpec(data: ["name": "Kit", "version": "1.0", "dependencies": ["Peer": []]])
        let peer = try NativeSpec(data: ["name": "Peer", "version": "1.0"])
        let resolution = NativeResolution(specs: ["Kit": kit, "Peer": peer], requests: [])
        let plan = try NativeVariantPlan(manifest: ["targets": [target("Static", mode: "static", selection: "Kit"), target("Dynamic", mode: "dynamic", selection: "Kit")]], resolution: resolution)
        XCTAssertEqual(plan.variants.count, 4)
        for variant in plan.variants.values where variant.root == "Kit" {
            let dependency = try XCTUnwrap(plan.variants[variant.bindings["Peer"] ?? ""])
            XCTAssertEqual(dependency.mode, variant.mode)
        }
    }
    func testAmbiguousSubspecLabelsHaveDistinctStableNames() throws {
        let kit = try NativeSpec(data: ["name": "Kit", "version": "1.0", "subspecs": [["name": "A"], ["name": "B"], ["name": "A-B"]]])
        let resolved = NativeResolution(specs: ["Kit": kit], requests: [])
        let targets = [target("One", selection: "Kit/A-B"), target("Two", selection: "Kit", extra: ["subspecs": ["A", "B"]])]
        let plan = try NativeVariantPlan(manifest: ["targets": targets], resolution: resolved)
        XCTAssertEqual(plan.variants.count, 2)
        XCTAssertEqual(Set(plan.variants.values.map(\.label)).count, 2)
        XCTAssertEqual(plan.variants.mapValues(\.label), try NativeVariantPlan(manifest: ["targets": Array(targets.reversed())], resolution: resolved).variants.mapValues(\.label))
    }
    func testPlainArchiveModulesRequireSwiftOrAnExplicitOptIn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let resolution = NativeResolution(specs: ["Kit": try spec()], requests: [])
        let engine = try NativeXcode(project: root, manifest: ["targets": [target("Plain")]], resolution: resolution, integrateUserProjects: false)
        let variant = try XCTUnwrap(engine.variantPlan?.variants.values.first)
        XCTAssertFalse(engine.requiresModule(variant, attributes: [:], sources: [root.appendingPathComponent("source.m")]))
        XCTAssertTrue(engine.requiresModule(variant, attributes: [:], sources: [root.appendingPathComponent("source.swift")]))
        XCTAssertTrue(engine.requiresModule(variant, attributes: ["pod_target_xcconfig": ["DEFINES_MODULE": "YES"]], sources: []))
        XCTAssertTrue(engine.requiresModule(variant, attributes: ["module_map": "custom.modulemap"], sources: []))
        let modular = try NativeXcode(project: root, manifest: ["targets": [target("Modular", extra: ["modular_headers": true])]], resolution: resolution, integrateUserProjects: false)
        XCTAssertTrue(modular.requiresModule(try XCTUnwrap(modular.variantPlan?.variants.values.first), attributes: [:], sources: []))
    }
    func testSelectedSwiftAppSpecCanImportItsObjectiveCArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("int kit(void);".utf8).write(to: root.appendingPathComponent("Kit.h"))
        try Data("import Kit".utf8).write(to: root.appendingPathComponent("Example.swift"))
        let kit = try NativeSpec(data: ["name": "Kit", "version": "1.0", "source_files": "Kit.h", "appspecs": [["name": "Example", "source_files": "Example.swift"]]], directory: root)
        let resolution = NativeResolution(specs: ["Kit": kit], requests: [])
        for selected in [false, true] {
            let manifest: [String: Any] = ["targets": [target("App", selection: "Kit", extra: selected ? ["appspecs": ["Example"]] : [:])]]
            let engine = try NativeXcode(project: root, manifest: manifest, resolution: resolution, integrateUserProjects: false)
            try engine.generate()
            let target = try XCTUnwrap(engine.graph.objects.values.first { $0["name"] as? String == "Kit" && $0["isa"] as? String == "PBXNativeTarget" })
            let list = try XCTUnwrap(target["buildConfigurationList"] as? String)
            let configuration = try XCTUnwrap((engine.graph.objects[list]?["buildConfigurations"] as? [String])?.first { engine.graph.objects[$0]?["name"] as? String == "Debug" })
            let settings = try XCTUnwrap(engine.graph.objects[configuration]?["buildSettings"] as? [String: Any])
            XCTAssertEqual(settings["DEFINES_MODULE"] as? String, selected ? "YES" : "NO")
            XCTAssertEqual(settings["MODULEMAP_FILE"] is String, selected)
        }
    }
}
