import Darwin
import Foundation
import SwiftPodsTestSupport
@testable import SwiftPodsXcode
import XCTest

final class XcodeProjectTests: XCTestCase {
    private func load() throws -> XcodeProject {
        try XcodeProject(path: URL(fileURLWithPath: "/project/App.xcodeproj"), text: Fixtures.project)
    }

    func testReadsTargetsAndConfigurations() throws {
        let project = try load()
        XCTAssertEqual(project.nativeTargets.map(\.name), ["App", "Plugin", "AppTests"])
        XCTAssertEqual(project.nativeTargets[1].productType, "com.apple.product-type.library.static")
        XCTAssertEqual(project.configurations(of: project.nativeTargets[0].id).keys.sorted(), ["Debug", "Release"])
        XCTAssertFalse(project.hasChanges)
        XCTAssertEqual(project.serialized(), Fixtures.project)
    }

    func testSourceRootUsesProjectDirectoryWhenProjectDirPathIsEmpty() throws {
        let project = try load()
        XCTAssertEqual(project.sourceRoot.path, "/project")
    }

    func testSourceRootResolvesRelativeProjectDirPathFromProjectDirectory() throws {
        let source = Fixtures.project.replacingOccurrences(
            of: "projectDirPath = \"\";", with: "projectDirPath = ../../Sources/App;")
        let project = try XcodeProject(path: URL(fileURLWithPath: "/build/generated/App.xcodeproj"), text: source)

        XCTAssertEqual(project.sourceRoot.path, "/Sources/App")
    }

    func testSourceRootUsesAbsoluteProjectDirPath() throws {
        let source = Fixtures.project.replacingOccurrences(
            of: "projectDirPath = \"\";", with: "projectDirPath = /workspace/Sources/App;")
        let project = try XcodeProject(path: URL(fileURLWithPath: "/build/generated/App.xcodeproj"), text: source)

        XCTAssertEqual(project.sourceRoot.path, "/workspace/Sources/App")
    }

    func testEditsRewriteOnlyChangedRecords() throws {
        var project = try load()
        let app = project.nativeTargets[0].id
        let reference = project.put(
            "test:package",
            ["isa": "XCRemoteSwiftPackageReference", "repositoryURL": "https://github.com/a/Kit.git",
             "requirement": ["kind": "exactVersion", "version": "1.0.0"]])
        project.append(reference, to: "packageReferences", of: project.rootID)
        let product = project.put("test:product", ["isa": "XCSwiftPackageProductDependency", "package": .string(reference), "productName": "Kit"])
        project.append(product, to: "packageProductDependencies", of: app)

        let text = project.serialized()
        let reloaded = try XcodeProject(path: project.path, text: text)
        XCTAssertEqual(reloaded.objects, project.objects)
        XCTAssertTrue(text.contains("/* Begin XCRemoteSwiftPackageReference section */"))
        XCTAssertTrue(text.contains("repositoryURL = \"https://github.com/a/Kit.git\";"))

        let removedOriginal = Set(Fixtures.project.split(separator: "\n")).subtracting(text.split(separator: "\n"))
        XCTAssertEqual(removedOriginal, [], "Additions must not rewrite existing lines")

        project.remove(product)
        project.remove(reference)
        XCTAssertEqual(project.objects[app]?.strings("packageProductDependencies"), [])
        XCTAssertNil(project.objects[reference])
    }

    func testLargeArrayUpdatePreservesOriginalEntriesInLinearPass() throws {
        let values = (0..<10_000).map { "Region\($0)" }
        let original = "\t\t\tknownRegions = (\n" + values.map { "\t\t\t\t\($0),\n" }.joined() + "\t\t\t);"
        let source = Fixtures.project.replacingOccurrences(
            of: "\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);", with: original)
        var project = try XcodeProject(path: URL(fileURLWithPath: "/project/App.xcodeproj"), text: source)
        var root = project.project
        root["knownRegions"] = .array((values + ["Added"]).map(PBXValue.string))
        project.project = root

        let serialized = project.serialized()
        XCTAssertTrue(serialized.contains("\t\t\t\tRegion9999,"))
        XCTAssertTrue(serialized.contains("\t\t\t\tAdded,"))
        XCTAssertEqual(
            try XcodeProject(path: project.path, text: serialized).project.strings("knownRegions"), values + ["Added"])
    }

    func testLargeObjectAdditionsReuseIndexedSectionsAndCachedNewlines() throws {
        let existingIDs = (1...8_000).map { String(format: "%024X", $0) }
        let existing = existingIDs.enumerated().map { index, id in
            "\t\t\(id) /* preserve \(index) */ = {isa = PBXFileReference; path = \"File \(index)\"; sourceTree = \"<group>\"; };\r\n"
        }.joined()
        let source = "{\r\n\tobjects = {\r\n" + existing + "\t};\r\n}\r\n"
        let document = try PBXDocument(source)
        var root = try XCTUnwrap(document.value.dictionary)
        var objects = try XCTUnwrap(root["objects"]?.dictionary)
        let addedIDs = (0..<2_000).map { String(format: "F%023X", $0) }
        for (index, id) in addedIDs.enumerated() {
            objects[id] = ["isa": "PBXBuildRule", "name": .string("Rule \(index)")]
        }
        root["objects"] = .dictionary(objects)

        let serialized = document.updating(.dictionary(root))

        XCTAssertTrue(serialized.contains(existing.components(separatedBy: "\r\n")[0] + "\r\n"))
        XCTAssertEqual(serialized.components(separatedBy: "/* Begin PBXBuildRule section */").count - 1, 1)
        let firstAddedID = try XCTUnwrap(addedIDs.first)
        let lastAddedID = try XCTUnwrap(addedIDs.last)
        XCTAssertLessThan(
            try XCTUnwrap(serialized.range(of: firstAddedID)).lowerBound,
            try XCTUnwrap(serialized.range(of: lastAddedID)).lowerBound)
        XCTAssertFalse(serialized.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        XCTAssertEqual(try PBXDocument(serialized).value, .dictionary(root))
    }

    func testClassMovesDoNotReuseInsertionRangesScheduledForRemoval() throws {
        let source = "{\n\tobjects = {\n"
            + "\t\tAAAAAAAAAAAAAAAAAAAAAAAA = { isa = PBXGroup; name = Group; };\n"
            + "\t\tBBBBBBBBBBBBBBBBBBBBBBBB = { isa = PBXFileReference; path = File; };\n"
            + "\t};\n}\n"
        let document = try PBXDocument(source)
        var root = try XCTUnwrap(document.value.dictionary)
        var objects = try XCTUnwrap(root["objects"]?.dictionary)
        objects["AAAAAAAAAAAAAAAAAAAAAAAA"] = ["isa": "PBXFileReference", "path": "MovedFile"]
        objects["BBBBBBBBBBBBBBBBBBBBBBBB"] = ["isa": "PBXGroup", "name": "MovedGroup"]
        root["objects"] = .dictionary(objects)

        let serialized = document.updating(.dictionary(root))

        XCTAssertTrue(serialized.contains("/* Begin PBXFileReference section */"))
        XCTAssertTrue(serialized.contains("/* Begin PBXGroup section */"))
        XCTAssertEqual(try PBXDocument(serialized).value, .dictionary(root))
    }

    func testBulkRemovalDropsAllReferencesInOnePass() throws {
        var project = try load()
        let first = project.put("test:bulk-first", ["isa": "PBXGroup", "children": [], "sourceTree": "<group>"])
        let second = project.put("test:bulk-second", ["isa": "PBXGroup", "children": [], "sourceTree": "<group>"])
        let main = try XCTUnwrap(project.project.string("mainGroup"))
        project.append(first, to: "children", of: main)
        project.append(second, to: "children", of: main)

        project.remove(Set([first, second]))

        XCTAssertNil(project[first])
        XCTAssertNil(project[second])
        XCTAssertFalse(project[main]!.strings("children").contains(first))
        XCTAssertFalse(project[main]!.strings("children").contains(second))
    }

    func testRemovalTakesDependentObjectsAndSingleReferencesWithIt() throws {
        var project = try load()
        let main = try XCTUnwrap(project.project.string("mainGroup"))
        let subproject = "B00000000000000000000001"
        let proxy = "B00000000000000000000002"
        let library = "B00000000000000000000003"
        let file = "B00000000000000000000004"
        let products = "B00000000000000000000005"
        let settings = "B00000000000000000000006"
        project[subproject] = ["isa": "PBXFileReference", "path": "Sub.xcodeproj", "sourceTree": "<group>"]
        project[proxy] = ["isa": "PBXContainerItemProxy", "containerPortal": .string(subproject), "proxyType": "2",
                          "remoteGlobalIDString": "D00000000000000000000001", "remoteInfo": "Sub"]
        project[library] = ["isa": "PBXReferenceProxy", "path": "libSub.a", "remoteRef": .string(proxy), "sourceTree": "BUILT_PRODUCTS_DIR"]
        project[file] = ["isa": "PBXBuildFile", "fileRef": .string(library)]
        project[products] = ["isa": "PBXGroup", "children": [.string(library)], "sourceTree": "<group>"]
        project[settings] = ["isa": "PBXFileReference", "path": "App.xcconfig", "sourceTree": "<group>"]
        project.append(file, to: "files", of: "A30000000000000000000001")
        project.append(subproject, to: "children", of: main)
        project.project["projectReferences"] = [["ProductGroup": .string(products), "ProjectRef": .string(subproject)]]
        project["A80000000000000000000003"]!["baseConfigurationReference"] = .string(settings)

        project.remove(Set([subproject, settings]))

        for id in [subproject, proxy, library, file, settings] { XCTAssertNil(project[id], id) }
        XCTAssertNotNil(project[products], "A group is not dependent; only its entries are removed")
        XCTAssertEqual(project[products]?.strings("children"), [])
        XCTAssertEqual(project["A30000000000000000000001"]?.strings("files"), [])
        XCTAssertEqual(project.project["projectReferences"], [])
        XCTAssertNil(project["A80000000000000000000003"]?["baseConfigurationReference"])
    }

    func testUnquotedDoubleSlashIsPartOfAStringAsInFoundation() throws {
        let text = Fixtures.project.replacingOccurrences(
            of: "\t\t\tknownRegions = (\n\t\t\t\ten,\n", with: "\t\t\tknownRegions = (\n\t\t\t\ten//x,\n")
        XCTAssertNotEqual(text, Fixtures.project)
        var project = try XcodeProject(path: URL(fileURLWithPath: "/tmp/App.xcodeproj"), text: text)
        XCTAssertEqual(project.project.strings("knownRegions"), ["en//x", "Base"])

        project.project["knownRegions"] = ["en//x", "Base", "fr"]
        let serialized = project.serialized()
        XCTAssertEqual(try XcodeProject(path: project.path, text: serialized).project.strings("knownRegions"), ["en//x", "Base", "fr"])
        let foundation = try PropertyListSerialization.propertyList(from: Data(serialized.utf8), format: nil) as? [String: Any]
        let objects = foundation?["objects"] as? [String: [String: Any]]
        XCTAssertEqual(objects?["A00000000000000000000001"]?["knownRegions"] as? [String], ["en//x", "Base", "fr"])
    }

    func testIdentifiersAreStableAndXcodeShaped() {
        let id = XcodeProject.identifier("package:github.com/a/kit")
        XCTAssertEqual(id, XcodeProject.identifier("package:github.com/a/kit"))
        XCTAssertNotEqual(id, XcodeProject.identifier("package:github.com/a/other"))
        XCTAssertNotNil(id.range(of: #"\A[0-9A-F]{24}\z"#, options: .regularExpression))
    }

    func testGeneratedScalarsEscapeAllControlCharacters() throws {
        var project = try load()
        let id = project.put(
            "test:controls", ["isa": "PBXGroup", "children": [], "name": .string("a\0b\u{c}c\u{7f}d"), "sourceTree": "<group>"])
        project.append(id, to: "children", of: project.project.string("mainGroup")!)
        let serialized = project.serialized()
        XCTAssertFalse(serialized.contains("\0"))
        XCTAssertFalse(serialized.contains("\u{c}"))
        XCTAssertTrue(serialized.contains("\\U0000"), serialized)
        XCTAssertTrue(serialized.contains("\\U000C"), serialized)
        XCTAssertEqual(try XcodeProject(path: project.path, text: serialized).objects, project.objects)
    }

    func testRejectsInvalidProjects() {
        XCTAssertThrowsError(try XcodeProject(path: URL(fileURLWithPath: "/p.xcodeproj"), text: "{ objects = {}; }"))
        XCTAssertThrowsError(try XcodeProject(path: URL(fileURLWithPath: "/p.xcodeproj"), text: "{ objects = { "))
    }

    func testRejectsDuplicateAndDifferentlyDecodedDictionaryKeys() {
        let duplicate = Fixtures.project.replacingOccurrences(
            of: "\tobjects = {", with: "\tobjects = {};\n\tobjects = {", options: [],
            range: Fixtures.project.range(of: "\tobjects = {")!)
        XCTAssertThrowsError(try XcodeProject(path: URL(fileURLWithPath: "/p.xcodeproj"), text: duplicate))

        let escaped = Fixtures.project.replacingOccurrences(
            of: "\tobjects = {", with: "\t\"\\U006Fbjects\" = {", options: [],
            range: Fixtures.project.range(of: "\tobjects = {")!)
        XCTAssertThrowsError(try XcodeProject(path: URL(fileURLWithPath: "/p.xcodeproj"), text: escaped)) {
            XCTAssertTrue("\($0)".contains("keys do not map uniquely"), "\($0)")
        }
    }

    func testRejectsDeeplyNestedProjectBeforeFoundationDecoding() {
        let depth = 300
        let text = "{ objects = { x = " + String(repeating: "(", count: depth) + "a"
            + String(repeating: ",)", count: depth) + "; }; rootObject = x; }"
        XCTAssertThrowsError(
            try XcodeProject(path: URL(fileURLWithPath: "/p.xcodeproj"), text: text)
        ) { error in
            XCTAssertTrue("\(error)".contains("nesting exceeds"), "\(error)")
        }
    }

    func testSaveRefusesToOverwriteAConcurrentProjectChange() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftPods-XcodeProjectSave-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectDirectory = directory.appendingPathComponent("App.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let file = projectDirectory.appendingPathComponent("project.pbxproj")
        try Data(Fixtures.project.utf8).write(to: file)
        var project = try XcodeProject(path: projectDirectory)
        _ = project.put("test:concurrent", ["isa": "PBXGroup", "children": [], "sourceTree": "<group>"])

        let external = Fixtures.project.replacingOccurrences(of: "archiveVersion = 1;", with: "archiveVersion = 2;")
        XCTAssertEqual(external.utf8.count, Fixtures.project.utf8.count)
        try Data(external.utf8).write(to: file)
        XCTAssertThrowsError(try project.save()) {
            XCTAssertTrue("\($0)".contains("changed since SwiftPods read it"), "\($0)")
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), external)
    }

    func testAProjectFileWithAByteOrderMarkCanBeSaved() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftPods-XcodeProjectBOM-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectDirectory = directory.appendingPathComponent("App.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let file = projectDirectory.appendingPathComponent("project.pbxproj")
        try (Data([0xEF, 0xBB, 0xBF]) + Data(Fixtures.project.utf8)).write(to: file)

        var project = try XcodeProject(path: projectDirectory)
        _ = project.put("test:bom", ["isa": "PBXGroup", "children": [], "sourceTree": "<group>"])
        XCTAssertTrue(try project.save())
        XCTAssertNotNil(try XcodeProject(path: projectDirectory)[XcodeProject.identifier("test:bom")])
    }

    func testSaveRefreshesItsBaselineAndKeepsPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftPods-XcodeProjectRepeatSave-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectDirectory = directory.appendingPathComponent("App.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let file = projectDirectory.appendingPathComponent("project.pbxproj")
        try Data(Fixtures.project.utf8).write(to: file)
        XCTAssertEqual(chmod(file.path, 0o600), 0)

        var project = try XcodeProject(path: projectDirectory)
        _ = project.put("test:first-save", ["isa": "PBXGroup", "children": [], "sourceTree": "<group>"])
        XCTAssertTrue(try project.save())
        _ = project.put("test:second-save", ["isa": "PBXGroup", "children": [], "sourceTree": "<group>"])
        XCTAssertTrue(try project.save())
        XCTAssertFalse(try project.save())

        let reloaded = try XcodeProject(path: projectDirectory)
        XCTAssertNotNil(reloaded[XcodeProject.identifier("test:first-save")])
        XCTAssertNotNil(reloaded[XcodeProject.identifier("test:second-save")])
        var status = stat()
        XCTAssertEqual(lstat(file.path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o7777, 0o600)
    }

    func testTextInitializerCannotBlindlyOverwriteADifferentExistingFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftPods-XcodeProjectTextSave-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectDirectory = directory.appendingPathComponent("App.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let file = projectDirectory.appendingPathComponent("project.pbxproj")
        let external = Fixtures.project.replacingOccurrences(of: "archiveVersion = 1;", with: "archiveVersion = 2;")
        try Data(external.utf8).write(to: file)
        var project = try XcodeProject(path: projectDirectory, text: Fixtures.project)
        _ = project.put("test:unsafe", ["isa": "PBXGroup", "children": [], "sourceTree": "<group>"])

        XCTAssertThrowsError(try project.save()) {
            XCTAssertTrue("\($0)".contains("changed since SwiftPods read it"), "\($0)")
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), external)
    }

    /// Unchanged real projects must serialize byte for byte. Set SWIFTPODS_PBX_CORPUS to a directory of
    /// `project.pbxproj` copies (any file names) to run it; private projects stay out of the repository.
    func testCorpusRoundTrip() throws {
        guard let directory = ProcessInfo.processInfo.environment["SWIFTPODS_PBX_CORPUS"] else {
            throw XCTSkip("SWIFTPODS_PBX_CORPUS is not set")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory).sorted()
        XCTAssertFalse(files.isEmpty)
        for name in files {
            let text = try String(contentsOfFile: directory + "/" + name, encoding: .utf8)
            var project = try XcodeProject(path: URL(fileURLWithPath: "/corpus/\(name).xcodeproj"), text: text)
            XCTAssertEqual(project.serialized(), text, name)
            let reference = project.put("corpus:\(name)", ["isa": "XCLocalSwiftPackageReference", "relativePath": "SwiftPods/Binaries"])
            project.append(reference, to: "packageReferences", of: project.rootID)
            let edited = project.serialized()
            XCTAssertEqual(try XcodeProject(path: project.path, text: edited).objects, project.objects, name)
            let removed = Set(text.split(separator: "\n")).subtracting(edited.split(separator: "\n"))
            XCTAssertLessThanOrEqual(removed.count, 2, "\(name): \(removed)")
        }
    }
}
