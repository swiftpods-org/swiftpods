import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeDoctorPathBoundaryTests: XCTestCase {
    private func fixture(identifier: String = "Slice", library: String = "Payload.a") throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sdk = root.appendingPathComponent("Fixture.xcframework", isDirectory: true)
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "AvailableLibraries": [
                [
                    "LibraryIdentifier": identifier,
                    "LibraryPath": library, "SupportedPlatform": "macos", "SupportedArchitectures": ["arm64"],
                ]
            ]
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(
            to: sdk.appendingPathComponent("Info.plist"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, sdk)
    }

    private func binary(_ path: URL) throws {
        // Minimal arm64 Mach-O build-version metadata; no host tools are required.
        let words: [UInt32] = [0xfeed_facf, 0x0100_000c, 0, 6, 1, 24, 0, 0, 0x32, 24, 1, 13 << 16, 13 << 16, 0]
        var data = Data()
        for word in words {
            var little = word.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: path)
    }

    private func checks(_ root: URL) -> [[String: Any]] {
        Doctor(
            directory: root, platform: "osx", variant: nil, architecture: nil, application: nil, deploymentTarget: nil
        )
        .report(bundle: nil)["checks"] as? [[String: Any]] ?? []
    }

    private func failedLayout(_ root: URL) -> Bool {
        checks(root).contains { $0["name"] as? String == "xcframework_layout" && $0["status"] as? String == "failed" }
    }

    func testInvalidUnicodeSliceIdentifiersAreRejectedBeforeBinaryInspection() throws {
        for identifier in ["/\u{301}Slice", "../\u{301}Slice"] {
            let (root, sdk) = try fixture(identifier: identifier)
            try binary(sdk.appendingPathComponent(identifier).appendingPathComponent("Payload.a"))
            XCTAssertTrue(failedLayout(root), identifier)
        }
    }

    func testInvalidUnicodeLibraryPathsAreRejectedBeforeBinaryInspection() throws {
        for library in ["/\u{301}Payload.a", "../\u{301}Payload.a"] {
            let (root, sdk) = try fixture(library: library)
            try binary(sdk.appendingPathComponent("Slice").appendingPathComponent(library))
            XCTAssertTrue(failedLayout(root), library)
        }
    }

    func testRelativeUnicodeSliceAndLibraryPathsRemainInspectable() throws {
        let (root, sdk) = try fixture(identifier: "\u{301}Slice", library: "\u{301}Payload.a")
        try binary(sdk.appendingPathComponent("\u{301}Slice/\u{301}Payload.a"))
        XCTAssertFalse(failedLayout(root))
        XCTAssertTrue(
            checks(root).contains {
                $0["name"] as? String == "xcframework_metadata" && $0["status"] as? String == "passed"
            })
    }

    func testSliceProductCannotAliasAnOutsideBinary() throws {
        let (root, sdk) = try fixture()
        let outside = root.appendingPathComponent("Outside.bin")
        try binary(outside)
        let slice = sdk.appendingPathComponent("Slice", isDirectory: true)
        try FileManager.default.createDirectory(at: slice, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: slice.appendingPathComponent("Payload.a"), withDestinationURL: outside)
        XCTAssertTrue(failedLayout(root))
    }

    func testFrameworkExecutableCannotEscapeItsFrameworkDirectory() throws {
        let (root, sdk) = try fixture(library: "Payload.framework")
        let framework = sdk.appendingPathComponent("Slice/Payload.framework", isDirectory: true)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        let info = ["CFBundleExecutable": "../\u{301}Escape"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(
            to: framework.appendingPathComponent("Info.plist"))
        try binary(sdk.appendingPathComponent("Slice/\u{301}Escape"))
        XCTAssertTrue(failedLayout(root))
    }

    func testApplicationExecutableCannotEscapeItsBundle() throws {
        for mac in [false, true] {
            let (root, _) = try fixture()
            let app = root.appendingPathComponent("Example.app", isDirectory: true)
            let infoPath = app.appendingPathComponent(mac ? "Contents/Info.plist" : "Info.plist")
            try FileManager.default.createDirectory(
                at: infoPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            let executable = mac ? "../../../\u{301}Outside" : "../\u{301}Outside"
            try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleExecutable": executable], format: .xml, options: 0
            ).write(to: infoPath)
            try FileManager.default.createDirectory(
                at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            try binary(root.appendingPathComponent("\u{301}Outside"))
            let report = Doctor(
                directory: root, platform: "osx", variant: nil, architecture: nil, application: app,
                deploymentTarget: nil
            ).report(bundle: nil)
            XCTAssertTrue(
                (report["checks"] as? [[String: Any]] ?? []).contains {
                    $0["name"] as? String == "application" && $0["status"] as? String == "failed"
                })
        }
    }

    func testEmbeddedFrameworkCannotAliasAnOutsideContainer() throws {
        let (root, _) = try fixture()
        let app = root.appendingPathComponent("Example.app", isDirectory: true)
        try binary(app.appendingPathComponent("Contents/MacOS/Example"))
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleExecutable": "Example"], format: .xml, options: 0
        ).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let framework = root.appendingPathComponent("Outside.framework", isDirectory: true)
        try binary(framework.appendingPathComponent("Outside"))
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleExecutable": "Outside"], format: .xml, options: 0
        ).write(to: framework.appendingPathComponent("Info.plist"))
        let embedded = app.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: embedded, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: embedded.appendingPathComponent("Outside.framework"), withDestinationURL: framework)
        let report = Doctor(
            directory: root, platform: "osx", variant: nil, architecture: nil, application: app, deploymentTarget: nil
        ).report(bundle: nil)
        XCTAssertTrue(
            (report["checks"] as? [[String: Any]] ?? []).contains {
                $0["name"] as? String == "application" && $0["status"] as? String == "failed"
            })
    }
}
