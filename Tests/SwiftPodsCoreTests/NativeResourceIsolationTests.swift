import XCTest

@testable import SwiftPodsCore

final class NativeResourceIsolationTests: XCTestCase {
    private func directory(_ files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in files {
            let path = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(name.utf8).write(to: path)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func engine(
        _ root: URL, specs: [NativeSpec], dependencies: [[String: Any]], platform: String = "osx", mode: String? = nil
    ) throws -> NativeXcode {
        let catalog = Dictionary(uniqueKeysWithValues: specs.map { ($0.name, $0) })
        let requests = try dependencies.flatMap {
            try NativeDependency($0, platform: platform, deployment: "15.0").expandedSelections()
        }
        let resolution = try NativeResolver(candidates: { catalog[$0.root].map { [$0] } ?? [] }).resolve(requests)
        var target: [String: Any] = [
            "name": "Demo", "platform": ["name": platform, "deployment_target": "15.0"], "dependencies": dependencies,
        ]
        target["frameworks"] = mode
        let generated = try NativeXcode(
            project: root, manifest: ["targets": [target]], resolution: resolution, integrateUserProjects: false)
        try generated.generate()
        return generated
    }

    func testResourceBundlesProduceStableProjectBytesAcrossRepeatedGeneration() throws {
        let root = try directory(["asset.txt"])
        let names = ["Zulu", "Alpha", "Beta", "Middle", "Omega"]
        let bundles = Dictionary(uniqueKeysWithValues: names.map { ($0, "asset.txt") })
        let spec = try NativeSpec(
            data: ["name": "Kit", "version": "1.0", "resource_bundles": bundles], directory: root)
        var first: Data?
        for _ in 0..<6 {
            let generated = try engine(root, specs: [spec], dependencies: [["name": "Kit"]])
            let products = generated.products.compactMap { generated.graph.objects[$0] }.filter {
                $0["explicitFileType"] as? String == "wrapper.cfbundle"
            }.compactMap { $0["path"] as? String }
            XCTAssertEqual(products, names.sorted().map { $0 + ".bundle" })
            try generated.graph.save()
            let contents = try Data(contentsOf: generated.graph.url)
            if let first { XCTAssertEqual(contents, first) }
            first = contents
        }
    }

    func testResourceBundlePlistsOmitExecutablesAcrossPlatformsAndLinkageModes() throws {
        for platform in ["osx", "ios"] {
            for mode: String? in [nil, "static", "dynamic"] {
                let root = try directory(["asset.txt"])
                let spec = try NativeSpec(
                    data: [
                        "name": "Kit", "version": "1.0", "resources": "asset.txt",
                        "resource_bundles": ["Privacy": "asset.txt"], "info_plist": ["Author": "Fixture"],
                        "appspecs": [["name": "Example", "resource_bundles": ["AppResources": "asset.txt"]]],
                        "testspecs": [["name": "Checks", "resource_bundles": ["TestResources": "asset.txt"]]],
                    ], directory: root)
                let engine = try engine(
                    root, specs: [spec],
                    dependencies: [["name": "Kit", "options": ["appspecs": ["Example"], "testspecs": ["Checks"]]]],
                    platform: platform, mode: mode)
                var resourceCount = 0
                for target in engine.graph.objects.values {
                    guard let type = target["productType"] as? String,
                        type == "com.apple.product-type.bundle" || type == "com.apple.product-type.application"
                            || type == "com.apple.product-type.bundle.unit-test"
                            || type == "com.apple.product-type.framework"
                    else { continue }
                    let list = try XCTUnwrap(target["buildConfigurationList"] as? String)
                    let configurations = try XCTUnwrap(engine.graph.objects[list]?["buildConfigurations"] as? [String])
                    for id in configurations {
                        let configuration = try XCTUnwrap(engine.graph.objects[id])
                        let settings = try NativeBuildSettings.resolvedScopes(
                            configuration, graph: engine.graph, targetName: target["name"] as? String
                        ).targetScope
                        let path = try XCTUnwrap(settings.expandedValue("INFOPLIST_FILE", undefinedAsEmpty: true))
                        let plist = try XCTUnwrap(
                            PropertyListSerialization.propertyList(
                                from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as? [String: Any])
                        XCTAssertEqual(try settings.expandedValue("GENERATE_INFOPLIST_FILE"), "NO")
                        if type == "com.apple.product-type.bundle" {
                            XCTAssertNil(plist["CFBundleExecutable"])
                            XCTAssertEqual(plist["CFBundlePackageType"] as? String, "BNDL")
                        } else {
                            XCTAssertEqual(plist["CFBundleExecutable"] as? String, "$(EXECUTABLE_NAME)")
                        }
                    }
                    if type == "com.apple.product-type.bundle" { resourceCount += 1 }
                }
                XCTAssertEqual(resourceCount, mode == "dynamic" ? 3 : 4)
            }
        }
    }

    func testOnDemandExclusionsStayWithTheirDeclaringSubspec() throws {
        for platform in ["osx", "ios"] {
            for mode: String? in [nil, "static", "dynamic"] {
                let root = try directory(["A/a.txt", "A/hidden.txt", "B/b.txt"])
                let spec = try NativeSpec(
                    data: [
                        "name": "Kit", "version": "1.0",
                        "subspecs": [
                            [
                                "name": "A", "on_demand_resources": ["a": ["A/*.txt"]],
                                "exclude_files": ["A/hidden.txt", "B/*"],
                            ],
                            ["name": "B", "on_demand_resources": ["b": "B/*.txt"]],
                        ],
                    ], directory: root)
                let generated = try engine(
                    root, specs: [spec], dependencies: [["name": "Kit"]], platform: platform, mode: mode)
                let resources = try generated.onDemandResources(roots: ["Kit"], platform: platform)
                XCTAssertEqual(
                    Set(resources.files.keys.map(\.lastPathComponent)), ["a.txt", "b.txt"],
                    "\(platform)/\(mode ?? "library")")
            }
        }
    }

    func testRepeatedOnDemandTagKeepsEverySelectedOwnersPaths() throws {
        let root = try directory(["root.txt", "A/a.txt", "B/b.txt", "shared.txt"])
        let spec = try NativeSpec(
            data: [
                "name": "Kit", "version": "1.0", "on_demand_resources": ["common": "root.txt"],
                "subspecs": [
                    [
                        "name": "A",
                        "on_demand_resources": ["common": ["A/a.txt", "shared.txt"], "extra": "shared.txt"],
                    ],
                    ["name": "B", "on_demand_resources": ["common": "B/b.txt"]],
                ],
            ], directory: root)
        let generated = try engine(root, specs: [spec], dependencies: [["name": "Kit"]])
        let resources = try generated.onDemandResources(roots: ["Kit"], platform: "osx")
        XCTAssertEqual(
            Set(resources.files.keys.map(\.lastPathComponent)), ["root.txt", "a.txt", "b.txt", "shared.txt"])
        XCTAssertEqual(resources.files[root.appendingPathComponent("shared.txt")], ["common", "extra"])
    }

    func testSupplementaryResourcesHonorExclusionsInEveryLinkageMode() throws {
        for platform in ["osx", "ios"] {
            for mode: String? in [nil, "static", "dynamic"] {
                let root = try directory([
                    "App/keep.txt", "App/hidden.txt", "App/Hidden/deep.txt",
                    "Test/keep.txt", "Test/hidden.txt", "Test/Hidden/deep.txt",
                ])
                func declaration(_ directory: String, name: String) -> [String: Any] {
                    [
                        "name": name, "resources": [directory + "/*.txt", directory + "/Hidden"],
                        "exclude_files": [directory + "/hidden.txt", directory + "/Hidden"],
                    ]
                }
                let spec = try NativeSpec(
                    data: [
                        "name": "Kit", "version": "1.0", "appspecs": [declaration("App", name: "Example")],
                        "testspecs": [declaration("Test", name: "Checks")],
                    ], directory: root)
                let generated = try engine(
                    root, specs: [spec],
                    dependencies: [
                        [
                            "name": "Kit", "options": ["appspecs": ["Example"], "testspecs": ["Checks"]],
                        ]
                    ], platform: platform, mode: mode)
                for name in ["Kit-Example", "Kit-Unit-Checks"] {
                    let target = try XCTUnwrap(generated.graph.objects.values.first { $0["name"] as? String == name })
                    let refs = (target["buildPhases"] as? [String] ?? []).filter {
                        generated.graph.objects[$0]?["isa"] as? String == "PBXResourcesBuildPhase"
                    }.flatMap { generated.graph.objects[$0]?["files"] as? [String] ?? [] }.compactMap {
                        generated.graph.objects[$0]?["fileRef"] as? String
                    }
                    let paths = refs.compactMap { generated.graph.objects[$0]?["path"] as? String }
                    XCTAssertEqual(
                        paths.map { URL(fileURLWithPath: $0).lastPathComponent }, ["keep.txt"],
                        "\(platform)/\(mode ?? "library")/\(name)")
                }
            }
        }
    }

    func testConfigurationExclusionsIncludeOnDemandFilesAndPreserveSharedPaths() throws {
        let root = try directory(["alpha.txt", "beta.txt", "shared.txt"])
        let alpha = try NativeSpec(
            data: [
                "name": "Alpha", "version": "1.0", "on_demand_resources": ["alpha": ["alpha.txt", "shared.txt"]],
            ], directory: root)
        let beta = try NativeSpec(
            data: [
                "name": "Beta", "version": "1.0", "resources": "shared.txt",
                "on_demand_resources": ["beta": "beta.txt"],
            ], directory: root)
        let generated = try engine(root, specs: [alpha, beta], dependencies: [["name": "Alpha"], ["name": "Beta"]])
        XCTAssertEqual(
            try generated.consumerAssetExclusions(eligible: ["Alpha", "Beta"], enabled: ["Beta"], platform: "osx"),
            [root.appendingPathComponent("alpha.txt").path])
    }

    func testResourceKindsUseTheSameOwnerExclusionPolicy() throws {
        for reversed in [false, true] {
            let root = try directory(["A/keep.txt", "A/hidden.txt", "B/keep.txt", "B/hidden.txt"])
            var children: [[String: Any]] = [
                [
                    "name": "A", "resources": "A/*.txt", "resource_bundles": ["Shared": "A/*.txt"],
                    "on_demand_resources": ["shared": "A/*.txt"], "exclude_files": ["A/hidden.txt", "B/*"],
                ],
                [
                    "name": "B", "resources": "B/*.txt", "resource_bundles": ["Shared": "B/*.txt"],
                    "on_demand_resources": ["shared": "B/*.txt"], "exclude_files": "B/hidden.txt",
                ],
            ]
            if reversed { children.reverse() }
            let spec = try NativeSpec(data: ["name": "Kit", "version": "1.0", "subspecs": children], directory: root)
            let files = try NativeLibraryFiles(spec: spec, names: ["Kit/A", "Kit/B"], platform: "osx", root: root)
            let generated = try engine(root, specs: [spec], dependencies: [["name": "Kit"]])
            let expected: Set<URL> = [
                root.appendingPathComponent("A/keep.txt"), root.appendingPathComponent("B/keep.txt"),
            ]
            XCTAssertEqual(Set(try files.paths("resources")), expected)
            XCTAssertEqual(Set(try files.resourceBundles()["Shared"] ?? []), expected)
            XCTAssertEqual(Set(try generated.onDemandResources(roots: ["Kit"], platform: "osx").files.keys), expected)
        }
    }

    func testConditionalTagsKeepSeparateReferencesAndLocalization() throws {
        let root = try directory(["shared.txt", "en.lproj/Localizable.strings"])
        let files = [
            root.appendingPathComponent("shared.txt"), root.appendingPathComponent("en.lproj/Localizable.strings"),
        ]
        let debug = try NativeOnDemandResources(
            attributes: ["on_demand_resources": ["alpha": ["shared.txt", "en.lproj/*.strings"]]], root: root)
        let profile = try NativeOnDemandResources(
            attributes: ["on_demand_resources": ["beta": ["shared.txt", "en.lproj/*.strings"]]], root: root)
        let plan = try NativeConditionalResources(
            directory: root.appendingPathComponent("Support"), normal: ["Release": files],
            configurations: ["Debug": debug, "Profile": profile, "Release": NativeOnDemandResources()])
        XCTAssertTrue(Set(plan.paths).isDisjoint(with: files))
        XCTAssertEqual(plan.paths.count, 6)
        for (configuration, tags): (String, Set<String>) in [
            ("Debug", ["alpha"]), ("Profile", ["beta"]), ("Release", []),
        ] {
            let visible = plan.paths.filter { !(plan.exclusions[configuration] ?? []).contains($0.path) }
            XCTAssertEqual(visible.count, 2)
            for path in visible {
                let source = try FileManager.default.destinationOfSymbolicLink(atPath: path.path)
                XCTAssertTrue(files.map(\.path).contains(source))
                XCTAssertEqual(plan.onDemand.files[path] ?? [], tags)
                if path.pathExtension == "strings" {
                    XCTAssertEqual(path.deletingLastPathComponent().lastPathComponent, "en.lproj")
                }
            }
        }
    }

    func testConditionalPlanIsStableAndDoesNotAliasUnambiguousResources() throws {
        let root = try directory(["shared.txt", "exclusive.txt", "always.txt"])
        let shared = root.appendingPathComponent("shared.txt")
        let exclusive = root.appendingPathComponent("exclusive.txt")
        let always = root.appendingPathComponent("always.txt")
        let debug = try NativeOnDemandResources(
            attributes: ["on_demand_resources": ["alpha": ["shared.txt", "exclusive.txt"]]], root: root)
        let normal: [String: [URL]] = ["Debug": [always], "Release": [always, shared]]
        let first = try NativeConditionalResources(
            directory: root.appendingPathComponent("Support"), normal: normal,
            configurations: ["Debug": debug, "Release": NativeOnDemandResources()])
        let second = try NativeConditionalResources(
            directory: root.appendingPathComponent("Support"),
            normal: ["Release": [shared, always], "Debug": [always]],
            configurations: ["Release": NativeOnDemandResources(), "Debug": debug])
        XCTAssertEqual(first.paths, second.paths)
        XCTAssertEqual(first.onDemand.files, second.onDemand.files)
        XCTAssertEqual(first.exclusions, second.exclusions)
        XCTAssertTrue(first.paths.contains(always))
        XCTAssertTrue(first.paths.contains(exclusive))
        XCTAssertFalse(first.paths.contains(shared))
    }

    func testOpaqueResourceDirectoriesKeepTheirLayoutAndTaggedChildren() throws {
        for includesRelease in [false, true] {
            let root = try directory(["Folder/nested.txt"])
            let folder = root.appendingPathComponent("Folder")
            let file = folder.appendingPathComponent("nested.txt")
            let resources = try NativeOnDemandResources(
                attributes: ["on_demand_resources": ["alpha": "Folder/nested.txt"]], root: root)
            var normal = ["Debug": [folder]]
            var configurations = ["Debug": resources]
            if includesRelease {
                normal["Release"] = [folder]
                configurations["Release"] = NativeOnDemandResources()
            }
            let plan = try NativeConditionalResources(
                directory: root.appendingPathComponent("Support"), normal: normal, configurations: configurations)
            XCTAssertEqual(plan.paths.count, 2)
            XCTAssertFalse(plan.paths.contains(file))
            let alias = try XCTUnwrap(plan.paths.first { $0 != folder })
            XCTAssertEqual(plan.onDemand.files[alias], ["alpha"])
            XCTAssertEqual(try? FileManager.default.destinationOfSymbolicLink(atPath: alias.path), file.path)
            let graph = try NativePBX(root.appendingPathComponent("project.pbxproj"))
            let refs = try NativeResources.references(
                plan.paths, owner: "Demo", graph: graph, ungrouped: Set(plan.onDemand.files.keys))
            XCTAssertEqual(refs.count, 2, "Directory copying must not suppress the tagged child reference")
            if includesRelease {
                XCTAssertEqual(plan.exclusions["Release"], [alias.path])
            }
        }
    }

    func testLocalizedDirectorySelectionsMatchFileGlobsAndKeepRawHookPaths() throws {
        for directories in [true, false] {
            let root = try directory([
                "en.lproj/Localizable.strings", "en.lproj/Hidden.strings", "fr.lproj/Localizable.strings",
            ])
            let patterns = directories ? ["en.lproj", "fr.lproj"] : ["*.lproj/*.strings"]
            let attributes: [String: Any] = [
                "name": "Kit", "version": "1.0", "resources": patterns,
                "resource_bundles": ["Own": patterns], "on_demand_resources": ["locale": ["paths": patterns]],
                "exclude_files": "en.lproj/Hidden.strings",
            ]
            let expected: Set<URL> = [
                root.appendingPathComponent("en.lproj/Localizable.strings"),
                root.appendingPathComponent("fr.lproj/Localizable.strings"),
            ]
            let spec = try NativeSpec(data: attributes, directory: root)
            let files = try NativeLibraryFiles(spec: spec, names: ["Kit"], platform: "osx", root: root)
            XCTAssertEqual(Set(try files.paths("resources")), expected)
            XCTAssertEqual(Set(try files.resourceBundles()["Own"] ?? []), expected)
            let onDemand = try NativeOnDemandResources(attributes: attributes, root: root)
            XCTAssertEqual(Set(onDemand.files.keys), expected)
            XCTAssertTrue(onDemand.files.values.allSatisfy { $0 == ["locale"] })
            if directories {
                let response = try NativeFileAccessor.response([
                    "value": [
                        "root": root.path, "attributes": attributes, "operation": "on_demand_resources_files",
                    ]
                ])
                XCTAssertEqual(
                    Set(response["result"] as? [String] ?? []),
                    [root.appendingPathComponent("en.lproj").path, root.appendingPathComponent("fr.lproj").path])
            }
        }
    }
}
