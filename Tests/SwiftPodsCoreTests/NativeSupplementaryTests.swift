import XCTest
@testable import SwiftPodsCore

final class NativeSupplementaryTests: XCTestCase {
    private func fixture() throws -> NativeSpec {
        try NativeSpec(data: ["name": "Kit", "version": "1.0", "source_files": "Library/*", "resources": "Library/asset", "script_phase": ["name": "Library", "script": "true"],
            "dependencies": ["Common": ["~> 1.0"]], "pod_target_xcconfig": ["FLAG": "parent"], "info_plist": ["Parent": "value"],
            "testspecs": [["name": "Tests", "source_files": "Tests/*", "dependencies": ["TestHelper": []], "pod_target_xcconfig": ["FLAG": "test"]]],
            "appspecs": [["name": "Demo", "source_files": "Demo/*", "dependencies": ["AppHelper": []]]]])
    }
    func testAuxiliaryAttributesExcludeLibrarySourcesResourcesAndScripts() throws {
        let spec = try fixture()
        let values = try spec.attributes("Kit/Tests", platform: "osx")
        XCTAssertEqual(try spec.kind("Kit/Tests"), .test)
        XCTAssertEqual(try spec.kind("Kit/Demo"), .app)
        XCTAssertEqual(values["source_files"] as? String, "Tests/*")
        XCTAssertNil(values["resources"])
        XCTAssertNil(values["script_phase"])
        XCTAssertNil(values["info_plist"])
        XCTAssertEqual((values["pod_target_xcconfig"] as? [String: String])?["FLAG"], "test")
        XCTAssertEqual(Set((values["dependencies"] as! [String: Any]).keys), ["Common", "TestHelper"])
    }
    func testDefaultResolutionDoesNotSelectTestsOrApps() throws {
        let spec = try fixture(), common = try NativeSpec(data: ["name": "Common", "version": "1.0"])
        let result = try NativeResolver(candidates: { $0.root == "Kit" ? [spec] : [common] }).resolve([NativeDependency(["name": "Kit"])])
        XCTAssertEqual(Set(result.requests.map(\.name)), ["Kit", "Common"])
        XCTAssertThrowsError(try spec.nodes("Kit/Missing"))
    }
    func testSelectionsExpandWithExternalOptionsAndResolveOwnDependencies() throws {
        let requests = try NativeDependency(["name": "Kit", "options": ["path": "Modules/Kit", "testspecs": ["Tests"], "appspecs": ["Demo"]]], platform: "osx", deployment: "13.0").expandedSelections()
        XCTAssertEqual(requests.map(\.name), ["Kit", "Kit/Tests", "Kit/Demo"])
        XCTAssertTrue(requests.allSatisfy { $0.options["path"] as? String == "Modules/Kit" && $0.options["testspecs"] == nil })
        let spec = try fixture()
        let catalog = try ["Kit": [spec], "Common": [NativeSpec(data: ["name": "Common", "version": "1.0"])], "TestHelper": [NativeSpec(data: ["name": "TestHelper", "version": "1.0"])], "AppHelper": [NativeSpec(data: ["name": "AppHelper", "version": "1.0"])]]
        let result = try NativeResolver(candidates: { catalog[$0.root] ?? [] }).resolve(requests)
        XCTAssertEqual(Set(result.specs.keys), ["Kit", "Common", "TestHelper", "AppHelper"])
        XCTAssertThrowsError(try NativeDependency(["name": "Kit", "options": ["testspecs": "Tests"]]).expandedSelections())
    }
    func testSupplementaryMinimumCanExceedConsumerAndInvalidHostIsRejected() throws {
        let spec = try NativeSpec(data: ["name": "Kit", "version": "1.0", "testspecs": [["name": "Tests", "osx": ["deployment_target": "15.0"]], ["name": "Bad", "app_host_name": "Kit/App"]], "appspecs": [["name": "App"]]])
        XCTAssertNoThrow(try spec.dependencies(for: NativeDependency(["name": "Kit/Tests"], platform: "osx", deployment: "13.0")))
        XCTAssertThrowsError(try spec.validateSupplementary(NativeDependency(["name": "Kit/Bad"])))
    }
    func testConsumerDependencyClosureExcludesTestOnlyDependencies() throws {
        let spec = try fixture()
        let common = try NativeSpec(data: ["name": "Common", "version": "1.0"])
        let helper = try NativeSpec(data: ["name": "TestHelper", "version": "1.0"])
        let requests = try ["Kit", "Kit/Tests", "Common", "TestHelper"].map { try NativeDependency(["name": $0], platform: "osx", deployment: "13.0") }
        let resolved = NativeResolution(specs: ["Kit": spec, "Common": common, "TestHelper": helper], requests: requests)
        let engine = try NativeXcode(project: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), manifest: [:], resolution: resolved, integrateUserProjects: false)
        XCTAssertEqual(try engine.dependencyRoots([requests[0], requests[1]]), ["Kit", "Common"])
        XCTAssertEqual(try engine.dependencyRoots([requests[0], requests[1]], includeSupplementary: true), ["Kit", "Common", "TestHelper"])
    }
    func testUITypesValidateAndRejectUnknownTypes() throws {
        let spec = try NativeSpec(data: ["name": "Kit", "version": "1.0", "testspecs": [["name": "UI", "test_type": "ui"], ["name": "Unknown", "test_type": "unknown"], ["name": "Invalid", "test_type": 7]]])
        XCTAssertEqual(try spec.testType("Kit/UI", platform: "ios"), .ui)
        XCTAssertNoThrow(try spec.validateSupplementary(NativeDependency(["name": "Kit/UI"])))
        for name in ["Unknown", "Invalid"] {
            XCTAssertThrowsError(try spec.validateSupplementary(NativeDependency(["name": "Kit/" + name]))) { error in
                XCTAssertEqual((error as? Diagnostic)?.code, "SP-TEST-TYPE")
            }
        }
    }
    func testUIHostAssociatesRunnerWhileUnitHostUsesBundleLoader() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tests: [[String: Any]] = ["unit", "ui"].map { ["name": $0, "test_type": $0, "requires_app_host": true, "app_host_name": "Kit/App", "dependencies": ["Kit/App": []]] }
        let spec = try NativeSpec(data: ["name": "Kit", "version": "1.0", "platforms": ["ios": "15.0"], "testspecs": tests, "appspecs": [["name": "App"]]], directory: directory, local: true)
        let direct = try NativeDependency(["name": "Kit", "options": ["testspecs": ["unit", "ui"]]], platform: "ios", deployment: "15.0").expandedSelections()
        let resolution = try NativeResolver(candidates: { _ in [spec] }).resolve(direct)
        let engine = try NativeXcode(project: directory, manifest: ["targets": [["name": "Demo", "platform": ["name": "ios", "deployment_target": "15.0"], "dependencies": direct.map { ["name": $0.name] }]]], resolution: resolution, integrateUserProjects: false)
        try engine.generate()
        let graph = engine.graph
        let host = try XCTUnwrap(graph.objects.first { $0.value["name"] as? String == "Kit-App" && $0.value["isa"] as? String == "PBXNativeTarget" }?.key)
        let root = try XCTUnwrap(graph.root["rootObject"] as? String)
        let attributes = try XCTUnwrap((graph.objects[root]?["attributes"] as? [String: Any])?["TargetAttributes"] as? [String: [String: String]])
        for type in [NativeTestType.unit, .ui] {
            let target = try XCTUnwrap(graph.objects.first { $0.value["name"] as? String == "Kit-" + type.label + "-" + type.rawValue && $0.value["isa"] as? String == "PBXNativeTarget" })
            XCTAssertEqual(target.value["productType"] as? String, type.productType)
            XCTAssertEqual(attributes[target.key]?["TestTargetID"], host)
            let list = try XCTUnwrap(target.value["buildConfigurationList"] as? String)
            for id in graph.objects[list]?["buildConfigurations"] as? [String] ?? [] {
                let settings = try XCTUnwrap(graph.objects[id]?["buildSettings"] as? [String: Any])
                if type == .ui {
                    XCTAssertEqual(settings["TEST_TARGET_NAME"] as? String, "Kit-App")
                    XCTAssertNil(settings["TEST_HOST"]); XCTAssertNil(settings["BUNDLE_LOADER"])
                } else {
                    XCTAssertEqual(settings["TEST_HOST"] as? String, "$(BUILT_PRODUCTS_DIR)/Kit-App.app/Kit-App")
                    XCTAssertEqual(settings["BUNDLE_LOADER"] as? String, "$(TEST_HOST)")
                }
            }
        }
    }
}
