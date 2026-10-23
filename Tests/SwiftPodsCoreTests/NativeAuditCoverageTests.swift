import Foundation
import XCTest

@testable import SwiftPodsCore

/// Public-interface and regeneration contracts found by the ten-case audit.
final class NativeAuditCoverageTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func write(_ text: String, _ relative: String, at root: URL) throws {
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func source(_ name: String, module: String, at root: URL, map: Bool = false) throws -> NativeSpec {
        let folder = root.appendingPathComponent(name)
        try write("#define \(name.uppercased())_API 7\n", name + ".h", at: folder)
        try write("int \(name.lowercased())_value(void) { return 7; }\n", name + ".c", at: folder)
        var data: [String: Any] = ["name": name, "version": "1.0", "module_name": module, "source_files": "*.{c,h}"]
        if map {
            data["module_map"] = "Author.modulemap"
            try write("module \(module) { header \"\(name).h\" export * }\n", "Author.modulemap", at: folder)
        }
        return try NativeSpec(data: data, directory: folder)
    }

    private func binary(_ name: String, module: String, at root: URL, swift: Bool = false) throws -> NativeSpec {
        let folder = root.appendingPathComponent(name)
        let framework = folder.appendingPathComponent(name + "SDK.framework")
        let version = framework.appendingPathComponent("Versions/A")
        try write("#define \(name.uppercased())_API 11\n", "Headers/" + name + "SDK.h", at: version)
        try write(
            "framework module \(module) { umbrella header \"\(name)SDK.h\" export * }\n", "Modules/module.modulemap",
            at: version)
        if swift {
            try write(
                "invalid Swift interface\n", "Modules/" + name + "SDK.swiftmodule/arm64-apple-macos.swiftinterface",
                at: version)
        }
        #if arch(arm64)
            let cpu: UInt32 = 0x0100_000c
        #else
            let cpu: UInt32 = 0x0100_0007
        #endif
        let words: [UInt32] = [0xfeed_facf, cpu, 0, 6, 1, 24, 0, 0, 0x32, 24, 1, 0x000d_0000, 0x001b_0000, 0]
        try Data(words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } })
            .write(to: version.appendingPathComponent(name + "SDK"))
        try FileManager.default.createSymbolicLink(
            atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        for entry in ["Headers", "Modules", name + "SDK"] {
            try FileManager.default.createSymbolicLink(
                atPath: framework.appendingPathComponent(entry).path, withDestinationPath: "Versions/Current/" + entry)
        }
        return try NativeSpec(
            data: ["name": name, "version": "1.0", "vendored_frameworks": name + "SDK.framework"], directory: folder)
    }

    private func engine(
        _ specs: [NativeSpec], at root: URL, dependencies: [[String: Any]]? = nil,
        search: [[String: Any]] = [], multiple: Bool = false
    ) throws -> NativeXcode {
        try NativeXcode(
            project: root,
            manifest: [
                "options": ["generate_multiple_pod_projects": multiple],
                "targets": [
                    [
                        "name": "App", "platform": ["name": "osx", "deployment_target": "13.0"],
                        "modular_headers": true, "dependencies": dependencies ?? specs.map { ["name": $0.name] },
                        "search_dependencies": search,
                    ]
                ],
            ],
            resolution: NativeResolution(
                specs: Dictionary(uniqueKeysWithValues: specs.map { ($0.name, $0) }), requests: []),
            integrateUserProjects: false)
    }

    func testCaseFoldedChildProjectCannotOverwriteTheAggregateProject() throws {
        let root = try directory()
        let spec = try source("Kit", module: "Kit", at: root)
        let generated = try engine(
            [spec], at: root, dependencies: [["name": "Kit", "options": ["project_name": "pods"]]], multiple: true)
        try generated.generate()
        XCTAssertThrowsError(try generated.prepareMultipleProjects()) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCODE-PROJECT")
        }
    }

    func testCaseDistinctConfigurationsKeepIndependentSupportFiles() throws {
        let root = try directory()
        let generated = try engine([], at: root)
        let first = try generated.supportConfiguration(
            label: "Pods-App", name: "Debug", settings: ["OTHER_CFLAGS": ["-DFIRST=1"]])
        let before = try Data(contentsOf: first)
        let second = try generated.supportConfiguration(
            label: "Pods-App", name: "DEBUG", settings: ["OTHER_CFLAGS": ["-DSECOND=1"]])
        XCTAssertEqual(try Data(contentsOf: first), before, "Generating DEBUG must not rewrite Debug")
        XCTAssertNotEqual(first, second)
    }

    func testCustomModuleNamesRemainCaseSensitive() throws {
        let root = try directory()
        let specs = try [
            source("First", module: "Feature", at: root, map: true),
            source("Second", module: "feature", at: root, map: true),
        ]
        XCTAssertNoThrow(try engine(specs, at: root).generate())
    }

    func testBinaryModulesCannotShadowEachOther() throws {
        let root = try directory()
        let specs = try [binary("First", module: "Shared", at: root), binary("Second", module: "Shared", at: root)]
        XCTAssertThrowsError(try engine(specs, at: root).generate()) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCODE-MODULE-CONFLICT")
        }
    }

    func testBinaryOnlyPodsStillOwnTheirExplicitModuleMap() throws {
        let root = try directory()
        let vendor = try binary("Binary", module: "VendorAPI", at: root)
        var data = vendor.data
        data["module_map"] = "Facade.modulemap"
        try write("module Shared { header \"Facade.h\" export * }\n", "Facade.modulemap", at: vendor.directory!)
        try write("int facade(void);\n", "Facade.h", at: vendor.directory!)
        let facade = try NativeSpec(data: data, directory: vendor.directory)
        let local = try source("Source", module: "Shared", at: root, map: true)
        XCTAssertThrowsError(try engine([facade, local], at: root).generate()) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCODE-MODULE-CONFLICT")
        }
    }

    func testBeforeHeadersRecognizesBracedBuildSettingPaths() throws {
        let root = try directory()
        let graph = try NativePBX(root.appendingPathComponent("project.pbxproj"))
        let copy = graph.add(
            "copy", ["isa": "PBXCopyFilesBuildPhase", "dstPath": "${PUBLIC_HEADERS_FOLDER_PATH}/Mapped", "files": []])
        let compile = graph.add("compile", ["isa": "PBXSourcesBuildPhase", "files": []])
        let target = graph.add("target", ["isa": "PBXNativeTarget", "buildPhases": [copy, compile]])
        let phase = try NativeScriptPhase([
            "name": "Generate", "script": "true", "execution_position": "before_headers",
        ])
        NativeScriptPhase.apply([phase], target: target, graph: graph)
        let order = try XCTUnwrap(graph.objects[target]?["buildPhases"] as? [String])
        let script = try XCTUnwrap(order.first { graph.objects[$0]?["name"] as? String == "[CP-User] Generate" })
        XCTAssertLessThan(try XCTUnwrap(order.firstIndex(of: script)), try XCTUnwrap(order.firstIndex(of: copy)))
    }

    func testLintInspectsSwiftModulesBehindVersionedFrameworkLinks() throws {
        let root = try directory()
        let vendor = try binary("Binary", module: "BinarySDK", at: root, swift: true)
        let selection = try NativeLibraryFiles(
            spec: vendor, names: [vendor.name], platform: "osx", root: vendor.directory!)
        let probe = try NativeLintVendorInterface(selection: selection, platform: "osx")
        XCTAssertEqual(probe.swift, "import BinarySDK\n", "A broken Swift interface must reach the lint compiler")
    }

    func testFrameworkMapConversionAcceptsACommentBeforeTheDeclaration() throws {
        let root = try directory()
        let original = try source("Kit", module: "Kit", at: root, map: true)
        let contents = "/* authored */ framework module Kit { header \"Kit.h\" export * }\n"
        try write(contents, "Author.modulemap", at: original.directory!)
        let generated = try engine([original], at: root)
        try generated.generate()
        let effective = try XCTUnwrap(generated.customModuleMaps["Kit:osx"])
        let normalized = try String(contentsOf: effective, encoding: .utf8)
        XCTAssertFalse(normalized.contains("framework module"), "Static library maps must use ordinary modules")
        XCTAssertEqual(
            try String(contentsOf: original.directory!.appendingPathComponent("Author.modulemap"), encoding: .utf8),
            contents)
    }

    func testReinstallHonorsChangedScriptPhaseOrder() throws {
        let root = try directory()
        let graph = try NativePBX(root.appendingPathComponent("project.pbxproj"))
        let compile = graph.add("compile", ["isa": "PBXSourcesBuildPhase", "files": []])
        let target = graph.add("target", ["isa": "PBXNativeTarget", "buildPhases": [compile]])
        let phases = try ["Produce", "Consume"].map {
            try NativeScriptPhase(["name": $0, "script": "true", "execution_position": "before_compile"])
        }
        NativeScriptPhase.apply(phases, target: target, graph: graph)
        NativeScriptPhase.apply(phases.reversed(), target: target, graph: graph)
        let names = (graph.objects[target]?["buildPhases"] as? [String] ?? []).compactMap {
            graph.objects[$0]?["name"] as? String
        }
        XCTAssertEqual(names, ["[CP-User] Consume", "[CP-User] Produce"])
    }

    func testSearchPathOnlyDependenciesParticipateInModuleOwnership() throws {
        let root = try directory()
        let specs = try [
            source("First", module: "Shared", at: root, map: true),
            source("Second", module: "Shared", at: root, map: true),
        ]
        let generated = try engine(specs, at: root, dependencies: [["name": "First"]], search: [["name": "Second"]])
        XCTAssertThrowsError(try generated.generate()) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCODE-MODULE-CONFLICT")
        }
    }
}
