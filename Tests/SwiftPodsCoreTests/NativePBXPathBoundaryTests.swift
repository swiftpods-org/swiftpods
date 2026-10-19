import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativePBXPathBoundaryTests: XCTestCase {
    private let projectID = "A00000000000000000000001"
    private let groupID = "A00000000000000000000002"
    private let fileID = "A00000000000000000000003"

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func graph() throws -> NativePBX {
        let graph = try NativePBX(directory().appendingPathComponent("App.xcodeproj/project.pbxproj"))
        graph.root = ["rootObject": projectID]
        graph.objects = [
            projectID: ["isa": "PBXProject", "mainGroup": groupID, "projectDirPath": "", "targets": []],
            groupID: ["isa": "PBXGroup", "path": "Configs", "sourceTree": "<group>", "children": [fileID]],
            fileID: ["isa": "PBXFileReference", "path": "Base.xcconfig", "sourceTree": "<group>"],
        ]
        return graph
    }

    private func reject(_ operation: () throws -> Any, code: String = "SP-XCODE-PATH") {
        XCTAssertThrowsError(try operation()) { XCTAssertEqual(($0 as? Diagnostic)?.code, code) }
    }

    func testExistingProjectsRejectNULPathFieldsWithoutRewriting() throws {
        for (object, key) in [
            (projectID, "projectDirPath"), (projectID, "projectRoot"), (groupID, "path"), (fileID, "path"),
        ] {
            let graph = try graph()
            graph.objects[object]?[key] = "Before\0After"
            var value = graph.root
            value["objects"] = graph.objects
            let bytes = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
            try FileManager.default.createDirectory(
                at: graph.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: graph.url)
            reject { try NativePBX(graph.url, existing: true) }
            XCTAssertEqual(try Data(contentsOf: graph.url), bytes)
        }
    }

    func testSaveRejectsNULBeforeCreatingProjectFiles() throws {
        let graph = try graph()
        graph.objects[fileID]?["path"] = "Before\0After"
        reject { try graph.save() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: graph.url.deletingLastPathComponent().path))
    }

    func testInvalidMutationCannotOverwriteAnExistingProject() throws {
        let graph = try graph()
        try graph.save()
        let bytes = try Data(contentsOf: graph.url)
        graph.objects[groupID]?["path"] = "Before\0After"
        reject { try graph.save() }
        XCTAssertEqual(try Data(contentsOf: graph.url), bytes)
    }

    func testBuildSettingsRejectMutatedRootGroupAndFilePaths() throws {
        for (object, key) in [
            (projectID, "projectDirPath"), (projectID, "projectRoot"), (groupID, "path"), (fileID, "path"),
        ] {
            let graph = try graph()
            graph.objects[object]?[key] = "Before\0After"
            reject { try NativeBuildSettings.file(fileID, graph: graph) }
        }
    }

    func testHookGraphsRejectNULBeforeApplyingOrSaving() throws {
        let graph = try graph()
        graph.objects[fileID]?["path"] = "Before\0After"
        var value = graph.root
        value["objects"] = graph.objects
        reject { try NativeHookGraph.parse(["path": graph.url.deletingLastPathComponent().path, "graph": value]) }
    }

    func testLiteralPercentAndUnicodePathsKeepTheirExactMeaning() throws {
        let graph = try graph()
        graph.objects[projectID]?["projectDirPath"] = "Sources%00Ignored"
        graph.objects[groupID]?["path"] = "\u{301}Configs東京"
        graph.objects[fileID]?["path"] = "Base%00Ignored.xcconfig"
        try graph.save()
        let loaded = try NativePBX(graph.url, existing: true)
        let expected = graph.url.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources%00Ignored/\u{301}Configs東京/Base%00Ignored.xcconfig")
        XCTAssertEqual(try NativeBuildSettings.file(fileID, graph: loaded), expected)
        XCTAssertEqual(loaded.objects[groupID]?["path"] as? String, "\u{301}Configs東京")
    }

    private func inventoryFile(_ relative: String, root: URL) throws -> URL {
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("preserved".utf8).write(to: file)
        return file
    }

    func testInventoryLoadRejectsNULBeforeInterpretingReceiptPaths() throws {
        let root = try directory()
        let file = try inventoryFile("Old%00Ignored.xcodeproj/project.pbxproj", root: root)
        let receipt = root.appendingPathComponent("inventory.json")
        let bytes = try jsonData([
            "schema_version": 1, "files": ["Old\0Ignored.xcodeproj/project.pbxproj": try FileFingerprint.file(file)],
            "products": [],
        ])
        try bytes.write(to: receipt)
        reject({ try NativeProjectInventory.load(receipt, root: root) }, code: "SP-XCODE-INVENTORY")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "preserved")
        XCTAssertEqual(try Data(contentsOf: receipt), bytes)
    }

    func testInventoryCleanupCannotDeleteLiteralPercentAliases() throws {
        for (relative, invalid) in [
            ("Old%00Ignored.xcodeproj/project.pbxproj", "Old\0Ignored.xcodeproj/project.pbxproj"),
            (
                "Old.xcodeproj/xcshareddata/xcschemes/Old%00Ignored.xcscheme",
                "Old.xcodeproj/xcshareddata/xcschemes/Old\0Ignored.xcscheme"
            ),
        ] {
            let root = try directory()
            let file = try inventoryFile(relative, root: root)
            let hash = try FileFingerprint.file(file)
            reject(
                { try NativeProjectInventory.clean(previous: [invalid: hash], current: [], root: root) },
                code: "SP-XCODE-INVENTORY")
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testValidPercentAndUnicodeInventoryEntriesStillCleanOwnedFiles() throws {
        let root = try directory()
        var previous: [String: String] = [:]
        for relative in [
            "Old%00Ignored.xcodeproj/project.pbxproj",
            "\u{301}Old東京.xcodeproj/xcshareddata/xcschemes/\u{301}Run%00.xcscheme",
        ] {
            let file = try inventoryFile(relative, root: root)
            XCTAssertEqual(try NativeProjectInventory.path(relative, root: root), file)
            previous[relative] = try FileFingerprint.file(file)
        }
        try NativeProjectInventory.clean(previous: previous, current: [], root: root)
        for relative in previous.keys {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path))
        }
    }
}
