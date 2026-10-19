import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeGlobCharacterClassTests: XCTestCase {
    private func directory(_ names: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for name in names {
            let file = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        return root
    }

    private func matches(_ pattern: String, root: URL) throws -> Set<String> {
        Set(
            try nativeGlob(pattern, root: root).map {
                $0.pathComponents.dropFirst(root.standardizedFileURL.pathComponents.count).joined(separator: "/")
            })
    }

    func testCharacterClassesCannotCrossDirectorySeparators() throws {
        let root = try directory(["AqPoison.c", "AXPoison.c", "A/Poison.c"])
        for pattern in ["A[!X]Poison.c", "A[^X]Poison.c", "A[/q]Poison.c", "A[!X/]Poison.c"] {
            XCTAssertEqual(try matches(pattern, root: root), ["AqPoison.c"], pattern)
        }
    }

    func testLiteralOpeningBracketClassIsSupported() throws {
        let root = try directory(["[Source.c", "]Source.c", "Source.c"])
        XCTAssertEqual(try matches("[[]Source.c", root: root), ["[Source.c"])
    }

    func testAmpersandsAreClassMembersRatherThanRegexSetOperators() throws {
        let root = try directory(["a.c", "b.c", "&.c", "].c", "c.c"])
        XCTAssertEqual(try matches("[a&&b].c", root: root), ["a.c", "b.c", "&.c"])
    }

    func testBackslashEscapesAreLiteralGlobCharacters() throws {
        let root = try directory(["d.c", "1.c", "].c", "w.c", "s.c"])
        for letter in ["d", "w", "s"] {
            XCTAssertEqual(try matches("[\\" + letter + "].c", root: root), [letter + ".c"])
        }
    }

    func testEscapedClosingBracketAndHyphenRemainMembers() throws {
        let root = try directory(["a.c", "b.c", "c.c", "].c", "-.c", "^.c"])
        XCTAssertEqual(try matches("[a\\]b].c", root: root), ["a.c", "b.c", "].c"])
        XCTAssertEqual(try matches("[a\\-c].c", root: root), ["a.c", "-.c", "c.c"])
        XCTAssertEqual(try matches("[\\^].c", root: root), ["^.c"])
    }

    func testEmptyPositiveClassMatchesNothing() throws {
        let root = try directory(["].c", "a.c"])
        XCTAssertTrue(try matches("[]].c", root: root).isEmpty)
    }

    func testEmptyNegatedClassMatchesAnyVisibleCharacter() throws {
        let names = ["a.c", "b.c", "-.c", "].c", "&.c"]
        let root = try directory(names + [".c", "Dir/a.c"])
        for pattern in ["[!].c", "[^].c"] {
            XCTAssertEqual(try matches(pattern, root: root), Set(names), pattern)
        }
    }

    func testDescendingRangePreservesEndpointMembers() throws {
        let root = try directory(["z.c", "a.c", "m.c", "-.c", "].c"])
        XCTAssertEqual(try matches("[z-a].c", root: root), ["z.c", "a.c"])
    }

    func testOrdinaryRangesAndBraceAlternativesRemainCaseInsensitive() throws {
        let root = try directory(["A/a.c", "A/B.c", "B/c.c", "B/z.c", "A/.c"])
        XCTAssertEqual(try matches("{A,B}/[a-c].c", root: root), ["A/a.c", "A/B.c", "B/c.c"])
    }

    func testClassPatternsRetainDotfileAndMalformedPatternRules() throws {
        let root = try directory([".hidden.c", "ahidden.c"])
        XCTAssertEqual(try matches("[!x]hidden.c", root: root), ["ahidden.c"])
        XCTAssertEqual(try matches("\\.hidden.c", root: root), [".hidden.c"])
        for pattern in ["[", "[abc", "[a\\]"] {
            XCTAssertThrowsError(try matches(pattern, root: root)) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-SPEC-PATTERN")
            }
        }
    }

    func testMixedCaseRangesFoldEndpointsBeforeMatching() throws {
        let root = try directory(["A.c", "b.c", "z.c", "_.c", "[.c"])
        for pattern in ["[A-z].c", "[a-Z].c"] {
            XCTAssertEqual(try matches(pattern, root: root), ["A.c", "b.c", "z.c"], pattern)
        }
        for pattern in ["[Z-a].c", "[z-A].c"] {
            XCTAssertEqual(try matches(pattern, root: root), ["A.c", "z.c"], pattern)
        }
    }

    func testUnicodeLiteralsAndClassesMatchDecomposedFilesystemPaths() throws {
        let root = try directory(["é.c", "ê.c", "🧩.c"])
        for pattern in ["é.c", "e\u{301}.c", "[é].c"] {
            XCTAssertEqual(try matches(pattern, root: root), ["é.c"], pattern)
        }
        XCTAssertEqual(try matches("[é-ê].c", root: root), ["é.c", "ê.c"])
        XCTAssertEqual(try matches("[🧩].c", root: root), ["🧩.c"])
    }

    func testClassMembersKeepTheirDeclaredUnicodeScalars() throws {
        let root = try directory(["e.c", "é.c", "\u{301}.c"])
        XCTAssertEqual(try matches("[e\u{301}].c", root: root), ["e.c", "\u{301}.c"])
    }

    func testPathBoundariesUseComponentsBeforeLeadingCombiningMarks() throws {
        let root = try directory(["Folderé/\u{301}Source.c"])
        let folder = root.appendingPathComponent("Foldere\u{301}")
        XCTAssertEqual(try matches("*", root: folder), ["\u{301}Source.c"])
    }

    func testFullPathAnchorsDoNotMatchBeforeFinalNewlines() throws {
        let root = try directory(["Tail.c", "Tail.c\n", "Tail.c\r", "Tail.c\r\n", "Tail.c\u{2028}"])
        XCTAssertEqual(try matches("Tail.c", root: root), ["Tail.c"])
    }
}
