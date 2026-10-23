import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeModuleOwnershipTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func generate(
        _ specs: [NativeSpec], root: URL, separateConsumers: Bool = false, separateConfigurations: Bool = false
    ) throws {
        let groups = separateConsumers ? specs.map { [$0] } : [specs]
        let targets: [[String: Any]] = groups.enumerated().map { index, group in
            [
                "name": "App" + String(index), "platform": ["name": "osx", "deployment_target": "13.0"],
                "modular_headers": true,
                "dependencies": group.enumerated().map { offset, spec -> [String: Any] in
                    let options: [String: Any] =
                        separateConfigurations
                        ? ["configurations": [offset == 0 ? "Debug" : "Release"]] : [:]
                    return ["name": spec.name, "options": options]
                },
            ]
        }
        let engine = try NativeXcode(
            project: root, manifest: ["targets": targets],
            resolution: NativeResolution(
                specs: Dictionary(uniqueKeysWithValues: specs.map { ($0.name, $0) }), requests: []),
            integrateUserProjects: false)
        try engine.generate()
    }

    private func customMaps(
        _ contents: [String], aliases: [String] = ["FirstAlias", "SecondAlias"],
        separateConsumers: Bool = false, separateConfigurations: Bool = false
    ) throws {
        let root = try directory()
        let specs = try zip(["First", "Second"], zip(aliases, contents)).map { name, values -> NativeSpec in
            let source = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("#pragma once\n".utf8).write(to: source.appendingPathComponent(name + ".h"))
            try Data(("int " + name.lowercased() + "(void) { return 7; }\n").utf8).write(
                to: source.appendingPathComponent(name + ".c"))
            try Data(values.1.utf8).write(to: source.appendingPathComponent("Author.modulemap"))
            return try NativeSpec(
                data: [
                    "name": name, "version": "1.0", "module_name": values.0,
                    "source_files": "*.{c,h}", "module_map": "Author.modulemap",
                ], directory: source)
        }
        try generate(
            specs, root: root, separateConsumers: separateConsumers, separateConfigurations: separateConfigurations)
    }

    func testCustomMapsRejectDuplicateModulesEvenWhenPodAliasesDiffer() throws {
        for first in [
            "module Shared { header \"First.h\" export * }\n",
            "module FirstAPI { header \"First.h\" export * }\nmodule Shared { export * }\n",
        ] {
            XCTAssertThrowsError(try customMaps([first, "module Shared { header \"Second.h\" export * }\n"])) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCODE-MODULE-CONFLICT")
            }
        }
    }

    func testDistinctCustomMapsMayShareAnUnusedPodModuleAlias() throws {
        XCTAssertNoThrow(
            try customMaps(
                [
                    "module FirstAPI { header \"First.h\" export * }\n",
                    "module SecondAPI { header \"Second.h\" export * }\n",
                ],
                aliases: ["SharedAlias", "SharedAlias"]))
    }

    func testDistinctCustomModuleMapsRemainSupported() throws {
        XCTAssertNoThrow(
            try customMaps(
                [
                    "module FirstAPI { header \"First.h\" export * }\n",
                    "module SecondAPI { header \"Second.h\" export * }\n",
                ]))
    }

    func testCommentsAndNestedModuleNamesDoNotReserveTopLevelModules() throws {
        XCTAssertNoThrow(
            try customMaps([
                "// module Shared {}\nmodule FirstAPI { header \"First.h\" explicit module Shared { export * } }\n",
                "module Shared { header \"Second.h\" export * }\n",
            ]))
    }

    func testCustomModuleConflictsRespectConsumerAndConfigurationScopes() throws {
        let maps = [
            "module Shared { header \"First.h\" export * }\n", "module Shared { header \"Second.h\" export * }\n",
        ]
        XCTAssertNoThrow(try customMaps(maps, separateConsumers: true))
        XCTAssertNoThrow(try customMaps(maps, separateConfigurations: true))
    }

    private func sourceAndVendor(
        module: String = "SDK", separateConsumers: Bool = false, separateConfigurations: Bool = false
    ) throws {
        let root = try directory()
        let binary = root.appendingPathComponent("Binary")
        let framework = binary.appendingPathComponent("SDK.framework")
        for path in ["Headers", "Modules"] {
            try FileManager.default.createDirectory(
                at: framework.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        #if arch(arm64)
            let cpu: UInt32 = 0x0100_000c
        #else
            let cpu: UInt32 = 0x0100_0007
        #endif
        let words: [UInt32] = [0xfeed_facf, cpu, 0, 6, 1, 24, 0, 0, 0x32, 24, 1, 0x000d_0000, 0x001b_0000, 0]
        try Data(words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } })
            .write(to: framework.appendingPathComponent("SDK"))
        try Data("int sdk_value(void);\n".utf8).write(to: framework.appendingPathComponent("Headers/SDK.h"))
        try Data("framework module SDK { umbrella header \"SDK.h\" export * }\n".utf8).write(
            to: framework.appendingPathComponent("Modules/module.modulemap"))
        let source = root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("int source_value(void);\n".utf8).write(to: source.appendingPathComponent("Source.h"))
        try Data("int source_value(void) { return 7; }\n".utf8).write(to: source.appendingPathComponent("Source.c"))
        let specs = try [
            NativeSpec(
                data: ["name": "Binary", "version": "1.0", "vendored_frameworks": "SDK.framework"], directory: binary),
            NativeSpec(
                data: ["name": "Source", "version": "1.0", "module_name": module, "source_files": "*.{c,h}"],
                directory: source),
        ]
        try generate(
            specs, root: root, separateConsumers: separateConsumers, separateConfigurations: separateConfigurations)
    }

    func testSourceModuleCannotShadowAVendoredModule() throws {
        XCTAssertThrowsError(try sourceAndVendor()) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCODE-MODULE-CONFLICT")
        }
    }

    func testSourceAndVendorWithDifferentModulesRemainSupported() throws {
        XCTAssertNoThrow(try sourceAndVendor(module: "SourceAPI"))
    }

    func testSourceAndVendorConflictsRespectConsumerAndConfigurationScopes() throws {
        XCTAssertNoThrow(try sourceAndVendor(separateConsumers: true))
        XCTAssertNoThrow(try sourceAndVendor(separateConfigurations: true))
    }
}
