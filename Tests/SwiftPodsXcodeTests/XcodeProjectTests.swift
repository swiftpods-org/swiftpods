import Darwin
import Foundation
import SwiftPodsSecurity
import SwiftPodsTestSupport
@testable import SwiftPodsXcode
import XCTest

private final class ConcurrentProjectWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var project: XcodeProject
    private var storedError: (any Error)?

    init(_ project: XcodeProject) {
        self.project = project
    }

    func save(entered: DispatchSemaphore, release: DispatchSemaphore) {
        do {
            try project.save(
                beforeAtomicReplacement: {},
                afterAtomicReplacement: {
                    entered.signal()
                    if release.wait(timeout: .now() + 5) == .timedOut {
                        record(NSError(domain: "ConcurrentProjectWriter", code: 1))
                    }
                })
        } catch {
            record(error)
        }
    }

    var error: (any Error)? {
        lock.withLock { storedError }
    }

    private func record(_ error: any Error) {
        lock.withLock {
            if storedError == nil { storedError = error }
        }
    }
}

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

    func testFileReaderRejectsSymlinkFifoAndOversizedProject() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftPods-XcodeProjectTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("App.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("project.pbxproj")
        let source = directory.appendingPathComponent("real.pbxproj")
        try Data(Fixtures.project.utf8).write(to: source)

        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: source)
        XCTAssertThrowsError(try XcodeProject(path: project)) {
            XCTAssertTrue("\($0)".contains("symbolic link"), "\($0)")
        }

        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(file.path.withCString { mkfifo($0, S_IRUSR | S_IWUSR) }, 0)
        XCTAssertThrowsError(try XcodeProject(path: project)) {
            XCTAssertTrue("\($0)".contains("regular file"), "\($0)")
        }

        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 32 * 1_024 * 1_024 + 1)
        try handle.close()
        XCTAssertThrowsError(try XcodeProject(path: project)) {
            XCTAssertTrue("\($0)".contains("32 MiB"), "\($0)")
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

    func testSaveRollsBackAChangeAfterTheFinalValidation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftPods-XcodeProjectAtomicRace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectDirectory = directory.appendingPathComponent("App.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let file = projectDirectory.appendingPathComponent("project.pbxproj")
        try Data(Fixtures.project.utf8).write(to: file)
        var project = try XcodeProject(path: projectDirectory)
        _ = project.put("test:atomic-race", ["isa": "PBXGroup", "children": [], "sourceTree": "<group>"])
        let external = Fixtures.project.replacingOccurrences(of: "archiveVersion = 1;", with: "archiveVersion = 7;")

        XCTAssertThrowsError(try project.save(beforeAtomicReplacement: {
            try! Data(external.utf8).write(to: file, options: .atomic)
        })) { error in
            XCTAssertTrue("\(error)".contains("atomic replacement"), "\(error)")
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), external)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: projectDirectory.path)
                .contains(where: { $0.hasPrefix(".project.pbxproj.swiftpods-") }))
    }

    func testConcurrentProjectWritersSerializeOnTheStableDirectoryInode() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftPods-XcodeProjectConcurrentSave-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectDirectory = directory.appendingPathComponent("App.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try Data(Fixtures.project.utf8).write(to: projectDirectory.appendingPathComponent("project.pbxproj"))

        var first = try XcodeProject(path: projectDirectory)
        let firstID = first.put(
            "test:concurrent-first", ["isa": "PBXGroup", "children": [], "sourceTree": "<group>"])
        let writer = ConcurrentProjectWriter(first)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            writer.save(entered: entered, release: release)
            completed.signal()
        }
        guard entered.wait(timeout: .now() + 5) == .success else {
            release.signal()
            _ = completed.wait(timeout: .now() + 5)
            XCTFail("The first project writer did not reach atomic replacement")
            return
        }
        // Load after the first swap: the path now names a new, otherwise-unlocked file inode. Without the directory
        // lock this writer can complete while the first writer is still validating and cleaning up its transaction.
        var second = try XcodeProject(path: projectDirectory)
        let secondID = second.put(
            "test:concurrent-second", ["isa": "PBXGroup", "children": [], "sourceTree": "<group>"])
        XCTAssertThrowsError(try second.save()) { error in
            XCTAssertTrue("\(error)".contains("Another process is updating the Xcode project"), "\(error)")
        }
        release.signal()
        XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
        XCTAssertNil(writer.error)

        let saved = try XcodeProject(path: projectDirectory)
        XCTAssertNotNil(saved[firstID])
        XCTAssertNil(saved[secondID])
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: projectDirectory.path)
                .contains(where: { $0.hasPrefix(".project.pbxproj.swiftpods-") }))
    }

    func testSaveDoesNotAdoptAReplacementProjectDirectoryEvenWhenBytesMatch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftPods-XcodeProjectDirectorySwap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectDirectory = directory.appendingPathComponent("App.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try Data(Fixtures.project.utf8).write(to: projectDirectory.appendingPathComponent("project.pbxproj"))
        var project = try XcodeProject(path: projectDirectory)
        _ = project.put("test:replacement", ["isa": "PBXGroup", "children": [], "sourceTree": "<group>"])
        let desired = project.serialized()

        try FileManager.default.moveItem(
            at: projectDirectory, to: directory.appendingPathComponent("Original.xcodeproj", isDirectory: true))
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let replacement = projectDirectory.appendingPathComponent("project.pbxproj")
        try Data(desired.utf8).write(to: replacement)

        XCTAssertThrowsError(try project.save()) {
            XCTAssertTrue("\($0)".contains("directory changed since it was read"), "\($0)")
        }
        XCTAssertEqual(try String(contentsOf: replacement, encoding: .utf8), desired)
    }

    func testAnchoredSaveRejectsAncestorRebindBeforeAtomicReplacement() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftPods-XcodeProjectAnchored-\(UUID().uuidString)", isDirectory: true)
        let projects = workspace.appendingPathComponent("Projects", isDirectory: true)
        let decoy = workspace.appendingPathComponent("Decoy", isDirectory: true)
        let projectDirectory = projects.appendingPathComponent("App.xcodeproj", isDirectory: true)
        let decoyProject = decoy.appendingPathComponent("App.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: decoyProject, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try Data(Fixtures.project.utf8).write(to: projectDirectory.appendingPathComponent("project.pbxproj"))
        try Data(Fixtures.project.utf8).write(to: decoyProject.appendingPathComponent("project.pbxproj"))

        let root = workspace.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        XCTAssertGreaterThanOrEqual(root, 0)
        defer { if root >= 0 { close(root) } }
        var project = try XcodeProject(
            path: projectDirectory, relativePath: "Projects/App.xcodeproj",
            relativeToDirectoryDescriptor: root)
        let inserted = project.put(
            "test:anchored-rebind", ["isa": "PBXGroup", "children": [], "sourceTree": "<group>"])

        XCTAssertThrowsError(try project.save(beforeAtomicReplacement: {
            let result = projects.path.withCString { first in
                decoy.path.withCString { second in
                    renameatx_np(AT_FDCWD, first, AT_FDCWD, second, UInt32(RENAME_SWAP))
                }
            }
            XCTAssertEqual(result, 0)
        })) { error in
            XCTAssertTrue("\(error)".contains("anchored Xcode project directory changed"), "\(error)")
        }

        let pathNowNamesDecoy = try XcodeProject(path: projectDirectory)
        let originalNowAtDecoy = try XcodeProject(path: decoyProject)
        XCTAssertNil(pathNowNamesDecoy[inserted])
        XCTAssertNil(originalNowAtDecoy[inserted])
    }

    func testSaveRefreshesItsBaselineAndPreservesPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftPods-XcodeProjectRepeatSave-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectDirectory = directory.appendingPathComponent("App.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let file = projectDirectory.appendingPathComponent("project.pbxproj")
        try Data(Fixtures.project.utf8).write(to: file)
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        let attributeName = "com.swiftpods.tests.metadata"
        let attribute = Data("preserve-me".utf8)
        XCTAssertEqual(attribute.withUnsafeBytes {
            setxattr(file.path, attributeName, $0.baseAddress, $0.count, 0, 0)
        }, 0)
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone allow read", file.path]
        try chmod.run()
        chmod.waitUntilExit()
        XCTAssertEqual(chmod.terminationStatus, 0)
        let originalDescriptor = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(originalDescriptor, 0)
        let originalMetadata = try BoundedFileSecurityMetadata.capture(originalDescriptor)
        close(originalDescriptor)
        var originalStatus = stat()
        XCTAssertEqual(lstat(file.path, &originalStatus), 0)

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
        XCTAssertEqual(status.st_uid, originalStatus.st_uid)
        XCTAssertEqual(status.st_gid, originalStatus.st_gid)
        XCTAssertEqual(status.st_flags, originalStatus.st_flags)
        let attributeSize = getxattr(file.path, attributeName, nil, 0, 0, 0)
        XCTAssertEqual(attributeSize, attribute.count)
        var restoredAttribute = Data(count: max(0, attributeSize))
        let restoredSize = restoredAttribute.withUnsafeMutableBytes {
            getxattr(file.path, attributeName, $0.baseAddress, $0.count, 0, 0)
        }
        XCTAssertEqual(restoredSize, attribute.count)
        XCTAssertEqual(restoredAttribute, attribute)
        let restoredDescriptor = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(restoredDescriptor, 0)
        let restoredMetadata = try BoundedFileSecurityMetadata.capture(restoredDescriptor)
        close(restoredDescriptor)
        XCTAssertEqual(restoredMetadata.attributes, originalMetadata.attributes)
        XCTAssertEqual(restoredMetadata.acl, originalMetadata.acl)
    }

    func testSaveRejectsExcessiveExtendedAttributeCountBeforeReplacement() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftPods-XcodeProjectMetadataLimit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectDirectory = directory.appendingPathComponent("App.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let file = projectDirectory.appendingPathComponent("project.pbxproj")
        let original = Data(Fixtures.project.utf8)
        try original.write(to: file)
        let value = Data([0x41])
        for index in 0...128 {
            let name = String(format: "com.swiftpods.tests.metadata-limit-%03d", index)
            XCTAssertEqual(value.withUnsafeBytes {
                setxattr(file.path, name, $0.baseAddress, $0.count, 0, 0)
            }, 0, name)
        }

        var project = try XcodeProject(path: projectDirectory)
        _ = project.put("test:metadata-limit", ["isa": "PBXGroup", "children": [], "sourceTree": "<group>"])
        XCTAssertThrowsError(try project.save()) { error in
            XCTAssertTrue("\(error)".contains("too many extended attributes"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: projectDirectory.path).contains {
            $0.hasPrefix(".project.pbxproj.swiftpods-")
        })
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
            XCTAssertTrue("\($0)".contains("does not match the text supplied"), "\($0)")
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
