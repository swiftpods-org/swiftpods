import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeUnicodePathTests: XCTestCase {
    private func directory(_ names: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for name in names {
            let path = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(name.utf8).write(to: path)
        }
        return root
    }

    func testDirectoryExclusionsCoverDescendantsStartingWithCombiningMarks() throws {
        let root = try directory(["Skip/\u{301}Poison.c", "Skip/\u{301}Nested/Poison.c", "SkipPeer/Keep.c"])
        let excluded: Set<URL> = [root.appendingPathComponent("Skip")]
        for name in ["Skip", "Skip/\u{301}Poison.c", "Skip/\u{301}Nested/Poison.c"] {
            XCTAssertTrue(NativeFileSelection.excluded(root.appendingPathComponent(name), by: excluded), name)
        }
        XCTAssertFalse(NativeFileSelection.excluded(root.appendingPathComponent("SkipPeer/Keep.c"), by: excluded))
    }

    func testDirectorySourceDeclarationsKeepLeadingCombiningMarks() throws {
        let root = try directory(["\u{301}Sources/Keep.c", "\u{301}Sources/Keep.h", "\u{301}Sources/ignored.txt"])
        XCTAssertEqual(
            Set(try NativeFileSelection.files("\u{301}Sources", root: root).map(\.lastPathComponent)),
            ["Keep.c", "Keep.h"])
        XCTAssertEqual(
            try NativeFileSelection.files("\u{301}Sources", root: root, headersOnly: true).map(\.lastPathComponent),
            ["Keep.h"])
    }

    func testDirectorySourceDeclarationsKeepDecomposedAncestorSpelling() throws {
        let root = try directory(["Folderé/\u{301}Sources/Keep.c"])
        let folder = root.appendingPathComponent("Foldere\u{301}")
        XCTAssertEqual(
            try NativeFileSelection.files("\u{301}Sources", root: folder).map(\.lastPathComponent), ["Keep.c"])
    }

    func testMappedHeaderPathsPreserveLeadingCombiningMarksAtEveryBoundary() throws {
        let root = try directory(["Headers/\u{301}Kit.h", "Headers/\u{301}Folder/Kit.h", "HeadersPeer/Kit.h"])
        for name in ["\u{301}Kit.h", "\u{301}Folder/Kit.h"] {
            XCTAssertEqual(
                try NativeFileRules.headerPath(
                    root.appendingPathComponent("Headers/" + name),
                    attributes: ["header_mappings_dir": "Headers"], root: root), name)
        }
        XCTAssertThrowsError(
            try NativeFileRules.headerPath(
                root.appendingPathComponent("HeadersPeer/Kit.h"),
                attributes: ["header_mappings_dir": "Headers"], root: root))
    }

    func testOpaqueResourceDirectoriesSuppressUnicodeDescendantReferences() throws {
        let root = try directory(["Folder/\u{301}payload.txt", "Folder/\u{301}Nested/other.txt", "FolderPeer/keep.txt"])
        let graph = try NativePBX(root.appendingPathComponent("project.pbxproj"))
        let names = [
            "Folder", "Folder/\u{301}payload.txt", "Folder/\u{301}Nested", "Folder/\u{301}Nested/other.txt",
            "FolderPeer/keep.txt",
        ]
        let refs = try NativeResources.references(names.map(root.appendingPathComponent), owner: "Demo", graph: graph)
        XCTAssertEqual(
            Set(try refs.map { try NativeBuildSettings.file($0, graph: graph).path }),
            [root.appendingPathComponent("Folder").path, root.appendingPathComponent("FolderPeer/keep.txt").path])
    }

    func testUnicodeTaggedDirectoryDescendantsReceiveIndependentAliases() throws {
        let root = try directory(["Folder/\u{301}payload.txt"])
        let folder = root.appendingPathComponent("Folder")
        let file = folder.appendingPathComponent("\u{301}payload.txt")
        let tagged = try NativeOnDemandResources(
            attributes: ["on_demand_resources": ["alpha": "Folder/*"]], root: root)
        let plan = try NativeConditionalResources(
            directory: root.appendingPathComponent("Support"),
            normal: ["Debug": [folder], "Release": [folder]],
            configurations: ["Debug": tagged, "Release": NativeOnDemandResources()])
        XCTAssertEqual(plan.paths.count, 2)
        XCTAssertFalse(plan.paths.contains(file))
        let alias = try XCTUnwrap(plan.paths.first { $0 != folder })
        XCTAssertEqual(plan.onDemand.files[alias], ["alpha"])
        XCTAssertEqual(plan.exclusions["Release"], [alias.path])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), file.path)
    }

    func testSourceGroupsPreserveUnicodeDirectoryComponents() throws {
        let root = try directory(["\u{301}Folder/\u{301}Nested/Keep.c"])
        let spec = try NativeSpec(
            data: ["name": "Kit", "version": "1.0", "source_files": "**/*.c"], directory: root, local: true)
        let request = try NativeDependency(["name": "Kit"], platform: "osx", deployment: "13.0")
        let generated = try NativeXcode(
            project: root,
            manifest: [
                "targets": [
                    [
                        "name": "Demo", "platform": ["name": "osx", "deployment_target": "13.0"],
                        "dependencies": [["name": "Kit"]],
                    ]
                ]
            ],
            resolution: NativeResolution(specs: ["Kit": spec], requests: [request]), integrateUserProjects: false)
        try generated.generate()
        let groups = generated.graph.objects.values.filter { $0["isa"] as? String == "PBXGroup" }
        for name in ["\u{301}Folder", "\u{301}Nested"] {
            XCTAssertTrue(groups.contains { $0["path"] as? String == name }, name)
        }
    }

    func testSourceCleanupRetainsUnicodeSourceAncestorsAndRemovesUnusedFiles() throws {
        let root = try directory(["Pod/Folder/\u{301}Keep.c", "Pod/unused.txt"])
        let pod = root.appendingPathComponent("Pod")
        let spec = try NativeSpec(
            data: ["name": "Kit", "version": "1.0", "source_files": "Folder/*.c"], directory: pod)
        let request = try NativeDependency(["name": "Kit"], platform: "osx", deployment: "13.0")
        let sources = try NativeSources(
            project: root, cache: root.appendingPathComponent("cache"), sources: [], dsl: nil,
            offline: true, refreshRepositories: false, hardened: false)
        sources.installationOptions["lock_pod_sources"] = false
        try sources.finalize(["Kit": spec], requests: [request])
        XCTAssertTrue(FileManager.default.fileExists(atPath: pod.appendingPathComponent("Folder/\u{301}Keep.c").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pod.appendingPathComponent("unused.txt").path))
    }

    func testSourceCleanupRetainsUnicodeDescendantsOfPreservedDirectories() throws {
        let root = try directory(["Pod/Assets/\u{301}payload.txt", "Pod/AssetsPeer/unused.txt"])
        let pod = root.appendingPathComponent("Pod")
        let spec = try NativeSpec(
            data: ["name": "Kit", "version": "1.0", "preserve_paths": "Assets"], directory: pod)
        let sources = try NativeSources(
            project: root, cache: root.appendingPathComponent("cache"), sources: [], dsl: nil,
            offline: true, refreshRepositories: false, hardened: false)
        let request = try NativeDependency(["name": "Kit"], platform: "osx", deployment: "13.0")
        try sources.finalize(["Kit": spec], requests: [request])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: pod.appendingPathComponent("Assets/\u{301}payload.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pod.appendingPathComponent("AssetsPeer").path))
    }

    func testContainedSymlinksKeepUnicodeTargetComponents() throws {
        let root = try directory(["\u{301}Payload.txt"])
        let link = root.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "\u{301}Payload.txt")
        XCTAssertTrue(try FileFingerprint.linkIsContained(link, in: root))
    }

    func testRelativeSymlinkTraversalUsesThePhysicalUnicodeParent() throws {
        let root = try directory(["Folder/Payload.txt", "\u{301}Outside.txt"])
        let folder = root.appendingPathComponent("Folder/\u{301}Link")
        try FileManager.default.createSymbolicLink(atPath: folder.path, withDestinationPath: ".")
        let link = root.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: "Folder/\u{301}Link/Payload.txt")
        XCTAssertTrue(try FileFingerprint.linkIsContained(link, in: root))
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.deletingLastPathComponent())
        XCTAssertFalse(try FileFingerprint.linkIsContained(link, in: root))
    }

    func testParentTraversalAfterUnicodeSymlinkStaysInsideItsActualRoot() throws {
        let root = try directory(["Folder/unused.txt", "\u{301}Payload.txt"])
        let nested = root.appendingPathComponent("Folder/\u{301}Link")
        try FileManager.default.createSymbolicLink(atPath: nested.path, withDestinationPath: "..")
        let link = root.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: "Folder/\u{301}Link/\u{301}Payload.txt")
        XCTAssertEqual(
            try Data(contentsOf: link), try Data(contentsOf: root.appendingPathComponent("\u{301}Payload.txt")))
        XCTAssertTrue(try FileFingerprint.linkIsContained(link, in: root))
    }
}
