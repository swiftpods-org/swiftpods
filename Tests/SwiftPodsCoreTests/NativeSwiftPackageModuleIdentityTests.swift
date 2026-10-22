import XCTest

@testable import SwiftPodsCore

final class NativeSwiftPackageModuleIdentityTests: XCTestCase {
    private func fixture(
        product: String = "SDK", selected: String = "Other", module: String = "SDK",
        targets: [[String: Any]]? = nil, podAttributes: [String: Any] = [:], platform: String = "osx"
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
        let pod = try NativeSpec(
            data: [
                "name": "Kit", "version": "1.0", "module_name": module,
                "pod_target_xcconfig": ["DEFINES_MODULE": "YES"],
            ].merging(podAttributes) { _, new in new }, directory: root)
        let engine = try NativeXcode(
            project: root,
            manifest: [
                "targets": [["name": "App", "platform": ["name": platform], "dependencies": [["name": "Kit"]]]]
            ],
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
        for platform in ["osx", "ios"] {
            let (engine, user, graph) = try fixture(
                targets: [
                    ["name": "Other", "dependencies": [["target": ["SDK", ["platformNames": ["ios"]]]]]],
                    ["name": "SDK", "type": "regular"],
                ], platform: platform)
            if platform == "ios" {
                XCTAssertThrowsError(try validate(engine, user, graph, platform: platform)) {
                    XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-DUPLICATE-SDK")
                }
            } else {
                try validate(engine, user, graph, platform: platform)
            }
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

    func testPodCustomMapSuppliesItsDeclaredModulesInsteadOfThePodspecModuleName() throws {
        for (declared, actual, conflicts) in [("SDK", "Other", false), ("Other", "SDK", true)] {
            let (engine, user, graph) = try fixture(
                product: "Tools", selected: "SDK", module: declared,
                podAttributes: ["module_map": "Pod.modulemap"])
            try Data(("module " + actual + " { export * }\n").utf8)
                .write(to: engine.project.appendingPathComponent("Pod.modulemap"))
            if conflicts {
                XCTAssertThrowsError(try validate(engine, user, graph)) {
                    XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-DUPLICATE-SDK")
                }
            } else {
                try validate(engine, user, graph)
            }
        }
    }

    func testNonmodularPodDoesNotClaimASwiftPackageModule() throws {
        let (engine, user, graph) = try fixture(
            product: "Tools", selected: "SDK",
            podAttributes: ["module_map": false, "pod_target_xcconfig": [:] as [String: String]])
        try validate(engine, user, graph)
    }

    func testSwiftPodKeepsItsModuleAlongsideCustomClangModules() throws {
        let (engine, user, graph) = try fixture(
            product: "Tools", selected: "SDK",
            podAttributes: ["module_map": "Pod.modulemap", "source_files": "Pod.swift"])
        try Data("module Other { export * }\n".utf8).write(to: engine.project.appendingPathComponent("Pod.modulemap"))
        try Data("public struct PodAPI {}\n".utf8).write(to: engine.project.appendingPathComponent("Pod.swift"))
        XCTAssertThrowsError(try validate(engine, user, graph)) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-DUPLICATE-SDK")
        }
    }

    private func vendor(_ engine: NativeXcode, framework: Bool, module: String?) throws -> NativeVendorSDK {
        let root = engine.project.appendingPathComponent("Vendor")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Value.c")
        let object = root.appendingPathComponent("Value.o")
        try Data("int vendor_value(void) { return 42; }\n".utf8).write(to: source)
        try command("/usr/bin/xcrun", ["clang", "-Werror", "-c", source.path, "-o", object.path])
        let library = root.appendingPathComponent(framework ? "SDK.framework/SDK" : "Slice/libSDK.a")
        let headers = library.deletingLastPathComponent().appendingPathComponent("Headers")
        try FileManager.default.createDirectory(at: headers, withIntermediateDirectories: true)
        try command("/usr/bin/ar", ["rcs", library.path, object.path])
        let map = framework
            ? library.deletingLastPathComponent().appendingPathComponent("Modules/module.modulemap")
            : headers.appendingPathComponent("module.modulemap")
        if let module {
            try FileManager.default.createDirectory(at: map.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(("module " + module + " { export * }\n").utf8).write(to: map)
        }
        if framework { return try NativeVendorSDK(library.deletingLastPathComponent()) }
        let container = root.appendingPathComponent("Library.xcframework")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: library.deletingLastPathComponent(), to: container.appendingPathComponent("Slice"))
        #if arch(arm64)
            let architecture = "arm64"
        #else
            let architecture = "x86_64"
        #endif
        let info: [String: Any] = [
            "XCFrameworkFormatVersion": "1.0",
            "AvailableLibraries": [[
                "LibraryIdentifier": "Slice", "LibraryPath": "libSDK.a", "HeadersPath": "Headers",
                "SupportedPlatform": "macos", "SupportedArchitectures": [architecture],
            ]],
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: container.appendingPathComponent("Info.plist"))
        return try NativeVendorSDK(container)
    }

    func testVendoredModuleMapsReplaceTheBinaryProductBasename() throws {
        for framework in [false, true] {
            let (engine, user, graph) = try fixture(product: "Tools", selected: "SDK", module: "Wrapper")
            engine.vendorSDKs["Kit:osx"] = [try vendor(engine, framework: framework, module: "Other")]
            try validate(engine, user, graph)
        }
    }

    func testActualVendoredModulesConflictEvenWhenTheBinaryHasAnotherName() throws {
        for framework in [false, true] {
            let (engine, user, graph) = try fixture(product: "Tools", selected: "Other", module: "Wrapper")
            engine.vendorSDKs["Kit:osx"] = [try vendor(engine, framework: framework, module: "Other")]
            XCTAssertThrowsError(try validate(engine, user, graph)) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-DUPLICATE-SDK")
            }
        }
    }

    func testNonmodularVendoredBinariesDoNotClaimTheirProductBasename() throws {
        for framework in [false, true] {
            let (engine, user, graph) = try fixture(product: "Tools", selected: "SDK", module: "Wrapper")
            engine.vendorSDKs["Kit:osx"] = [try vendor(engine, framework: framework, module: nil)]
            try validate(engine, user, graph)
        }
    }

    func testVendoredSwiftModulesAreCheckedAlongsideClangModuleMaps() throws {
        let (engine, user, graph) = try fixture(product: "Tools", selected: "SDK", module: "Wrapper")
        let sdk = try vendor(engine, framework: true, module: "Other")
        try FileManager.default.createDirectory(
            at: sdk.url.appendingPathComponent("Modules/SDK.swiftmodule"), withIntermediateDirectories: true)
        engine.vendorSDKs["Kit:osx"] = [sdk]
        XCTAssertThrowsError(try validate(engine, user, graph)) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-DUPLICATE-SDK")
        }
    }

    func testLinkedPackageAliasesUseTheActualRenamedModule() throws {
        for module in ["Shared", "AliasedShared"] {
            let (engine, user, previous) = try fixture(product: "Tools", module: module)
            let dependency = engine.project.appendingPathComponent("Dependency")
            let sources = dependency.appendingPathComponent("Sources/Shared")
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            try Data("public struct API {}\n".utf8).write(to: sources.appendingPathComponent("API.swift"))
            let graph = try NativeSwiftPackageGraph(
                directory: previous.directory, environment: [:], moduleMaps: previous.moduleMaps
            ) { package in
                if package.identity == "dependency" {
                    return ["products": [["name": "Shared", "targets": ["Shared"]]], "targets": [["name": "Shared"]]]
                }
                return [
                    "products": [["name": "Tools", "targets": ["Other"]]],
                    "dependencies": [["fileSystem": [["identity": "dependency", "path": dependency.path]]]],
                    "targets": [
                        [
                            "name": "Other",
                            "dependencies": [
                                [
                                    "product": [
                                        "Shared", "dependency", ["Shared": "AliasedShared"], NSNull(),
                                    ]
                                ]
                            ],
                        ]
                    ],
                ]
            }
            if module == "AliasedShared" {
                XCTAssertThrowsError(try validate(engine, user, graph)) {
                    XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-DUPLICATE-SDK")
                }
            } else {
                try validate(engine, user, graph)
            }
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
