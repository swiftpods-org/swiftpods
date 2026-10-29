import Foundation
import SwiftPodsTestSupport
import SwiftPodsXcode
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

    func testIdentifiersAreStableAndXcodeShaped() {
        let id = XcodeProject.identifier("package:github.com/a/kit")
        XCTAssertEqual(id, XcodeProject.identifier("package:github.com/a/kit"))
        XCTAssertNotEqual(id, XcodeProject.identifier("package:github.com/a/other"))
        XCTAssertNotNil(id.range(of: #"\A[0-9A-F]{24}\z"#, options: .regularExpression))
    }

    func testRejectsInvalidProjects() {
        XCTAssertThrowsError(try XcodeProject(path: URL(fileURLWithPath: "/p.xcodeproj"), text: "{ objects = {}; }"))
        XCTAssertThrowsError(try XcodeProject(path: URL(fileURLWithPath: "/p.xcodeproj"), text: "{ objects = { "))
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
