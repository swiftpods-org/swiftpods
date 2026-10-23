import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeGlobScalarBoundaryTests: XCTestCase {
    private func root(_ names: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in names {
            let path = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture\n".utf8).write(to: path)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testWildcardOperatorsBeforeCombiningMarks() throws {
        let root = try root(["q\u{301}.c", "other.c"])
        for pattern in ["*\u{301}.c", "?\u{301}.c"] {
            XCTAssertEqual(try nativeGlob(pattern, root: root).map(\.lastPathComponent), ["q\u{301}.c"], pattern)
        }
    }

    func testCharacterClassDelimitersBeforeCombiningMarks() throws {
        let root = try root(["q\u{301}.c", "q.c", "\u{301}.c", "other.c"])
        XCTAssertEqual(try nativeGlob("[q]\u{301}.c", root: root).map(\.lastPathComponent), ["q\u{301}.c"])
        XCTAssertEqual(Set(try nativeGlob("[\u{301}q].c", root: root).map(\.lastPathComponent)), ["q.c", "\u{301}.c"])
    }

    func testBracesAndRecursiveSeparatorBeforeCombiningMarks() throws {
        let root = try root(["\u{301}Folder/q.c", "Other/q.c", "\u{301}Kit.c", "Nested/\u{301}Kit.c"])
        XCTAssertEqual(
            Set(try nativeGlob("{\u{301}Folder,Other}/*.c", root: root).map(\.path)),
            [root.appendingPathComponent("\u{301}Folder/q.c").path, root.appendingPathComponent("Other/q.c").path])
        XCTAssertEqual(
            Set(try nativeGlob("**/\u{301}Kit.c", root: root).map(\.path)),
            [root.appendingPathComponent("\u{301}Kit.c").path, root.appendingPathComponent("Nested/\u{301}Kit.c").path])
    }

    func testEscapeBeforeCombiningMark() throws {
        let root = try root(["\u{301}q.c", "q.c"])
        XCTAssertEqual(try nativeGlob("\\\u{301}q.c", root: root).map(\.lastPathComponent), ["\u{301}q.c"])
    }

    func testLiteralCanonicalNamesStillMatchAcrossNormalization() throws {
        let root = try root(["cafe\u{301}.c"])
        XCTAssertEqual(try nativeGlob("café.c", root: root).count, 1)
        XCTAssertEqual(try nativeGlob("cafe\u{301}.c", root: root).count, 1)
    }

    func testGlobNulIsRejectedInsteadOfMatchingNothing() throws {
        let root = try root(["A.c"])
        XCTAssertThrowsError(try nativeGlob("*.c\0*.h", root: root)) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-SPEC-PATH")
        }
    }

    func testAbsoluteBraceAlternativesRemainInvalidBeforeCombiningMarks() throws {
        let root = try root(["A.c"])
        for pattern in ["/\u{301}A.c", "{/\u{301}A.c,*.c}", "{*.c,/\u{301}A.c}"] {
            XCTAssertThrowsError(try nativeGlob(pattern, root: root), pattern) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-SPEC-PATH")
            }
        }
    }

    func testDanglingLinksKeepLexicalPathsAcrossFilesystemAliases() throws {
        let root = try root(["Keep.h"])
        let link = root.appendingPathComponent(".swiftpods/backup/Gone.h")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../../missing.h")
        let alias = root.appendingPathExtension("alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: root.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: alias) }
        var aliases = Set([root.path, alias.path])
        if root.path.hasPrefix("/var/") { aliases.insert("/private" + root.path) }
        if root.path.hasPrefix("/private/var/") { aliases.insert(String(root.path.dropFirst("/private".count))) }
        for spelling in aliases {
            let boundary = URL(fileURLWithPath: spelling)
            XCTAssertEqual(try nativeGlob("*.h", root: boundary).map(\.lastPathComponent), ["Keep.h"])
            let matches = try nativeGlob(".swiftpods/backup/*.h", root: boundary)
            XCTAssertEqual(matches.map(\.lastPathComponent), ["Gone.h"])
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: matches[0].path), "../../missing.h")
        }
    }

    func testDirectoryLinksRemainEntriesWithoutTraversingTheirTargets() throws {
        let root = try root(["Payload/Keep.h"])
        let alias = root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "Payload")
        XCTAssertEqual(try nativeGlob("**/*.h", root: root).map(\.lastPathComponent), ["Keep.h"])
        XCTAssertEqual(try nativeGlob("Alias", root: root), [alias])
    }
}
