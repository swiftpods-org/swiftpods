import XCTest

@testable import SwiftPodsCore

final class NativeVersionBoundaryTests: XCTestCase {
    func testNumericSegmentsFollowingHyphensParticipateInReleasePrecedence() throws {
        let numeric = try PodVersion("1.2.3-4")
        XCTAssertTrue(numeric.isPrerelease)
        XCTAssertEqual(numeric, try PodVersion("1.2.3.4"))
        XCTAssertGreaterThan(numeric, try PodVersion("1.2.3"))
        XCTAssertEqual(Set(try ["1.2.3-4", "1.2.3.4"].map(PodVersion.init)).count, 1)
    }

    func testHyphenPrereleaseStatusDoesNotImplyDistinctVersionPrecedence() throws {
        for spelling in ["1.0-", "1.0--", "1.0.0-0", "1.0.0--"] {
            let version = try PodVersion(spelling)
            XCTAssertTrue(version.isPrerelease, spelling)
            XCTAssertEqual(version, try PodVersion("1.0"), spelling)
            XCTAssertEqual(version.release, try PodVersion("1.0"), spelling)
        }
    }

    func testNumericPrefixesBeforePrereleaseLettersKeepTheirPrecision() throws {
        for (left, right) in [("1.0-1.alpha", "1.0.1.alpha"), ("1.0--1beta", "1.0.1beta")] {
            XCTAssertEqual(try PodVersion(left), try PodVersion(right))
            XCTAssertEqual(try PodVersion(left).release, try PodVersion("1.0.1"))
        }
    }

    func testExactNumericPrereleaseRequirementsAcceptTheirReleaseAliases() throws {
        for requirement in ["= 1.0.0-0", "= 1.0-", "= 1.0--"] {
            XCTAssertTrue(try PodRequirement([requirement]).accepts(PodVersion("1.0")))
        }
    }

    func testPessimisticBoundsIncludeAllDeclaredNumericSegments() throws {
        XCTAssertEqual(try PodVersion("1.0.0-0").pessimisticUpperBound().description, "1.0.1")
        XCTAssertEqual(try PodVersion("1.2-3").pessimisticUpperBound().description, "1.3")
        let requirement = try PodRequirement(["~> 1.0.0-0"])
        XCTAssertTrue(try requirement.accepts(PodVersion("1.0.0.5")))
        XCTAssertFalse(try requirement.accepts(PodVersion("1.0.5")))
    }

    func testResolverUsesNumericPrereleasePrecedenceAndEquality() throws {
        let candidates = try ["1.0", "1.0.0-1"].map { try NativeSpec(data: ["name": "Kit", "version": $0]) }
        let request = try NativeDependency(["name": "Kit", "requirements": [">= 1.0.0-0"]])
        let resolution = try NativeResolver(candidates: { _ in candidates }).resolve([request])
        XCTAssertEqual(resolution.specs["Kit"]?.version.description, "1.0.0-1")
        let exact = try NativeDependency(["name": "Kit", "requirements": ["= 1.0.0-0"]])
        let selected = try NativeResolver(candidates: { _ in [candidates[0]] }).resolve([exact])
        XCTAssertEqual(selected.specs["Kit"]?.version.description, "1.0")
    }

    func testHyphensCannotReplaceTheFirstVersionComponentSeparator() throws {
        for value in ["1-a", "1--", "1-2"] { XCTAssertThrowsError(try PodVersion(value), value) }
        for value in ["1.0-a", "1.0--", "1.0.0-0", "1.0.0-alpha-beta+metadata"] {
            XCTAssertNoThrow(try PodVersion(value), value)
        }
    }
}
