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
        XCTAssertThrowsError(try Requirement.parsePacked([(String(Int.max) + ".1.0.0", location)])) { error in
            XCTAssertTrue((error as? ManifestError)?.message.contains("too large") == true)
        }
        XCTAssertThrowsError(try Requirement.parsePacked([("~> " + String(Int.max) + ".99.99.0", location)])) { error in
            XCTAssertTrue((error as? ManifestError)?.message.contains("too large") == true)
        }
    }

    func testRangesExcludePrereleasesUnlessABoundNamesOne() throws {
        func version(_ text: String) throws -> Version { try XCTUnwrap(Version(text)) }
        let major = Requirement.upToNextMajor(try version("1.0.0"))
        XCTAssertTrue(major.allows(try version("1.5.0")))
        XCTAssertFalse(major.allows(try version("1.5.0-beta")))
        XCTAssertFalse(major.allows(try version("2.0.0-beta.1")), "X.0.0-alpha is not selected by an upper bound of X.0.0")
        XCTAssertFalse(major.allows(try version("2.0.0")))

        let minor = Requirement.upToNextMinor(try version("1.2.3"))
        XCTAssertTrue(minor.allows(try version("1.2.5")))
        XCTAssertFalse(minor.allows(try version("1.2.5-beta")))
        XCTAssertFalse(minor.allows(try version("1.3.0-rc.1")))

        let fromPrerelease = Requirement.upToNextMajor(try version("2.0.0-beta.1"))
        XCTAssertTrue(fromPrerelease.allows(try version("2.0.0-beta.2")))
        XCTAssertTrue(fromPrerelease.allows(try version("2.1.0-rc.1")))
        XCTAssertTrue(fromPrerelease.allows(try version("2.0.0")))
        XCTAssertFalse(fromPrerelease.allows(try version("3.0.0-alpha")))

        let toPrerelease = Requirement.range(try version("1.0.0"), try version("2.0.0-beta"))
        XCTAssertTrue(toPrerelease.allows(try version("2.0.0-alpha")))
        XCTAssertFalse(toPrerelease.allows(try version("2.0.0-beta")))

        XCTAssertTrue(Requirement.exact(try version("1.0.0-rc.1")).allows(try version("1.0.0-rc.1")))
        XCTAssertFalse(Requirement.exact(try version("1.0.0")).allows(try version("1.0.0-rc.1")))
    }

    func testPackedVersionsKeepBothBoundsInTheSameUnits() throws {
        let location = SourceLocation(file: "/project/Podfile", line: 1, column: 1)
        func message(_ texts: [String]) -> String? {
            do {
                _ = try Requirement.parsePacked(texts.map { ($0, location) })
                return nil
            } catch {
                return String(describing: error)
            }
        }
        XCTAssertEqual(
            try Requirement.parsePacked([("~> 13.9.99.0", location)]), .range(Version(13_099_900, 0, 0), Version(13_100_000, 0, 0)),
            "A padded component carries instead of growing to three digits")
        XCTAssertEqual(
            try Requirement.parsePacked([(">= 3.8.0.0.0", location), ("< 4.0.0.0.0", location)]),
            .range(Version(308_000_000, 0, 0), Version(400_000_000, 0, 0)))
        XCTAssertTrue(message(["~> 13.9"])?.contains("not a complete version") == true)
        XCTAssertTrue(message(["13.9.0"])?.contains("not a complete version") == true)
        XCTAssertTrue(message([">= 12", "< 13.0.0.0"])?.contains("not a complete version") == true)
        XCTAssertTrue(message([">= 12.0.0.0", "< 13.0.0.0.0"])?.contains("same number of components") == true)
        XCTAssertThrowsError(try Requirement.parsePackedExact("~> 13.9.0.0", at: location)) { error in
            XCTAssertTrue((error as? ManifestError)?.message.contains("`exact` takes a version") == true)
        }
        XCTAssertEqual(try Requirement.parsePackedExact("13.9.0.0", at: location), .exact(Version(13_090_000, 0, 0)))
    }
}
