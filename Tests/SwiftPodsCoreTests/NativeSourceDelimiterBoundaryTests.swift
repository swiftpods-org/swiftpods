import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeSourceDelimiterBoundaryTests: XCTestCase {
    private let project = URL(fileURLWithPath: "/tmp/source-location-project", isDirectory: true)

    func testScpColonBeforeCombiningCharactersIsStillARemoteDelimiter() {
        for suffix in ["\u{301}Repo", "\u{FE0F}Repo", "\u{200D}Repo", "\u{301}Repo/sub.git"] {
            let location = "fixture@example.invalid:" + suffix
            XCTAssertEqual(NativeSourceOptions.resolvedLocation(location, project: project), location)
        }
    }

    func testRemoteLocationsKeepTheirOriginalSpelling() {
        for location in [
            "https://example.invalid/\u{301}Repo.git", "ssh://git@example.invalid/\u{301}Repo.git",
            "file:///tmp/\u{301}Repo.git", "git@example.invalid:Repo.git", "Host:Repo%2FName.git",
        ] {
            XCTAssertEqual(NativeSourceOptions.resolvedLocation(location, project: project), location)
        }
    }

    func testRelativeSlashBeforeCombiningCharactersMakesColonALocalFilename() {
        for location in ["./\u{301}Repo:tag", "./\u{FE0F}Repo:tag", "./\u{200D}Repo:tag", "Sub/\u{301}Repo:tag"] {
            XCTAssertEqual(
                NativeSourceOptions.resolvedLocation(location, project: project),
                project.appendingPathComponent(location).standardizedFileURL.resolvingSymlinksInPath().path)
        }
    }

    func testParentAndAbsolutePathsInspectScalarDelimiters() {
        for location in ["../\u{301}Repo:tag", "/\u{301}Repo:tag", "/tmp/\u{301}Repo:tag"] {
            XCTAssertEqual(
                NativeSourceOptions.resolvedLocation(location, project: project),
                URL(fileURLWithPath: location, relativeTo: project).standardizedFileURL.resolvingSymlinksInPath().path)
        }
    }

    func testIndependentProjectsCannotShareAnUnresolvedLocalIdentity() {
        let location = "./\u{301}Repo:tag"
        let first = NativeSourceOptions.resolvedLocation(location, project: project.appendingPathComponent("first"))
        let second = NativeSourceOptions.resolvedLocation(location, project: project.appendingPathComponent("second"))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first, project.appendingPathComponent("first/\u{301}Repo:tag").path)
        XCTAssertEqual(second, project.appendingPathComponent("second/\u{301}Repo:tag").path)
    }

    func testCombiningCharactersAfterBothDelimitersDoNotChangeLocalMeaning() {
        let location = "./\u{301}Repo:\u{301}tag"
        XCTAssertEqual(
            NativeSourceOptions.resolvedLocation(location, project: project),
            project.appendingPathComponent(location).standardizedFileURL.resolvingSymlinksInPath().path)
    }

    func testLiteralPercentSequencesInMarkedLocalNamesAreNotDecoded() {
        let location = "./\u{301}Repo%2FName:tag%00"
        XCTAssertEqual(
            NativeSourceOptions.resolvedLocation(location, project: project),
            project.appendingPathComponent("\u{301}Repo%2FName:tag%00").path)
    }

    func testMarkedSymlinkAliasRetainsPhysicalSourceIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("Repository")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("\u{301}Alias:tag")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: repository)
        XCTAssertEqual(
            NativeSourceOptions.resolvedLocation("./\u{301}Alias:tag", project: root),
            NativeSourceOptions.resolvedLocation("./Repository", project: root))
    }
}
