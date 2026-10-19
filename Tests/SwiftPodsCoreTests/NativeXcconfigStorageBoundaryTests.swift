import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeXcconfigStorageBoundaryTests: XCTestCase {
    private func directory(_ suffix: String = "") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + suffix)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func engine(_ root: URL) throws -> NativeXcode {
        try NativeXcode(
            project: root, manifest: ["targets": []], resolution: NativeResolution(specs: [:], requests: []),
            integrateUserProjects: false)
    }

    func testNELInsideXcconfigValueIsData() throws {
        let root = try directory()
        let file = root.appendingPathComponent("Root.xcconfig")
        try Data("VALUE = \"first\u{85}last\"\nTAIL = kept\n".utf8).write(to: file)
        var inputs = Set<String>()
        let settings = try NativeBuildSettings.xcconfig(file, context: [:], inputs: &inputs)
        XCTAssertEqual(settings["VALUE"] as? String, "\"first\u{85}last\"")
        XCTAssertEqual(settings["TAIL"] as? String, "kept")
    }

    func testPodSettingsWithUnicodeLineSeparatorsStayInTheProject() throws {
        for separator in ["\u{2028}", "\u{2029}"] {
            let root = try directory()
            let engine = try engine(root)
            let expected = ["$(inherited)", "first" + separator + "last"]
            let config = engine.graph.add(
                "config",
                ["isa": "XCBuildConfiguration", "name": "Debug", "buildSettings": ["HEADER_SEARCH_PATHS": expected]])
            let list = engine.graph.add("list", ["isa": "XCConfigurationList", "buildConfigurations": [config]])
            let target = engine.graph.add(
                "target", ["isa": "PBXNativeTarget", "name": "Kit", "buildConfigurationList": list])
            engine.targetIDs = [target]
            try engine.podConfigurations()
            let retained = engine.graph.objects[config]?["buildSettings"] as? [String: Any]
            XCTAssertEqual(retained?["HEADER_SEARCH_PATHS"] as? [String], expected)
            let file = root.appendingPathComponent("Pods/Target Support Files/Kit/Kit.debug.xcconfig")
            XCTAssertFalse(
                try String(contentsOf: file, encoding: .utf8).unicodeScalars.contains {
                    $0 == "\u{2028}" || $0 == "\u{2029}"
                })
        }
    }

    func testConsumerProjectStoragePreservesInheritedFlagsAndPodsRoot() throws {
        for separator in ["\u{2028}", "\u{2029}"] {
            let root = try directory(separator + "Project")
            let engine = try engine(root)
            let user = try NativePBX(root.appendingPathComponent("Demo.xcodeproj/project.pbxproj"))
            let original = ["HEADER_SEARCH_PATHS": ["$(inherited)", "UserPath"]]
            let expected = ["$(inherited)", "UserPath", "Lib" + separator + "Path"]
            let config = user.add(
                "config", ["isa": "XCBuildConfiguration", "name": "Debug", "buildSettings": original])
            let settings: [String: Any] = [
                "HEADER_SEARCH_PATHS": expected, "PODS_ROOT": root.appendingPathComponent("Pods").path,
            ]
            let direct = try engine.consumerConfiguration(
                ["name": "Demo"], configuration: config, user: user, recordKey: "Demo", original: original,
                settings: settings)
            XCTAssertEqual(direct["HEADER_SEARCH_PATHS"] as? [String], expected)
            XCTAssertEqual(direct["PODS_ROOT"] as? String, root.appendingPathComponent("Pods").path)
            let file = root.appendingPathComponent("Pods/Target Support Files/Pods-Demo/Pods-Demo.debug.xcconfig")
            XCTAssertFalse(
                try String(contentsOf: file, encoding: .utf8).unicodeScalars.contains {
                    $0 == "\u{2028}" || $0 == "\u{2029}"
                })
        }
    }

    func testDirectXcconfigEmissionRejectsUnrepresentableLineSeparators() throws {
        let engine = try engine(directory())
        for separator in ["\u{2028}", "\u{2029}"] {
            XCTAssertThrowsError(
                try engine.supportConfiguration(
                    label: "Kit", name: "Debug", settings: ["HEADER_SEARCH_PATHS": "first" + separator + "last"])
            ) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCCONFIG-VALUE")
            }
        }
    }

    func testConditionKeysUseProjectStorageWithoutBypassingKeyValidation() throws {
        for separator in ["\u{2028}", "\u{2029}"] {
            let root = try directory()
            let engine = try engine(root)
            let user = try NativePBX(root.appendingPathComponent("Demo.xcodeproj/project.pbxproj"))
            let config = user.add("config", ["isa": "XCBuildConfiguration", "name": "Debug", "buildSettings": [:]])
            let key = "OTHER_CFLAGS[sdk=macosx" + separator + "*]"
            let direct = try engine.consumerConfiguration(
                ["name": "Demo"], configuration: config, user: user, recordKey: "Demo", original: [:],
                settings: [key: "-DKEPT=1"])
            XCTAssertEqual(direct[key] as? String, "-DKEPT=1")
            let file = root.appendingPathComponent("Pods/Target Support Files/Pods-Demo/Pods-Demo.debug.xcconfig")
            let before = try Data(contentsOf: file)
            XCTAssertFalse(
                String(decoding: before, as: UTF8.self).unicodeScalars.contains { $0 == "\u{2028}" || $0 == "\u{2029}" }
            )
            XCTAssertThrowsError(
                try engine.consumerConfiguration(
                    ["name": "Demo"], configuration: config, user: user, recordKey: "Demo", original: [:],
                    settings: ["BAD KEY": "first" + separator + "last"])
            ) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCCONFIG-KEY")
            }
            XCTAssertEqual(try Data(contentsOf: file), before)
        }
    }
}
