import Foundation
import XCTest

@testable import SwiftPodsCore

final class CLIProjectDiscoveryTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func folder(_ relative: String, in root: URL) throws -> URL {
        let directory = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func manifest(_ name: String = "Podfile", in directory: URL) throws {
        // Static discovery must not evaluate even an invalid Ruby manifest.
        try Data("raise 'Static discovery executed project code'\n".utf8).write(
            to: directory.appendingPathComponent(name))
    }

    private func inspect(from directory: URL, options: [String] = []) throws -> [String: Any] {
        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent(
            "swiftpods")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path), executable.path)
        var environment = ProcessInfo.processInfo.environment
        environment["SWIFTPODS_BUNDLE"] = directory.appendingPathComponent("no-runtime-bundle").path
        let result = try ToolProcess.run(
            executable.path, ["doctor", "--static", "--json"] + options,
            directory: directory, environment: environment)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
        XCTAssertNil(report["diagnostic"], String(decoding: result.error, as: UTF8.self))
        // The isolated fixture intentionally has no managed runtime.
        XCTAssertEqual(result.status, 1)
        return report
    }

    private func selectedProject(_ report: [String: Any]) throws -> URL {
        URL(fileURLWithPath: try XCTUnwrap(report["project"] as? String)).resolvingSymlinksInPath()
    }

    func testNestedInvocationFindsTheParentPodfileWithoutExecutingProjectCode() throws {
        let root = try directory()
        let nested = try folder("Sources/Deep spaces-🧩", in: root)
        try manifest(in: root)
        let before = try FileFingerprint.tree(root)
        let caller = FileManager.default.currentDirectoryPath
        XCTAssertEqual(try selectedProject(inspect(from: nested)), root.resolvingSymlinksInPath())
        XCTAssertEqual(FileManager.default.currentDirectoryPath, caller)
        XCTAssertEqual(try FileFingerprint.tree(root), before)
    }

    func testNearestManifestWinsOverAnAncestorsPreferredFilename() throws {
        let root = try directory()
        let inner = try folder("Inner", in: root)
        let nested = try folder("Sources/Deep", in: inner)
        try manifest("CocoaPods.podfile.yaml", in: root)
        try manifest(in: inner)
        XCTAssertEqual(try selectedProject(inspect(from: nested)), inner.resolvingSymlinksInPath())
        XCTAssertEqual(try selectedProject(inspect(from: inner)), inner.resolvingSymlinksInPath())
    }

    func testAllSupportedManifestNamesAreFoundAndDirectoriesAreSkipped() throws {
        let root = try directory()
        for name in NativePodfilePath.names {
            let project = try folder(name + "-project", in: root)
            let nested = try folder("Sources/Deep", in: project)
            try manifest(name, in: project)
            _ = try folder("Podfile", in: nested)
            XCTAssertEqual(try selectedProject(inspect(from: nested)), project.resolvingSymlinksInPath(), name)
        }
    }

    func testExplicitProjectDirectoryNeverFallsBackToAParent() throws {
        let root = try directory()
        let nested = try folder("Sources/Deep", in: root)
        let selected = try folder("Chosen empty project", in: root)
        try manifest(in: root)
        let relative = NativePath.relativePath(of: selected, to: nested)
        for options in [["--project-directory", relative], ["--project-directory=" + relative]] {
            let report = try inspect(from: nested, options: options)
            XCTAssertEqual(try selectedProject(report), selected.resolvingSymlinksInPath())
            let checks = try XCTUnwrap(report["checks"] as? [[String: Any]])
            XCTAssertEqual(checks.first { $0["name"] as? String == "podfile" }?["status"] as? String, "failed")
        }
    }

    func testMissingManifestKeepsTheInvocationDirectory() throws {
        let root = try directory()
        let nested = try folder("No manifest/Sources", in: root)
        XCTAssertEqual(try selectedProject(inspect(from: nested)), nested.resolvingSymlinksInPath())
    }

    func testSymlinkedInvocationDirectoryFindsThePhysicalProject() throws {
        let root = try directory()
        let project = try folder("Physical project", in: root)
        let nested = try folder("Sources/Deep", in: project)
        let link = root.appendingPathComponent("Link to sources")
        try manifest(in: project)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: nested)
        XCTAssertEqual(try selectedProject(inspect(from: link)), project.resolvingSymlinksInPath())
    }
}
