import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeGeneratedLiteralPathTests: XCTestCase {
    private func engine(_ additions: [String: Any] = [:], suffix: String = "Root-$(SDKROOT)-$TEXT") throws
        -> NativeXcode
    {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = parent.appendingPathComponent(suffix)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        var data: [String: Any] = ["name": "Kit", "version": "1.0", "source_files": "*.{c,h}"]
        data.merge(additions) { _, value in value }
        try Data("int kit(void) { return 7; }\n".utf8).write(to: root.appendingPathComponent("Source-$(SDKROOT).c"))
        try Data().write(to: root.appendingPathComponent("Kit.h"))
        let spec = try NativeSpec(data: data, directory: root)
        let requests = try NativeDependency(["name": "Kit"], platform: "osx", deployment: "13.0").expandedSelections()
        let resolution = try NativeResolver(candidates: { _ in [spec] }).resolve(requests)
        return try NativeXcode(
            project: root,
            manifest: [
                "targets": [
                    [
                        "name": "Demo", "platform": ["name": "osx", "deployment_target": "13.0"],
                        "dependencies": [["name": "Kit"]],
                    ]
                ]
            ],
            resolution: resolution, integrateUserProjects: false)
    }

    func testGeneratedSourceReferencesResolveToLiteralFilesystemPaths() throws {
        let engine = try engine()
        let source = engine.project.appendingPathComponent("Source-$(SDKROOT).c")
        let ref = engine.file(source.path)
        XCTAssertEqual(try NativeBuildSettings.file(ref, graph: engine.graph).path, source.path)
    }

    func testGeneratedResourcesKeepLiteralMacroText() throws {
        let engine = try engine()
        let resource = engine.project.appendingPathComponent("Resource-$(SDKROOT).txt")
        try Data().write(to: resource)
        let references = try NativeResources.references([resource], owner: "Kit", graph: engine.graph)
        XCTAssertEqual(
            try NativeBuildSettings.file(XCTUnwrap(references.first), graph: engine.graph).path, resource.path)
    }

    func testOnDemandTagsUseThePhysicalPathBehindGeneratedReferences() throws {
        let engine = try engine()
        let resource = engine.project.appendingPathComponent("Tagged-$(SDKROOT).txt")
        try Data().write(to: resource)
        let references = try NativeResources.references([resource], owner: "Kit", graph: engine.graph)
        let reference = try XCTUnwrap(references.first)
        XCTAssertEqual(try NativeBuildSettings.file(reference, graph: engine.graph).path, resource.path)
        let build = engine.buildFile(reference, target: "Kit")
        let phase = engine.phase("PBXResourcesBuildPhase", target: "Kit", files: [build])
        let target = engine.graph.add("test-target", ["isa": "PBXNativeTarget", "buildPhases": [phase]])
        var resources = NativeOnDemandResources()
        resources.files[resource] = ["download"]
        resources.tag(target: target, graph: engine.graph)
        XCTAssertEqual(
            (engine.graph.objects[build]?["settings"] as? [String: Any])?["ASSET_TAGS"] as? [String], ["download"])
    }

    func testLibrarySettingsAndGeneratedBaseConfigurationsKeepLiteralRoots() throws {
        let engine = try engine(["pod_target_xcconfig": ["CUSTOM_EXPRESSION": "$(SDKROOT)"]])
        try engine.generate()
        var count = 0
        for object in engine.graph.objects.values where object["isa"] as? String == "XCBuildConfiguration" {
            guard let values = object["buildSettings"] as? [String: Any], values["PODS_TARGET_SRCROOT"] != nil else {
                continue
            }
            count += 1
            let settings = try NativeBuildSettings.resolved(object, graph: engine.graph)
            XCTAssertEqual(
                try NativeBuildSettings.expandedValue("PODS_TARGET_SRCROOT", settings: settings), engine.project.path)
            XCTAssertEqual(
                try NativeBuildSettings.expandedValue("PODS_ROOT", settings: settings),
                engine.project.appendingPathComponent("Pods").path)
            XCTAssertEqual(
                try NativeBuildSettings.expandedValue("PODS_PODFILE_DIR_PATH", settings: settings), engine.project.path)
            XCTAssertEqual(try NativeBuildSettings.expandedValue("CUSTOM_EXPRESSION", settings: settings), "macosx")
            let base = try XCTUnwrap(object["baseConfigurationReference"] as? String)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: try NativeBuildSettings.file(base, graph: engine.graph).path))
        }
        XCTAssertEqual(count, 2)
    }

    func testGeneratedHeaderSearchPathsExpandToExistingDirectories() throws {
        let engine = try engine()
        try engine.generate()
        for object in engine.graph.objects.values where object["isa"] as? String == "XCBuildConfiguration" {
            let values = try NativeBuildSettings.resolved(object, graph: engine.graph)
            for raw in nativeStrings(values["HEADER_SEARCH_PATHS"]) where raw.hasPrefix("/") {
                let expanded = try XCTUnwrap(NativeBuildSettings.expandedValue("PATH", settings: ["PATH": raw]))
                XCTAssertTrue(FileManager.default.fileExists(atPath: expanded), expanded)
            }
        }
    }

    func testConsumerReferencesRetainTheirOwnershipAndLiteralPath() throws {
        let engine = try engine()
        let user = try NativePBX(engine.project.appendingPathComponent("Demo.xcodeproj/project.pbxproj"))
        let configuration = user.add("debug", ["isa": "XCBuildConfiguration", "name": "Debug", "buildSettings": [:]])
        _ = try engine.consumerConfiguration(
            ["name": "Demo"], configuration: configuration, user: user, recordKey: "record", original: [:],
            settings: [:])
        let reference = try XCTUnwrap(user.objects[configuration]?["baseConfigurationReference"] as? String)
        let path = try XCTUnwrap(user.objects[reference]?["path"] as? String)
        XCTAssertEqual(reference, NativePBX.identifier("swiftpods:xcconfig:" + path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try NativeBuildSettings.file(reference, graph: user).path))
    }

    func testRelocationDecodesOwnedExpressionsBeforeResolvingTheirLocation() throws {
        let engine = try engine()
        let old = engine.project.appendingPathComponent("Previous-$(SDKROOT)")
        let location = "Pods/Target Support Files/Pods-Demo/Pods-Demo.debug.xcconfig"
        let raw = old.appendingPathComponent(location).path.replacingOccurrences(of: "$", with: "$$")
        let reference = engine.graph.add(
            "swiftpods:xcconfig:" + raw, ["isa": "PBXFileReference", "path": raw, "sourceTree": "<absolute>"])
        try NativeIntegrationLocation.relocateGeneratedConfigurations(engine.graph, from: old, to: engine.project)
        XCTAssertEqual(
            try NativeBuildSettings.file(reference, graph: engine.graph).path,
            engine.project.appendingPathComponent(location).path)
    }
    func testLegacyRawDollarRootsAreNotDecodedTwice() throws {
        let engine = try engine()
        let old = engine.project.appendingPathComponent("Previous-$$Money")
        let location = "Pods/Target Support Files/Pods-Demo/Pods-Demo.debug.xcconfig"
        let raw = old.appendingPathComponent(location).path
        let reference = engine.graph.add(
            "swiftpods:xcconfig:" + raw, ["isa": "PBXFileReference", "path": raw, "sourceTree": "<absolute>"])
        try NativeIntegrationLocation.relocateGeneratedConfigurations(engine.graph, from: old, to: engine.project)
        XCTAssertEqual(
            try NativeBuildSettings.file(reference, graph: engine.graph).path,
            engine.project.appendingPathComponent(location).path)
    }

    func testLegacyDollarConfigurationFilenameUsesItsConfigurationName() throws {
        let engine = try engine()
        let old = engine.project.appendingPathComponent("Previous")
        let location = "Pods/Target Support Files/Pods-Demo/Pods-Demo.debug-$$cash.xcconfig"
        let file = old.appendingPathComponent(location)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: file)
        let reference = engine.graph.add(
            "swiftpods:xcconfig:" + file.path,
            ["isa": "PBXFileReference", "path": file.path, "sourceTree": "<absolute>"])
        _ = engine.graph.add(
            "legacy-config",
            ["isa": "XCBuildConfiguration", "name": "Debug-$$Cash", "baseConfigurationReference": reference])
        try NativeIntegrationLocation.relocateGeneratedConfigurations(engine.graph, from: old, to: engine.project)
        XCTAssertEqual(
            try NativeBuildSettings.file(reference, graph: engine.graph).path,
            engine.project.appendingPathComponent(location).path)
    }

    func testGeneratedScalarPathsPreserveEscapedDollarsAndBackslashPairs() throws {
        for suffix in [#"Root-\$(SDKROOT)"#, #"Root-\\$(SDKROOT)"#, #"Root-\\\$NAME"#] {
            let engine = try engine(suffix: suffix)
            try engine.generate()
            for object in engine.graph.objects.values where object["isa"] as? String == "XCBuildConfiguration" {
                let settings = object["buildSettings"] as? [String: Any] ?? [:]
                guard settings["PODS_TARGET_SRCROOT"] != nil else { continue }
                let scope = NativeBuildSettingScope(settings)
                XCTAssertEqual(try scope.expandedValue("PODS_ROOT"), engine.project.appendingPathComponent("Pods").path)
                XCTAssertEqual(try scope.expandedValue("PODS_PODFILE_DIR_PATH"), engine.project.path)
                XCTAssertEqual(try scope.expandedValue("PODS_TARGET_SRCROOT"), engine.project.path)
            }
        }
    }

    func testHeaderLookupsUseStringFormWhenTheRootContainsBackslashes() throws {
        let engine = try engine(suffix: #"Root-\$(SDKROOT)"#)
        let paths = engine.headerSettings(["Kit"], platform: "osx")
        XCTAssertEqual(paths.count, 1)
        XCTAssertTrue(try XCTUnwrap(paths.first).hasPrefix(#""$(PODS_ROOT)/Headers/Public/"#))
        XCTAssertTrue(try XCTUnwrap(paths.first).hasSuffix("\""))
    }

}
