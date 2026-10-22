import XCTest

@testable import SwiftPodsCore

final class NativeSwiftPackageModuleIdentityTests: XCTestCase {
    private func fixture(
        product: String = "SDK", selected: String = "Other", module: String = "SDK",
        targets: [[String: Any]]? = nil
    ) throws -> (NativeXcode, NativePBX, NativeSwiftPackageGraph) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Package")
        let declarations = targets ?? Set([selected, "SDK"]).sorted().map { ["name": $0, "type": "regular"] }
        for target in declarations {
            let headers = package.appendingPathComponent("Sources/" + (target["name"] as! String) + "/include")
            try FileManager.default.createDirectory(at: headers, withIntermediateDirectories: true)
        }
        let resolved = root.appendingPathComponent("Resolved")
        try FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
        try jsonData([
            "object": [
                "dependencies": [
                    [
                        "packageRef": ["identity": "package", "location": package.path],
                        "state": ["name": "fileSystem", "path": package.path],
                    ]
                ]
            ]
        ]).write(to: resolved.appendingPathComponent("workspace-state.json"))
        let graph = try NativeSwiftPackageGraph(
            directory: resolved, environment: [:],
            moduleMaps: NativeSwiftPackageModuleMaps(directory: root.appendingPathComponent("Maps"))
        ) { _ in
            ["products": [["name": product, "targets": [selected]]], "targets": declarations]
        }
        let pod = try NativeSpec(data: ["name": "Kit", "version": "1.0", "module_name": module], directory: root)
        let engine = try NativeXcode(
            project: root,
            manifest: ["targets": [["name": "App", "platform": ["name": "osx"], "dependencies": [["name": "Kit"]]]]],
            resolution: NativeResolution(specs: ["Kit": pod], requests: []), integrateUserProjects: false)
        let user = try NativePBX(root.appendingPathComponent("App.xcodeproj/project.pbxproj"))
        user.root = ["rootObject": "ROOT"]
        user.objects = [
            "ROOT": ["isa": "PBXProject", "packageReferences": ["PACKAGE"]],
            "APP": ["isa": "PBXNativeTarget", "packageProductDependencies": ["PRODUCT"], "buildPhases": []],
            "PACKAGE": ["isa": "XCLocalSwiftPackageReference", "relativePath": "Package"],
            "PRODUCT": ["isa": "XCSwiftPackageProductDependency", "productName": product, "package": "PACKAGE"],
        ]
        return (engine, user, graph)
    }

    private func validate(
        _ engine: NativeXcode, _ user: NativePBX, _ graph: NativeSwiftPackageGraph, platform: String = "osx"
    ) throws {
        try engine.validateExistingPackages(user, target: "APP", roots: ["Kit"], platform: platform, graph: graph)
    }

    func testProductNameCollisionWithAnUnselectedModuleIsAccepted() throws {
        let (engine, user, graph) = try fixture()
        XCTAssertTrue(engine.packagesNeedModuleValidation(user, target: "APP", roots: ["Kit"], platform: "osx"))
        try validate(engine, user, graph)
        let integrator = NativeSwiftPackageIntegrator()
        try integrator.prepare(user, record: nil)
        try integrator.integrate(
            [
                ["git": "https://example.invalid/package.git", "exact": "1.0.0", "products": ["SDK"]]
            ], targetID: "APP", user: user)
    }

    func testActualTargetModuleCollisionIsRejectedEvenWhenTheProductHasAnotherName() throws {
        let (engine, user, graph) = try fixture(product: "Tools", selected: "SDK")
        XCTAssertTrue(engine.packagesNeedModuleValidation(user, target: "APP", roots: ["Kit"], platform: "osx"))
        XCTAssertThrowsError(try validate(engine, user, graph)) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-DUPLICATE-SDK")
        }
    }

    func testDifferentProductNamesStillRequireValidationOfTheirActualModules() throws {
        let (engine, user, graph) = try fixture(product: "Tools")
        XCTAssertTrue(engine.packagesNeedModuleValidation(user, target: "APP", roots: ["Kit"], platform: "osx"))
        try validate(engine, user, graph)
    }

    func testUnattachedPackagesAndConsumersWithoutPodsDoNotRequireModuleValidation() throws {
        let (engine, user, _) = try fixture()
        XCTAssertFalse(engine.packagesNeedModuleValidation(user, target: "APP", roots: [], platform: "osx"))
        user.objects["APP"]?["packageProductDependencies"] = [] as [String]
        XCTAssertFalse(engine.packagesNeedModuleValidation(user, target: "APP", roots: ["Kit"], platform: "osx"))
        XCTAssertNotNil(user.objects["PACKAGE"])
    }

    func testTransitiveModuleConditionsFollowTheConsumerPlatform() throws {
        let (engine, user, graph) = try fixture(targets: [
            ["name": "Other", "dependencies": [["target": ["SDK", ["platformNames": ["ios"]]]]]],
            ["name": "SDK", "type": "regular"],
        ])
        try validate(engine, user, graph)
        XCTAssertThrowsError(try validate(engine, user, graph, platform: "ios")) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-DUPLICATE-SDK")
        }
    }

    func testCustomClangMapUsesItsDeclaredModuleIdentity() throws {
        let (engine, user, graph) = try fixture()
        let package = try graph.package(user.sourceRoot.appendingPathComponent("Package").path)
        let map = package.directory.appendingPathComponent("Sources/Other/include/module.modulemap")
        try Data("module SDK { export * }\n".utf8).write(to: map)
        XCTAssertThrowsError(try validate(engine, user, graph)) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-DUPLICATE-SDK")
        }
    }

    func testNormalizedTargetNamesAndBuildOnlyDependenciesAreChecked() throws {
        let (engine, user, graph) = try fixture(selected: "SDK-Helper", module: "SDK_Helper")
        user.objects["APP"]?["packageProductDependencies"] = [] as [String]
        user.objects["APP"]?["dependencies"] = ["BUILD"]
        user.objects["BUILD"] = ["isa": "PBXTargetDependency", "productRef": "PRODUCT"]
        XCTAssertTrue(engine.packagesNeedModuleValidation(user, target: "APP", roots: ["Kit"], platform: "osx"))
        XCTAssertThrowsError(try validate(engine, user, graph)) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-DUPLICATE-SDK")
        }
    }

    func testHostImplementationModulesDoNotConflictWithConsumerPods() throws {
        let (engine, user, graph) = try fixture(targets: [
            ["name": "Other", "dependencies": [["target": ["SDK", NSNull()]]]],
            ["name": "SDK", "type": "macro"],
        ])
        try validate(engine, user, graph)
    }

    func testPackageInferenceWithoutAnExplicitReferenceUsesResolvedProductTargets() throws {
        let (engine, user, graph) = try fixture()
        user.objects["PRODUCT"]?.removeValue(forKey: "package")
        try validate(engine, user, graph)
    }
}
