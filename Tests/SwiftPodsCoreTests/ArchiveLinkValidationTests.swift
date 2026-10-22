import XCTest

@testable import SwiftPodsCore

final class ArchiveLinkValidationTests: XCTestCase {
    /// Small USTAR headers preserve duplicate entries and links that cannot be
    /// represented by creating a fixture tree on a case-insensitive volume.
    private func archive(_ entries: [(type: String, name: String, target: String)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var bytes = Data()
        for entry in entries {
            var header = [UInt8](repeating: 0, count: 512)
            func field(_ value: String, _ offset: Int) {
                header.replaceSubrange(offset..<(offset + value.utf8.count), with: value.utf8)
            }
            field(entry.name, 0)
            field("0000644\0", 100)
            field("0000000\0", 108)
            field("0000000\0", 116)
            field("00000000000\0", 124)
            field("00000000000\0", 136)
            field("        ", 148)
            field(entry.type, 156)
            field(entry.target, 157)
            field("ustar\0", 257)
            field("00", 263)
            let checksum = header.reduce(0) { $0 + Int($1) }
            field(String(format: "%06o", checksum) + "\0 ", 148)
            bytes.append(contentsOf: header)
        }
        bytes.append(Data(repeating: 0, count: 1024))
        let path = root.appendingPathComponent("fixture.tar")
        try bytes.write(to: path)
        return path
    }

    private func reject(_ entries: [(String, String, String)], file: StaticString = #filePath, line: UInt = #line) throws {
        let path = try archive(entries)
        XCTAssertThrowsError(try ExecutionPolicy.validateArchive(path.path), file: file, line: line) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-ARCHIVE-UNSAFE", file: file, line: line)
        }
    }

    func testLinkChainsUseCaseInsensitiveAndCanonicallyEquivalentPaths() throws {
        for (name, alias) in [("A", "a"), ("CAFÉ", "cafe\u{301}")] {
            try reject([("2", name, "."), ("2", "B", alias + "/../outside")])
        }
    }

    func testWritesThroughCaseVariantLinkAncestorsAreRejected() throws {
        try reject([("2", "Link", "."), ("0", "link/value", "")])
    }

    func testDuplicateEntriesCannotHideConflictingLinkTargets() throws {
        for name in ["B", "b"] {
            try reject([("2", "B", "."), ("2", "A", "."), ("2", name, "A/../outside")])
            try reject([("0", "B", ""), ("2", name, ".")])
        }
    }

    func testHardlinksCannotRelocateRelativeSymlinks() throws {
        try reject([("2", "inner/deep/source", "../.."), ("1", "link", "inner/deep/source")])
        try reject([
            ("1", "link", "intermediate"), ("1", "intermediate", "inner/deep/source"),
            ("2", "inner/deep/source", "../.."),
        ])
    }

    func testInternalSymbolicAndRegularHardlinkChainsRemainValid() throws {
        for entries in [
            [("0", "dir/source", ""), ("2", "dir/link", "source")],
            [("0", "source", ""), ("1", "first", "source"), ("1", "second", "first")],
            [("2", "Link", "dir"), ("0", "dir/source", ""), ("1", "copy", "Link/source")],
            [("2", "Link", "dir"), ("2", "Link", "dir"), ("0", "dir/source", "")],
        ] {
            let path = try archive(entries)
            try ExecutionPolicy.validateArchive(path.path)
        }
    }

    func testAbsolutePathsTraversalCyclesAndEmptyLinkTargetsAreRejected() throws {
        for entries in [
            [("0", "/outside", "")], [("0", "dir/../outside", "")],
            [("2", "link", "../outside")], [("1", "link", "../outside")],
            [("2", "A", "B"), ("2", "B", "A")], [("1", "A", "B"), ("1", "B", "A")],
            [("2", "link", "")], [("1", "link", "")],
        ] {
            try reject(entries)
        }
    }

    func testUnsafeArchivesAreRejectedBeforeCreatingTheExtractionDirectory() throws {
        let path = try archive([("2", "A", "."), ("2", "B", "a/../outside"), ("0", "b/value", "")])
        let destination = path.deletingLastPathComponent().appendingPathComponent("extracted")
        XCTAssertThrowsError(try NativeArchive.extract(path, source: [:], destination: destination, pod: "Kit")) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-ARCHIVE-UNSAFE")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
