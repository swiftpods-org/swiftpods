import XCTest

@testable import SwiftPodsCore

final class NativeSwiftPackageDeclarationTests: XCTestCase {
    private func declaration(_ changes: [String: Any] = [:]) -> [String: Any] {
        ["name": "Net", "git": "https://example.invalid/Net.git", "exact": "1.0.0", "products": ["Net"]]
            .merging(changes) { _, new in new }
    }

    private func graph() throws -> NativePBX {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let graph = try NativePBX(root.appendingPathComponent("App.xcodeproj/project.pbxproj"))
        graph.root = ["rootObject": "ROOT"]
        graph.objects = [
            "ROOT": ["isa": "PBXProject", "packageReferences": []],
            "APP": ["isa": "PBXNativeTarget", "packageProductDependencies": [], "buildPhases": ["LINK"]],
            "LINK": ["isa": "PBXFrameworksBuildPhase", "files": []],
        ]
        return graph
    }

    func testRequirementsRejectNonStringSelectors() {
        for key in ["exact", "from", "branch", "revision"] {
            for value: Any in [true, 1, 1.0, [], ["1.0.0"]] {
                var data = declaration()
                data.removeValue(forKey: "exact")
                data[key] = value
                XCTAssertThrowsError(try NativeSwiftPackageDeclaration(data), "\(key): \(value)")
            }
        }
    }

    func testProductsRejectUnsupportedElementsAndKeepStringShorthand() throws {
        for value: Any in [42, true, [42], ["Net", 42], [""], [NSNull()]] {
            XCTAssertThrowsError(try NativeSwiftPackageDeclaration(declaration(["products": value])))
        }
        XCTAssertEqual(try NativeSwiftPackageDeclaration(declaration(["products": "Net"])).products, ["Net"])
        XCTAssertEqual(
            try NativeSwiftPackageDeclaration(declaration(["products": ["Net", "Utilities"]])).products,
            ["Net", "Utilities"])
    }

    func testUnknownOptionsAndEmptyNamesAreDiagnosed() {
        for changes: [String: Any] in [
            ["frobnicate": true], ["git": ""], ["git": false], ["name": NSNull()], ["name": " "],
            ["branch": "main"], ["exact": "1.0.0\n"], ["products": ["Net\u{0000}"]],
        ] {
            XCTAssertThrowsError(try NativeSwiftPackageDeclaration(declaration(changes)))
        }
    }

    func testLinkOptionRequiresABooleanAndDefaultsToLinking() throws {
        XCTAssertTrue(try NativeSwiftPackageDeclaration(declaration()).link)
        XCTAssertTrue(try NativeSwiftPackageDeclaration(declaration(["link": true])).link)
        XCTAssertFalse(try NativeSwiftPackageDeclaration(declaration(["link": false])).link)
        for value: Any in [NSNull(), "false", 0, 1, [], [:]] {
            XCTAssertThrowsError(try NativeSwiftPackageDeclaration(declaration(["link": value])))
        }
    }

    func testBuildOnlyPackagesSurviveReinstallAndCanSwitchToLinkingOrBeRemoved() throws {
        let user = try graph()
        user.objects["APP"]?["dependencies"] = ["USER_DEPENDENCY"]
        user.objects["USER_DEPENDENCY"] = ["isa": "PBXTargetDependency", "target": "OTHER"]
        var record: [String: Any]?
        for _ in 0..<2 {
            let integrator = NativeSwiftPackageIntegrator()
            try integrator.prepare(user, record: record)
            try integrator.integrate([declaration(["link": false])], targetID: "APP", user: user)
            record = integrator.finish(user)
            let dependencies = try XCTUnwrap(user.objects["APP"]?["dependencies"] as? [String])
            XCTAssertEqual(dependencies.count, 2)
            let dependency = try XCTUnwrap(dependencies.first { $0 != "USER_DEPENDENCY" })
            let product = try XCTUnwrap(user.objects[dependency]?["productRef"] as? String)
            XCTAssertEqual(user.objects[product]?["productName"] as? String, "Net")
            XCTAssertEqual(user.objects["APP"]?["packageProductDependencies"] as? [String], [])
            XCTAssertEqual(user.objects["LINK"]?["files"] as? [String], [])
        }
        let linked = NativeSwiftPackageIntegrator()
        try linked.prepare(user, record: record)
        try linked.integrate([declaration()], targetID: "APP", user: user)
        record = linked.finish(user)
        XCTAssertEqual(user.objects["APP"]?["dependencies"] as? [String], ["USER_DEPENDENCY"])
        XCTAssertEqual((user.objects["LINK"]?["files"] as? [String])?.count, 1)
        let removed = NativeSwiftPackageIntegrator()
        try removed.prepare(user, record: record)
        _ = removed.finish(user)
        XCTAssertEqual(user.objects["APP"]?["dependencies"] as? [String], ["USER_DEPENDENCY"])
        XCTAssertEqual(user.objects["LINK"]?["files"] as? [String], [])
        XCTAssertEqual(user.objects["ROOT"]?["packageReferences"] as? [String], [])
    }

    func testRemovingBuildOnlyDependencyPreservesAUserAttachment() throws {
        let user = try graph()
        let integrator = NativeSwiftPackageIntegrator()
        try integrator.prepare(user, record: nil)
        try integrator.integrate([declaration(["link": false])], targetID: "APP", user: user)
        let record = integrator.finish(user)
        let dependencies = try XCTUnwrap(user.objects["APP"]?["dependencies"] as? [String])
        user.objects["OTHER"] = ["isa": "PBXNativeTarget", "dependencies": dependencies]
        let removal = NativeSwiftPackageIntegrator()
        try removal.prepare(user, record: record)
        _ = removal.finish(user)
        XCTAssertEqual(user.objects["APP"]?["dependencies"] as? [String], [])
        XCTAssertEqual(user.objects["OTHER"]?["dependencies"] as? [String], dependencies)
        XCTAssertNotNil(user.objects[dependencies[0]])
    }

    func testBuildOnlyDependencyWithoutAnOwnershipRecordCanBeRemoved() throws {
        let user = try graph()
        let integrator = NativeSwiftPackageIntegrator()
        try integrator.prepare(user, record: nil)
        try integrator.integrate([declaration(["link": false])], targetID: "APP", user: user)
        _ = integrator.finish(user)
        let removal = NativeSwiftPackageIntegrator()
        try removal.prepare(user, record: nil)
        _ = removal.finish(user)
        XCTAssertEqual(user.objects["APP"]?["dependencies"] as? [String], [])
        XCTAssertEqual(user.objects["ROOT"]?["packageReferences"] as? [String], [])
        XCTAssertFalse(user.objects.values.contains { $0["isa"] as? String == "XCSwiftPackageProductDependency" })
    }

    func testRequirementFormsPreserveTheirDeclaredStrings() throws {
        let cases: [(String, Any, [String: String])] = [
            ("exact", "01.0.0", ["kind": "exactVersion", "version": "01.0.0"]),
            (
                "from", "1.2.3-alpha.01+build",
                ["kind": "upToNextMajorVersion", "minimumVersion": "1.2.3-alpha.01+build"]
            ),
            ("branch", "feature/net", ["kind": "branch", "branch": "feature/net"]),
            ("revision", "HEAD~1", ["kind": "revision", "revision": "HEAD~1"]),
            (
                "range", ["1.0.0", "2.0.0"],
                ["kind": "versionRange", "minimumVersion": "1.0.0", "maximumVersion": "2.0.0"]
            ),
        ]
        for (key, value, expected) in cases {
            var data = declaration()
            data.removeValue(forKey: "exact")
            data[key] = value
            XCTAssertEqual(try NativeSwiftPackageDeclaration(data).requirement, expected)
        }
        let selected = try NativeSwiftPackageDeclaration(declaration(["exact": NSNull(), "branch": "main"]))
        XCTAssertEqual(selected.requirement, ["kind": "branch", "branch": "main"])
    }

    func testVersionParsingMatchesPackageDescriptionControls() {
        for value in [
            "1.0.0", "01.0.0", "1.0.0-alpha.01", "1.0.0+build.01", "1.0.0-", "1.0.0+", "1.0.0-alpha..beta",
            "1.0.0--alpha",
        ] {
            XCTAssertNotNil(NativeSwiftPackageVersion(value), value)
        }
        for value in [
            "1.0", "9223372036854775808.0.0", "1.0.0-alpha_1", "1.0.0-α", "1.0.0.0", " 1.0.0", "1.0.0 ", "-1.0.0",
        ] {
            XCTAssertNil(NativeSwiftPackageVersion(value), value)
        }
    }

    func testVersionOrderingMatchesPackageDescriptionControls() throws {
        let cases: [(String, String, Int)] = [
            ("1.0.0+a", "1.0.0+b", 0), ("1.0.0-alpha.01", "1.0.0-alpha.1", 0),
            ("1.0.0-", "1.0.0", -1), ("1.0.0-alpha.2", "1.0.0-alpha.10", -1),
            ("1.0.0-alpha.9223372036854775808", "1.0.0-alpha.9223372036854775807", 1),
            ("1.0.0-alpha.99999999999999999999", "1.0.0-alpha.100000000000000000000", 1),
        ]
        for (left, right, expected) in cases {
            let a = try XCTUnwrap(NativeSwiftPackageVersion(left))
            let b = try XCTUnwrap(NativeSwiftPackageVersion(right))
            XCTAssertEqual(a == b ? 0 : (a < b ? -1 : 1), expected)
        }
    }

    func testRangesRejectInvalidOrNonIncreasingBounds() {
        for value: Any in [
            "1.0.0", ["1.0.0"], ["1.0.0", "2.0.0", "3.0.0"], ["2.0.0", "1.0.0"],
            ["1.0.0", "1.0.0"], ["1.0.0+a", "1.0.0+b"], ["1.0", "2.0.0"], [1, 2],
        ] {
            var data = declaration()
            data.removeValue(forKey: "exact")
            data["range"] = value
            XCTAssertThrowsError(try NativeSwiftPackageDeclaration(data))
        }
        var data = declaration()
        data.removeValue(forKey: "exact")
        data["from"] = String(Int.max) + ".0.0"
        XCTAssertThrowsError(try NativeSwiftPackageDeclaration(data))
    }

    func testManifestValidatesPackagesBeforeReadingProjectsOrRunningHooks() {
        for value: Any in [42, [42], [declaration(["products": [42]])], [declaration(["exact": true])]] {
            let manifest: [String: Any] = [
                "targets": [["name": "App", "project": "missing.xcodeproj", "packages": value]]
            ]
            XCTAssertThrowsError(
                try NativeManifest.analyze(manifest, project: URL(fileURLWithPath: "/missing"), integrate: true)
            ) { error in
                XCTAssertTrue((error as? Diagnostic)?.code.hasPrefix("SP-SPM-") == true)
            }
        }
    }

    func testPackageOnlyDeclarationsRemainAttachedUntilRemoved() throws {
        let user = try graph()
        let integrator = NativeSwiftPackageIntegrator()
        var data = declaration()
        data.removeValue(forKey: "products")
        var record: [String: Any]?
        for version in ["1.0.0", "2.0.0"] {
            data["exact"] = version
            try integrator.prepare(user, record: record)
            try integrator.integrate([data], targetID: "APP", user: user)
            record = integrator.finish(user)
            XCTAssertEqual((user.objects["ROOT"]?["packageReferences"] as? [String])?.count, 1)
            let package = try XCTUnwrap(
                user.objects.values.first { $0["isa"] as? String == "XCRemoteSwiftPackageReference" })
            XCTAssertEqual((package["requirement"] as? [String: String])?["version"], version)
            XCTAssertEqual(user.objects["APP"]?["packageProductDependencies"] as? [String], [])
        }
        try integrator.prepare(user, record: record)
        _ = integrator.finish(user)
        XCTAssertEqual(user.objects["ROOT"]?["packageReferences"] as? [String], [])
    }

    func testInvalidSecondDeclarationLeavesProjectObjectsUnchanged() throws {
        let user = try graph()
        let before = try jsonData(user.objects)
        let integrator = NativeSwiftPackageIntegrator()
        try integrator.prepare(user, record: nil)
        XCTAssertThrowsError(
            try integrator.integrate(
                [declaration(), declaration(["products": [42]])], targetID: "APP", user: user))
        XCTAssertEqual(try jsonData(user.objects), before)
    }

    func testPackageOwnershipSurvivesSavedHookScalarSettings() throws {
        let user = try graph()
        let settings: [String: Any] = [
            "COMPILER_FLAGS": NSNull(), "BOOL": true, "FALSE": false, "INTEGER": 42,
            "FLOAT": NSNumber(value: 1.0), "ARRAY": [NSNull(), false, true, 42, NSNumber(value: 1.0)],
        ]
        user.objects["BUILD"] = ["isa": "PBXBuildFile", "settings": settings]
        let record: [String: Any] = ["objects": ["BUILD": user.objects["BUILD"]!]]
        try user.save()
        let reopened = try NativePBX(user.url, existing: true)
        let saved = try XCTUnwrap(reopened.objects["BUILD"]?["settings"] as? [String: Any])
        XCTAssertEqual(saved["COMPILER_FLAGS"] as? String, "")
        XCTAssertEqual(saved["ARRAY"] as? [String], ["", "false", "true", "42", "1.0"])
        XCTAssertNoThrow(try NativeSwiftPackageIntegrator.validate(reopened, record: record))
    }

    func testPackageOwnershipStillRejectsExternalEditsAfterScalarSerialization() throws {
        let user = try graph()
        user.objects["BUILD"] = ["isa": "PBXBuildFile", "settings": ["COMPILER_FLAGS": NSNull()]]
        let record: [String: Any] = ["objects": ["BUILD": user.objects["BUILD"]!]]
        try user.save()
        let reopened = try NativePBX(user.url, existing: true)
        reopened.objects["BUILD"]?["settings"] = ["COMPILER_FLAGS": "-DCHANGED=1"]
        XCTAssertThrowsError(try NativeSwiftPackageIntegrator.validate(reopened, record: record)) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-SPM-CONFLICT")
        }
    }

    func testPackageOwnershipKeepsScalarSpellingAndContainerDifferencesSignificant() throws {
        let user = try graph()
        let cases: [(Any, Any)] = [(false, "0"), (true, "1"), (NSNumber(value: 1.0), "1"), (["a", "b"], "a b")]
        for (before, current) in cases {
            let object: [String: Any] = ["isa": "PBXBuildFile", "settings": ["VALUE": before]]
            let record: [String: Any] = ["objects": ["BUILD": object]]
            user.objects["BUILD"] = ["isa": "PBXBuildFile", "settings": ["VALUE": current]]
            XCTAssertThrowsError(try NativeSwiftPackageIntegrator.validate(user, record: record)) {
                XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-SPM-CONFLICT")
            }
        }
    }
}
