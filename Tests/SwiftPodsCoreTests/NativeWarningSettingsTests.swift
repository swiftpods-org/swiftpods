import XCTest

@testable import SwiftPodsCore

final class NativeWarningSettingsTests: XCTestCase {
    private func generated() throws -> (URL, NativeXcode) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let header = """
            #include "Aux.h"
            int vendor(void);
            #ifdef __OBJC__
            #import <Foundation/Foundation.h>
            @interface SDKObject : NSObject
            + (void)take:(NSUInteger)value;
            @end
            #endif

            """
        try Data(header.utf8).write(to: root.appendingPathComponent("Kit.h"))
        try Data("int helper(void);\n".utf8).write(to: root.appendingPathComponent("Aux.h"))
        let dependencies: [[String: Any]] = [
            ["name": "Quiet"], ["name": "Strict", "options": ["inhibit_warnings": false]],
        ]
        let specs = try Dictionary(
            uniqueKeysWithValues: ["Quiet", "Strict"].map { name in
                (name, try NativeSpec(data: ["name": name, "version": "1.0", "source_files": "*.h"], directory: root))
            })
        let requests = try dependencies.map { try NativeDependency($0, platform: "osx", deployment: "13.0") }
        let engine = try NativeXcode(
            project: root,
            manifest: [
                "targets": [
                    [
                        "name": "App", "platform": ["name": "osx", "deployment_target": "13.0"],
                        "frameworks": "static", "inhibit_warnings": true, "dependencies": dependencies,
                    ]
                ]
            ],
            resolution: NativeResolution(specs: specs, requests: requests), integrateUserProjects: false)
        try engine.generate()
        return (root, engine)
    }

    #if os(macOS)
        private func frameworks() throws -> URL {
            let (root, _) = try generated()
            for name in ["Quiet", "Strict"] {
                let framework = root.appendingPathComponent(name + ".framework")
                let headers = framework.appendingPathComponent("Headers")
                let modules = framework.appendingPathComponent("Modules")
                try FileManager.default.createDirectory(at: headers, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
                let support = root.appendingPathComponent("Pods/Target Support Files/" + name)
                for file in ["Kit.h", "Aux.h"] {
                    try FileManager.default.copyItem(
                        at: root.appendingPathComponent(file), to: headers.appendingPathComponent(file))
                }
                try FileManager.default.copyItem(
                    at: support.appendingPathComponent(name + "-umbrella.h"),
                    to: headers.appendingPathComponent(name + "-umbrella.h"))
                try FileManager.default.copyItem(
                    at: support.appendingPathComponent(name + ".modulemap"),
                    to: modules.appendingPathComponent("module.modulemap"))
            }
            return root
        }

        func testSuppressedSDKHeadersPreserveSwiftUnsignedIntegerTypes() throws {
            let root = try frameworks()
            let client = root.appendingPathComponent("client.swift")
            try Data("import Quiet\nlet value: UInt = 1\nSDKObject.take(value)\n".utf8).write(to: client)
            let result = try ToolProcess.run(
                "/usr/bin/xcrun",
                [
                    "swiftc", "-typecheck", "-warnings-as-errors", "-F", root.path,
                    "-module-cache-path", root.appendingPathComponent("swift-cache").path, client.path,
                ])
            XCTAssertEqual(result.status, 0, String(decoding: result.error, as: UTF8.self))
        }

        func testSuppressedSDKHeadersDoNotDisableConsumerCompilerWarnings() throws {
            let root = try frameworks()
            let client = root.appendingPathComponent("client.c")
            func compile(_ source: String) throws -> ToolOutput {
                try Data(source.utf8).write(to: client)
                return try ToolProcess.run(
                    "/usr/bin/xcrun",
                    [
                        "clang", "-fsyntax-only", "-x", "c", "-fmodules",
                        "-fmodules-cache-path=" + root.appendingPathComponent("cache").path,
                        "-F" + root.path, "-Werror", "-Wquoted-include-in-framework-header", client.path,
                    ])
            }
            XCTAssertEqual(try compile("#include <Quiet/Quiet-umbrella.h>\n").status, 0)
            let strict = try compile("#include <Strict/Strict-umbrella.h>\n")
            XCTAssertNotEqual(strict.status, 0)
            let own = try compile("#include <Quiet/Quiet-umbrella.h>\nint broken(void) {}\n")
            XCTAssertNotEqual(own.status, 0)
        }
    #endif

    func testExplicitSDKWarningSuppressionDoesNotConflictWithSwiftOrAffectOptedOutPods() throws {
        let (_, engine) = try generated()
        let names = ["Quiet", "Strict"]
        for name in names {
            let target = try XCTUnwrap(
                engine.graph.objects.values.first {
                    $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == name
                })
            let list = try XCTUnwrap(target["buildConfigurationList"] as? String)
            let configs = try XCTUnwrap(engine.graph.objects[list]?["buildConfigurations"] as? [String])
            for config in configs {
                let settings = try XCTUnwrap(engine.graph.objects[config]?["buildSettings"] as? [String: Any])
                XCTAssertEqual(settings["GCC_TREAT_WARNINGS_AS_ERRORS"] as? String, "YES")
                if name == "Quiet" {
                    XCTAssertEqual(settings["SWIFT_SUPPRESS_WARNINGS"] as? String, "YES")
                    XCTAssertEqual(settings["SWIFT_TREAT_WARNINGS_AS_ERRORS"] as? String, "NO")
                } else {
                    XCTAssertNil(settings["SWIFT_SUPPRESS_WARNINGS"])
                    XCTAssertEqual(settings["SWIFT_TREAT_WARNINGS_AS_ERRORS"] as? String, "YES")
                }
            }
        }
    }
}
