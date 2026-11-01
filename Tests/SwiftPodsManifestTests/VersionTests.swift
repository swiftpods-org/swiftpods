@testable import SwiftPodsManifest
import XCTest

final class VersionTests: XCTestCase {
    func testPrereleaseAndBuildIdentifiersFollowSemVerGrammar() {
        XCTAssertNotNil(Version("1.2.3-alpha.1"))
        XCTAssertNotNil(Version("1.2.3-Alpha-1.0"))
        XCTAssertNotNil(Version("1.2.3-0"))
        XCTAssertNotNil(Version("1.2.3-01"), "SwiftPM accepts numeric prerelease identifiers with leading zeroes")
        XCTAssertNotNil(Version("1.2.3+build.01.sha-ABC"))
        XCTAssertNotNil(Version("1.2.3--"))

        for text in [
            "1.2.3-alpha..1",
            "1.2.3-.alpha",
            "1.2.3-alpha.",
            "1.2.3-alpha_1",
            "1.2.3-alpha/1",
            "1.2.3-β",
            "1.2.3+",
            "1.2.3+build..1",
            "1.2.3+.build",
            "1.2.3+build.",
            "1.2.3+build_1",
            "1.2.3+build.β",
            "1.2.3+build+τwo",
        ] {
            XCTAssertNil(Version(text), text)
        }
    }

    func testBuildMetadataDoesNotAffectVersionIdentityOrPrecedence() throws {
        let plain = try XCTUnwrap(Version("1.2.3"))
        let first = try XCTUnwrap(Version("1.2.3+first"))
        let second = try XCTUnwrap(Version("1.2.3+second.01"))

        XCTAssertEqual(plain, first)
        XCTAssertEqual(first, second)
        XCTAssertEqual(Set([plain, first, second]).count, 1)
        XCTAssertFalse(first < second)
        XCTAssertFalse(second < first)
        XCTAssertEqual(second.description, "1.2.3+second.01")
    }

    func testArbitrarilyLargeNumericPrereleaseIdentifiersCompareNumerically() throws {
        let smaller = try XCTUnwrap(Version("1.0.0-999999999999999999999999999999"))
        let larger = try XCTUnwrap(Version("1.0.0-1000000000000000000000000000000"))
        let nonnumeric = try XCTUnwrap(Version("1.0.0-1a"))
        let padded = try XCTUnwrap(Version("1.0.0-01"))
        let canonical = try XCTUnwrap(Version("1.0.0-1"))

        XCTAssertLessThan(smaller, larger)
        XCTAssertLessThan(larger, nonnumeric)
        XCTAssertEqual(padded, canonical)
        XCTAssertEqual(Set([padded, canonical]).count, 1)
        XCTAssertFalse(padded < canonical)
        XCTAssertFalse(canonical < padded)

        let paddedSequence = try XCTUnwrap(Version("1.0.0-01.a"))
        let canonicalSequence = try XCTUnwrap(Version("1.0.0-1.a"))
        let laterSequence = try XCTUnwrap(Version("1.0.0-1.b"))
        XCTAssertEqual(paddedSequence, canonicalSequence)
        XCTAssertEqual(Set([paddedSequence, canonicalSequence]).count, 1)
        XCTAssertLessThan(paddedSequence, laterSequence)
        XCTAssertFalse(laterSequence < paddedSequence)
    }

    func testRequirementUpperBoundsDoNotOverflow() {
        let maximumMajor = Version(Int.max, 0, 0)
        XCTAssertTrue(Requirement.upToNextMajor(maximumMajor).allows(Version(Int.max, 1, 0)))
        XCTAssertFalse(Requirement.upToNextMajor(maximumMajor).allows(Version(Int.max - 1, Int.max, Int.max)))

        let maximumMinor = Version(1, Int.max, 0)
        XCTAssertTrue(Requirement.upToNextMinor(maximumMinor).allows(Version(1, Int.max, 1)))
        XCTAssertFalse(Requirement.upToNextMinor(maximumMinor).allows(Version(2, 0, 0)))
    }

    func testOversizedPackedVersionsReturnManifestErrorsInsteadOfTrapping() {
        let location = SourceLocation(file: "/project/Podfile", line: 1, column: 1)

        XCTAssertThrowsError(try Requirement.parse([(">= " + String(Int.max), location)])) { error in
            XCTAssertTrue((error as? ManifestError)?.message.contains("no upper bound") == true)
        }
        XCTAssertThrowsError(try Requirement.parsePacked([(String(Int.max) + ".1", location)])) { error in
            XCTAssertTrue((error as? ManifestError)?.message.contains("too large") == true)
        }
        XCTAssertThrowsError(try Requirement.parsePacked([("~> " + String(Int.max), location)])) { error in
            XCTAssertTrue((error as? ManifestError)?.message.contains("too large") == true)
        }
    }
}
