import Darwin
import Foundation
@testable import SwiftPodsKit
import XCTest

final class DirectoryEnumerationSecurityTests: XCTestCase {
    func testBoundedEnumerationRejectsTheFirstEntryBeyondItsBudget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swiftpods-bounded-enumeration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["c", "a", "b"] {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        let descriptor = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }

        XCTAssertEqual(
            try Installer.boundedDirectoryNames(in: descriptor, maximumCount: 3, kind: "test directory"),
            ["a", "b", "c"])
        XCTAssertThrowsError(
            try Installer.boundedDirectoryNames(in: descriptor, maximumCount: 2, kind: "test directory")
        ) { error in
            XCTAssertTrue("\(error)".contains("more than 2 entries"), "\(error)")
        }
    }
}
