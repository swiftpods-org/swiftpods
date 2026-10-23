import XCTest

@testable import SwiftPodsCore

final class NativeSwiftPackageAliasTests: XCTestCase {
    private func graph(
        _ documents: [String: [String: Any]], roots: [String]? = nil, rootTraits: [String: Set<String>] = [:]
    ) throws -> NativeSwiftPackageGraph {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for (name, document) in documents {
            for target in document["targets"] as? [[String: Any]] ?? [] {
                let sources = root.appendingPathComponent(name + "/Sources/" + (target["name"] as! String))
                try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
                try Data("public struct API {}\n".utf8).write(to: sources.appendingPathComponent("API.swift"))
            }
        }
        let entries: [[String: Any]] = documents.keys.sorted().map {
            let path = root.appendingPathComponent($0).path
            return ["packageRef": ["identity": $0, "location": path], "state": ["name": "fileSystem", "path": path]]
        }
        try jsonData(["object": ["dependencies": entries]]).write(
            to: root.appendingPathComponent("workspace-state.json"))
        return try NativeSwiftPackageGraph(
            directory: root, environment: [:],
            moduleMaps: NativeSwiftPackageModuleMaps(directory: root.appendingPathComponent("Maps")),
            roots: roots?.map {
                .init(location: root.appendingPathComponent($0).path, traits: rootTraits[$0] ?? ["default"])
            }
        ) { package in
            var document = documents[package.identity]!
            if let dependencies = document["dependencies"] as? [String] {
                document["dependencies"] = dependencies.map {
                    ["fileSystem": [["identity": $0, "path": root.appendingPathComponent($0).path]]]
                }
            }
            return document
        }
    }

    private func documents(
        condition: Any = NSNull(), traits: [[String: Any]] = [], exported: Bool = true, test: Bool = false
    ) -> [String: [String: Any]] {
        [
            "dependency": ["products": [["name": "Shared", "targets": ["Shared"]]], "targets": [["name": "Shared"]]],
            "package": [
                "dependencies": ["dependency"], "traits": traits,
                "products": [["name": "Bare", "targets": ["BareAPI"]]]
                    + (exported ? [["name": "Aliased", "targets": ["AliasAPI"]]] : []),
                "targets": [
                    ["name": "BareAPI", "dependencies": [["product": ["Shared", "dependency", NSNull(), NSNull()]]]],
                    [
                        "name": "AliasAPI", "type": test ? "test" : "regular",
                        "dependencies": [
                            ["product": ["Shared", "dependency", ["Shared": "RenamedShared"], condition]]
                        ],
                    ],
                ],
            ],
        ]
    }

    private func names(_ graph: NativeSwiftPackageGraph, products: [String] = ["Bare"]) throws -> Set<String> {
        let package = try XCTUnwrap(graph.packages.first { $0.identity == "package" })
        return Set(
            try NativeSwiftPackageTargets.list(
                products, package: package, graph: graph, platform: "osx", allowAliases: true
            ).map(\.moduleName))
    }

    private func forest(sameAlias: Bool = false, outer: String? = nil) -> [String: [String: Any]] {
        var result: [String: [String: Any]] = ["dependency": documents()["dependency"]!]
        for (wrapper, root, product, module, alias) in [
            ("p", "package", "Bare", "First", "FirstShared"),
            ("q", "rootb", "Other", "Second", sameAlias ? "FirstShared" : "SecondShared"),
        ] {
            result[wrapper] = [
                "dependencies": ["dependency"], "products": [["name": "API", "targets": [module + "API"]]],
                "targets": [
                    [
                        "name": module + "API",
                        "dependencies": [
                            ["product": ["Shared", "dependency", NSNull(), NSNull()]]
                        ],
                    ]
                ],
            ]
            result[root] = [
                "dependencies": [wrapper], "products": [["name": product, "targets": [module + "Root"]]],
                "targets": [
                    [
                        "name": module + "Root",
                        "dependencies": [
                            ["product": ["API", wrapper, ["Shared": alias], NSNull()]]
                        ],
                    ]
                ],
            ]
        }
        if let outer {
            let first: Any =
                outer == "none" ? NSNull() : [outer == "intermediate" ? "FirstShared" : "Shared": "CommonShared"]
            let second: Any =
                outer == "none" ? NSNull() : [outer == "intermediate" ? "SecondShared" : "Shared": "CommonShared"]
            result["common"] = [
                "dependencies": ["package", "rootb"], "products": [["name": "All", "targets": ["All"]]],
                "targets": [
                    [
                        "name": "All",
                        "dependencies": [
                            ["product": ["Bare", "package", first, NSNull()]],
                            ["product": ["Other", "rootb", second, NSNull()]],
                        ],
                    ]
                ],
            ]
        }
        return result
    }

    func testIndependentRootsMustAgreeOnTheNameOfTheSamePhysicalModule() throws {
        for _ in 0..<3 {
            XCTAssertThrowsError(try names(graph(forest()))) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-SPM-ALIASES")
            }
        }
        XCTAssertEqual(try names(graph(forest(sameAlias: true))), ["FirstRoot", "FirstAPI", "FirstShared"])
    }

    func testAMoreDependentRenameCanResolveIndependentAliasConflicts() throws {
        XCTAssertThrowsError(try names(graph(forest(outer: "none")))) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-SPM-ALIASES")
        }
        for outer in ["original", "intermediate"] {
            XCTAssertEqual(try names(graph(forest(outer: outer))), ["FirstRoot", "FirstAPI", "CommonShared"])
        }
    }

    func testOverridesFollowConsumersWhenAProducerAlsoHasADeeperDependencyPath() throws {
        var documents = forest()
        documents.removeValue(forKey: "rootb")
        documents["common"] = [
            "dependencies": ["package", "q", "deep0"], "products": [["name": "All", "targets": ["All"]]],
            "targets": [
                [
                    "name": "All",
                    "dependencies": [
                        ["product": ["Bare", "package", NSNull(), NSNull()]],
                        ["product": ["API", "q", ["Shared": "CommonShared"], NSNull()]],
                        ["product": ["API", "deep0", NSNull(), NSNull()]],
                    ],
                ]
            ],
        ]
        for index in 0..<3 {
            let dependency = index == 2 ? "q" : "deep" + String(index + 1)
            let name = "deep" + String(index)
            documents[name] = [
                "dependencies": [dependency], "products": [["name": "API", "targets": [name]]],
                "targets": [["name": name, "dependencies": [["product": ["API", dependency, NSNull(), NSNull()]]]]],
            ]
        }
        XCTAssertEqual(try names(graph(documents)), ["FirstRoot", "FirstAPI", "CommonShared"])
    }

    func testAliasFromAnUnselectedPublicProductRenamesTheSharedDependency() throws {
        let graph = try graph(documents())
        XCTAssertEqual(try names(graph), ["BareAPI", "RenamedShared"])
        XCTAssertEqual(try names(graph, products: ["Bare", "Aliased"]), ["BareAPI", "AliasAPI", "RenamedShared"])
    }

    func testAliasesOnlyPropagateThroughProductsReachableFromPackageRoots() throws {
        for nested in [false, true] {
            var documents = documents()
            documents["private"] = [
                "dependencies": ["dependency"], "products": [["name": "Bridge", "targets": ["Bridge"]]],
                "targets": [
                    ["name": "Bridge", "dependencies": [["product": ["Shared", "dependency", NSNull(), NSNull()]]]]
                ],
            ]
            documents["package"]?["dependencies"] = ["dependency", "private"]
            var targets = documents["package"]?["targets"] as! [[String: Any]]
            targets[1]["dependencies"] = [["product": ["Bridge", "private", ["Shared": "RenamedShared"], NSNull()]]]
            documents["package"]?["targets"] = targets
            if nested {
                documents["outer"] = [
                    "dependencies": ["package"], "products": [["name": "Wrap", "targets": ["Wrap"]]],
                    "targets": [
                        ["name": "Wrap", "dependencies": [["product": ["Bare", "package", NSNull(), NSNull()]]]]
                    ],
                ]
            }
            XCTAssertEqual(try names(graph(documents)), ["BareAPI", nested ? "Shared" : "RenamedShared"])
            if nested {
                XCTAssertEqual(try names(graph(documents, roots: ["outer", "package"])), ["BareAPI", "Shared"])
            }
        }
    }

    func testAliasPropagationRetainsProductIdentityWhenProductsShareTargets() throws {
        var documents = documents()
        documents["private"] = [
            "dependencies": ["dependency"],
            "products": [
                ["name": "BareBridge", "targets": ["Bridge"]], ["name": "AliasBridge", "targets": ["Bridge"]],
            ],
            "targets": [
                ["name": "Bridge", "dependencies": [["product": ["Shared", "dependency", NSNull(), NSNull()]]]]
            ],
        ]
        documents["package"]?["dependencies"] = ["private"]
        documents["package"]?["targets"] = [
            ["name": "BareAPI", "dependencies": [["product": ["BareBridge", "private", NSNull(), NSNull()]]]],
            [
                "name": "AliasAPI",
                "dependencies": [["product": ["AliasBridge", "private", ["Shared": "RenamedShared"], NSNull()]]],
            ],
        ]
        documents["outer"] = [
            "dependencies": ["package"], "products": [["name": "Wrap", "targets": ["Wrap"]]],
            "targets": [["name": "Wrap", "dependencies": [["product": ["Bare", "package", NSNull(), NSNull()]]]]],
        ]
        XCTAssertEqual(try names(graph(documents)), ["BareAPI", "Bridge", "Shared"])
    }

    func testUnexportedAndTestTargetsDoNotRenamePublicDependencies() throws {
        for test in [false, true] {
            let graph = try graph(documents(exported: false, test: test))
            XCTAssertEqual(try names(graph), ["BareAPI", "Shared"])
        }
    }

    func testPlatformConditionsDoNotLimitGlobalAliasPropagation() throws {
        let graph = try graph(documents(condition: ["platformNames": ["ios"]]))
        XCTAssertEqual(try names(graph), ["BareAPI", "RenamedShared"])
    }

    func testTraitsControlAliasesIncludingDefaultAndTransitiveImplications() throws {
        for enabled in [false, true] {
            let graph = try graph(
                documents(
                    condition: ["platformNames": [], "traits": ["Feature", "Other"]],
                    traits: [
                        ["name": "default", "enabledTraits": enabled ? ["Intermediate"] : []],
                        ["name": "Intermediate", "enabledTraits": ["Feature"]],
                        ["name": "Feature", "enabledTraits": []],
                    ]))
            XCTAssertEqual(try names(graph), ["BareAPI", enabled ? "RenamedShared" : "Shared"])
        }
    }

    func testAliasesRemainScopedToTheReferencedPackage() throws {
        var documents = documents()
        documents["peer"] = ["products": [["name": "Peer", "targets": ["Shared"]]], "targets": [["name": "Shared"]]]
        documents["package"]?["dependencies"] = ["dependency", "peer"]
        var targets = documents["package"]?["targets"] as! [[String: Any]]
        targets[0]["dependencies"] = [
            ["product": ["Shared", "dependency", NSNull(), NSNull()]],
            ["product": ["Peer", "peer", NSNull(), NSNull()]],
        ]
        documents["package"]?["targets"] = targets
        XCTAssertEqual(try names(graph(documents)), ["BareAPI", "Shared", "RenamedShared"])
    }

    func testPublicAliasesFromAnUnlinkedRootPackageStillApply() throws {
        var documents = documents(exported: false)
        documents["unlinked"] = [
            "dependencies": ["dependency"], "products": [["name": "Unused", "targets": ["Unused"]]],
            "targets": [
                [
                    "name": "Unused",
                    "dependencies": [
                        ["product": ["Shared", "dependency", ["Shared": "UnlinkedShared"], NSNull()]]
                    ],
                ]
            ],
        ]
        XCTAssertEqual(try names(graph(documents)), ["BareAPI", "UnlinkedShared"])
    }

    func testExplicitRootTraitsOverrideThePackagesDefaults() throws {
        for defaults in [false, true] {
            for requested: Set<String> in [[], ["Feature"], ["default"]] {
                let documents = documents(
                    condition: ["traits": ["Feature"]],
                    traits: [
                        ["name": "default", "enabledTraits": defaults ? ["Feature"] : []],
                        ["name": "Feature", "enabledTraits": []],
                    ])
                let expected = requested.contains("Feature") || (defaults && requested.contains("default"))
                XCTAssertEqual(
                    try names(graph(documents, roots: ["package"], rootTraits: ["package": requested])),
                    ["BareAPI", expected ? "RenamedShared" : "Shared"])
            }
        }
    }

    func testDisabledTraitsRemoveConditionalModulesFromTheSelectedInterface() throws {
        for enabled in [false, true] {
            var documents = documents(exported: false)
            documents["package"]?["traits"] = [["name": "Feature", "enabledTraits": []]]
            var targets = documents["package"]?["targets"] as! [[String: Any]]
            targets[0]["dependencies"] = [
                ["product": ["Shared", "dependency", NSNull(), ["platformNames": [], "traits": ["Feature"]]]]
            ]
            documents["package"]?["targets"] = targets
            XCTAssertEqual(
                try names(graph(documents, roots: ["package"], rootTraits: ["package": enabled ? ["Feature"] : []])),
                enabled ? ["BareAPI", "Shared"] : ["BareAPI"])
        }
    }

    func testCompilerOnlyInterfacesRejectAnAliasDeclaredByASiblingProduct() throws {
        let graph = try graph(documents())
        let package = try XCTUnwrap(graph.packages.first { $0.identity == "package" })
        XCTAssertThrowsError(
            try NativeSwiftPackageTargets.list(["Bare"], package: package, graph: graph, platform: "osx")
        ) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-SPM-ALIASES")
        }
    }

    func testOuterAliasesCanRenameEitherTheOriginalOrAnIntermediateName() throws {
        for original in ["Shared", "RenamedShared"] {
            var documents = documents()
            documents["outer"] = [
                "dependencies": ["package"], "products": [["name": "Wrap", "targets": ["Wrap"]]],
                "targets": [
                    [
                        "name": "Wrap",
                        "dependencies": [
                            ["product": ["Bare", "package", [original: "FinalShared"], NSNull()]]
                        ],
                    ]
                ],
            ]
            let graph = try graph(documents)
            XCTAssertEqual(try names(graph), ["BareAPI", "FinalShared"])
        }
    }

    func testAProducerModuleShadowsTheSameOriginalNameInItsDependencies() throws {
        var documents = documents()
        documents["package"] = [
            "dependencies": ["dependency"], "products": [["name": "Bare", "targets": ["Shared"]]],
            "targets": [
                [
                    "name": "Shared",
                    "dependencies": [
                        ["product": ["Shared", "dependency", ["Shared": "InnerShared"], NSNull()]]
                    ],
                ]
            ],
        ]
        documents["outer"] = [
            "dependencies": ["package"], "products": [["name": "Wrap", "targets": ["Wrap"]]],
            "targets": [
                [
                    "name": "Wrap",
                    "dependencies": [
                        ["product": ["Bare", "package", ["Shared": "FinalShared"], NSNull()]]
                    ],
                ]
            ],
        ]
        XCTAssertEqual(try names(graph(documents)), ["FinalShared", "InnerShared"])
    }

    func testAnOuterAliasIsConsumedByTheFirstMatchingDependencyProduct() throws {
        for (reverse, internalBranch) in [(false, false), (true, false), (false, true)] {
            var documents = documents()
            documents["peer"] = documents["dependency"]
            var dependencies: [[String: Any]] = [
                ["product": ["Shared", "dependency", ["Shared": "FirstShared"], NSNull()]],
                ["product": ["Shared", "peer", ["Shared": "SecondShared"], NSNull()]],
            ]
            if reverse { dependencies.reverse() }
            documents["package"] = [
                "dependencies": ["dependency", "peer"], "products": [["name": "Bare", "targets": ["Wrapper"]]],
                "targets": [["name": "Wrapper", "dependencies": dependencies]],
            ]
            if internalBranch {
                documents["package"]?["targets"] = [
                    ["name": "Wrapper", "dependencies": [dependencies[0], ["target": ["Helper", NSNull()]]]],
                    ["name": "Helper", "dependencies": [dependencies[1]]],
                ]
            }
            documents["outer"] = [
                "dependencies": ["package"], "products": [["name": "Wrap", "targets": ["Wrap"]]],
                "targets": [
                    [
                        "name": "Wrap",
                        "dependencies": [
                            ["product": ["Bare", "package", ["Shared": "FinalShared"], NSNull()]]
                        ],
                    ]
                ],
            ]
            var expected: Set<String> = [
                "Wrapper", "FinalShared", reverse || internalBranch ? "FirstShared" : "SecondShared",
            ]
            if internalBranch { expected.insert("Helper") }
            XCTAssertEqual(try names(graph(documents)), expected)
        }
    }

    func testDependencyTraitRequestsRespectExplicitEmptyDefaultsAndDirectRoots() throws {
        var documents = documents(
            condition: ["traits": ["Feature"]],
            traits: [
                ["name": "default", "enabledTraits": ["Feature"]], ["name": "Feature", "enabledTraits": []],
            ])
        documents["outer"] = [
            "dependencies": [["fileSystem": [["identity": "package", "path": "../package", "traits": []]]]],
            "products": [["name": "Wrap", "targets": ["Wrap"]]],
            "targets": [["name": "Wrap", "dependencies": [["product": ["Bare", "package", NSNull(), NSNull()]]]]],
        ]
        XCTAssertEqual(try names(graph(documents, roots: ["outer"])), ["BareAPI", "Shared"])
        XCTAssertEqual(try names(graph(documents, roots: ["outer", "package"])), ["BareAPI", "RenamedShared"])
    }
}
