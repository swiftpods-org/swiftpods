import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeGeneratedConfigurationIdentityTests: XCTestCase {
    private func fixture(label: String = "Pods-Demo", name: String = "Debug-$Cash", encoded: Bool = true) throws
        -> (NativePBX, URL, URL, String)
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let graph = try NativePBX(root.appendingPathComponent("App.xcodeproj/project.pbxproj"))
        let physical = root.appendingPathComponent(
            "Pods/Target Support Files/\(label)/\(label).\(name.lowercased()).xcconfig")
        try FileManager.default.createDirectory(
            at: physical.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = encoded ? NativeBuildSetting.literal(physical.path) : physical.path
        let ref = graph.add(
            "swiftpods:xcconfig:" + path, ["isa": "PBXFileReference", "path": path, "sourceTree": "<absolute>"])
        _ = graph.add(
            "configuration", ["isa": "XCBuildConfiguration", "name": name, "baseConfigurationReference": ref])
        return (graph, root, physical, ref)
    }

    func testMissingConfigurationCannotBorrowANeighborsDoubleDollarFilename() throws {
        let (graph, root, physical, ref) = try fixture()
        let neighbor = physical.deletingLastPathComponent().appendingPathComponent("Pods-Demo.debug-$$cash.xcconfig")
        try Data("SWIFT_VERSION = 99.0\n".utf8).write(to: neighbor)
        try NativeIntegrationLocation.relocateGeneratedConfigurations(graph, from: root, to: root)
        XCTAssertEqual(try NativeBuildSettings.file(ref, graph: graph).path, physical.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: physical.path))
        XCTAssertEqual(try String(contentsOf: neighbor, encoding: .utf8), "SWIFT_VERSION = 99.0\n")
    }

    private func portable(_ graph: NativePBX, physical: URL, ref: String, encoded: Bool) throws -> String {
        let relative = NativePath.relativePath(of: physical, to: graph.sourceRoot)
        let path = encoded ? NativeBuildSetting.literal(relative) : relative
        let replacement = graph.add(
            "swiftpods:xcconfig:" + path,
            ["isa": "PBXFileReference", "path": path, "sourceTree": "SOURCE_ROOT"])
        for id in graph.objects.keys where graph.objects[id]?["baseConfigurationReference"] as? String == ref {
            graph.objects[id]?["baseConfigurationReference"] = replacement
        }
        graph.objects.removeValue(forKey: ref)
        return replacement
    }

    func testPortableMissingConfigurationsRelocateUsingTheProjectRoot() throws {
        let (graph, root, physical, ref) = try fixture()
        let portable = try portable(graph, physical: physical, ref: ref, encoded: true)
        let destination = root.appendingPathComponent("Moved")
        let neighbor = physical.deletingLastPathComponent().appendingPathComponent("Pods-Demo.debug-$$cash.xcconfig")
        try Data("SWIFT_VERSION = 99.0\n".utf8).write(to: neighbor)
        try NativeIntegrationLocation.relocateGeneratedConfigurations(graph, from: root, to: destination)
        let relative = NativePath.relativePath(of: physical, to: root)
        let expected = destination.appendingPathComponent(relative)
        XCTAssertEqual(try NativeBuildSettings.file(portable, graph: graph).path, expected.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expected.path))
        XCTAssertEqual(try String(contentsOf: neighbor, encoding: .utf8), "SWIFT_VERSION = 99.0\n")
    }

    func testPortableRawLegacyReferencesUseTheGeneratedProjectsPhysicalIdentity() throws {
        let (graph, root, physical, ref) = try fixture(name: "Debug-$$Cash", encoded: false)
        let portable = try portable(graph, physical: physical, ref: ref, encoded: false)
        let pods = try NativePBX(root.appendingPathComponent("Pods/Pods.xcodeproj/project.pbxproj"))
        _ = pods.add(
            "file:" + physical.path,
            ["isa": "PBXFileReference", "path": physical.path, "sourceTree": "<absolute>"])
        try pods.save()
        let neighbor = physical.deletingLastPathComponent().appendingPathComponent("Pods-Demo.debug-$cash.xcconfig")
        try Data("SWIFT_VERSION = 99.0\n".utf8).write(to: neighbor)
        try NativeIntegrationLocation.relocateGeneratedConfigurations(graph, from: root, to: root)
        XCTAssertEqual(try NativeBuildSettings.file(portable, graph: graph).path, physical.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: physical.path))
        XCTAssertEqual(try String(contentsOf: neighbor, encoding: .utf8), "SWIFT_VERSION = 99.0\n")
    }

    func testRawLegacyConfigurationUsesItsDeclaredNameWhenBothSpellingsExist() throws {
        let (graph, root, physical, ref) = try fixture(name: "Debug-$$Cash", encoded: false)
        try Data().write(to: physical)
        try Data().write(
            to: physical.deletingLastPathComponent().appendingPathComponent("Pods-Demo.debug-$cash.xcconfig"))
        try NativeIntegrationLocation.relocateGeneratedConfigurations(graph, from: root, to: root)
        XCTAssertEqual(try NativeBuildSettings.file(ref, graph: graph).path, physical.path)
    }

    func testGeneratedProjectIdentityDisambiguatesALiteralDollarLabelWithoutItsFile() throws {
        for randomID in [false, true] {
            let (graph, root, physical, ref) = try fixture(label: "Pods-Demo-$Cash", name: "Debug")
            let pods = try NativePBX(root.appendingPathComponent("Pods/Pods.xcodeproj/project.pbxproj"))
            pods.randomIdentifiers = randomID
            let expression = try XCTUnwrap(graph.objects[ref]?["path"] as? String)
            let counterpart = pods.add(
                "file:" + physical.path, ["isa": "PBXFileReference", "path": expression, "sourceTree": "<absolute>"])
            let config = pods.add(
                "debug", ["isa": "XCBuildConfiguration", "name": "Debug", "baseConfigurationReference": counterpart])
            let list = pods.add("list", ["isa": "XCConfigurationList", "buildConfigurations": [config]])
            _ = pods.add(
                "aggregate", ["isa": "PBXAggregateTarget", "name": "Pods-Demo-$Cash", "buildConfigurationList": list])
            try pods.save()
            let decoy = URL(fileURLWithPath: expression)
            try FileManager.default.createDirectory(
                at: decoy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: decoy)
            try NativeIntegrationLocation.relocateGeneratedConfigurations(graph, from: root, to: root)
            XCTAssertEqual(try NativeBuildSettings.file(ref, graph: graph).path, physical.path)
        }
    }

    func testReceiptEncodingIsAuthoritativeWhenGeneratedProjectAndBaseAreMissing() throws {
        let (graph, root, physical, ref) = try fixture(label: "Pods-Demo-$Cash", name: "Debug")
        let expression = try XCTUnwrap(graph.objects[ref]?["path"] as? String)
        let decoy = URL(fileURLWithPath: expression)
        try FileManager.default.createDirectory(
            at: decoy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: decoy)
        try jsonData(["_configuration_path_encoding": 1]).write(
            to: root.appendingPathComponent("Pods/Target Support Files/SwiftPods-Integration.json"))
        try NativeIntegrationLocation.relocateGeneratedConfigurations(graph, from: root, to: root)
        XCTAssertEqual(try NativeBuildSettings.file(ref, graph: graph).path, physical.path)
    }

    func testUnprovenLegacyLabelUsesPBXEncodingAndPreservesAnUnrelatedFile() throws {
        let (graph, root, _, ref) = try fixture(label: "Pods-Custom-$Cash", name: "Debug")
        let expression = try XCTUnwrap(graph.objects[ref]?["path"] as? String)
        let before = graph.objects[ref]?["path"] as? String
        let decoy = URL(fileURLWithPath: expression)
        try FileManager.default.createDirectory(
            at: decoy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("unrelated".utf8).write(to: decoy)
        try NativeIntegrationLocation.relocateGeneratedConfigurations(graph, from: root, to: root)
        XCTAssertEqual(graph.objects[ref]?["path"] as? String, before)
        XCTAssertEqual(try String(contentsOf: decoy, encoding: .utf8), "unrelated")
    }
    func testUnsupportedReceiptEncodingsFailBeforeChangingReferences() throws {
        for version: Any in [2, true, "1"] {
            let (graph, root, _, ref) = try fixture()
            let before = graph.objects[ref]?["path"] as? String
            try jsonData(["_configuration_path_encoding": version]).write(
                to: root.appendingPathComponent("Pods/Target Support Files/SwiftPods-Integration.json"))
            XCTAssertThrowsError(
                try NativeIntegrationLocation.relocateGeneratedConfigurations(graph, from: root, to: root)
            ) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-INTEGRATION-LOCATION")
            }
            XCTAssertEqual(graph.objects[ref]?["path"] as? String, before)
        }
    }

}
