import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativePBXDocumentTests: XCTestCase {
    private let source = """
        // !$*UTF8*$!
        {
        \tarchiveVersion = 1;
        \tclasses = {};
        \tobjectVersion = 60;
        \tobjects = {

        /* Begin PBXFileReference section */
        \t\tSOURCE /* café 🧩 */ = {isa = PBXFileReference; path = "café.m"; sourceTree = "<group>"; };
        /* End PBXFileReference section */

        /* Begin PBXGroup section */
        \t\tGROUP /* Sources */ = {
        \t\t\tisa = PBXGroup;
        \t\t\tchildren = (
        \t\t\t\tSOURCE /* café 🧩 */,
        \t\t\t);
        \t\t\tsourceTree = "<group>";
        \t\t};
        /* End PBXGroup section */
        \t\tCONFIG = {isa = XCBuildConfiguration; buildSettings = {CUSTOM = "say \\"hi\\""; }; name = Debug; };
        \t\tPROJECT = {isa = PBXProject; mainGroup = GROUP /* Sources */; targets = (); };
        \t};
        \trootObject = PROJECT /* Project object */;
        }

        """

    private func graph(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: Any])
    }

    func testChangingObjectClassMovesItToTheMatchingSectionWithoutReformattingOtherObjects() throws {
        let before = """
            // !$*UTF8*$!
            { objects = {
            /* Begin PBXCopyFilesBuildPhase section */
            \tPHASE = {isa = PBXCopyFilesBuildPhase; files = (); };
            \tUSER /* keep this comment */ = {isa = PBXCopyFilesBuildPhase; files = (); };
            /* End PBXCopyFilesBuildPhase section */
            /* Begin PBXShellScriptBuildPhase section */
            \tSCRIPT = {isa = PBXShellScriptBuildPhase; shellScript = "echo existing"; };
            /* End PBXShellScriptBuildPhase section */
            }; }
            """
        var value = try graph(before)
        var objects = try XCTUnwrap(value["objects"] as? [String: [String: Any]])
        objects["PHASE"] = ["isa": "PBXShellScriptBuildPhase", "files": [], "shellScript": "echo generated"]
        value["objects"] = objects
        let after = try NativePBXDocument(before).updating(value)
        let begin = try XCTUnwrap(after.range(of: "/* Begin PBXShellScriptBuildPhase section */"))
        let phase = try XCTUnwrap(after.range(of: "PHASE ="))
        let end = try XCTUnwrap(after.range(of: "/* End PBXShellScriptBuildPhase section */"))
        XCTAssertLessThan(begin.upperBound, phase.lowerBound)
        XCTAssertLessThan(phase.upperBound, end.lowerBound)
        XCTAssertTrue(after.contains("USER /* keep this comment */ = {isa = PBXCopyFilesBuildPhase; files = (); };"))
        XCTAssertTrue(after.contains("SCRIPT = {isa = PBXShellScriptBuildPhase; shellScript = \"echo existing\"; };"))
        XCTAssertEqual(NativePBX.serialize(try graph(after)), NativePBX.serialize(value))
        XCTAssertEqual(try NativePBXDocument(after).updating(value), after)
    }

    private func edit(_ mutate: (inout [String: [String: Any]]) -> Void) throws -> String {
        var root = try graph(source)
        var objects = try XCTUnwrap(root["objects"] as? [String: [String: Any]])
        mutate(&objects)
        root["objects"] = objects
        let result = try NativePBXDocument(source).updating(root)
        XCTAssertEqual(NativePBX.serialize(try graph(result)), NativePBX.serialize(root))
        return result
    }

    func testNoOpPreservesEveryByteIncludingCommentsAndInlineObjects() throws {
        XCTAssertEqual(try NativePBXDocument(source).updating(graph(source)), source)
    }

    func testSingleBuildSettingEditDoesNotReformatAnyOtherText() throws {
        let result = try edit { $0["CONFIG"]?["name"] = "Release" }
        XCTAssertEqual(result, source.replacingOccurrences(of: "name = Debug", with: "name = Release"))
    }

    func testNewReferencesStayInTheirSectionAndKeepExistingComments() throws {
        let result = try edit {
            $0["NEW"] = ["isa": "PBXFileReference", "path": "Pods/Kit.framework", "sourceTree": "SOURCE_ROOT"]
            $0["GROUP"]?["children"] = ["SOURCE", "NEW"]
        }
        XCTAssertTrue(result.contains("SOURCE /* café 🧩 */ = {isa = PBXFileReference;"))
        XCTAssertTrue(result.contains("SOURCE /* café 🧩 */,"))
        let new = try XCTUnwrap(result.range(of: "NEW = {"))
        let end = try XCTUnwrap(result.range(of: "/* End PBXFileReference section */"))
        XCTAssertLessThan(new.lowerBound, end.lowerBound)
    }

    func testRemovingAndReorderingArrayItemsRetainsTheirComments() throws {
        let text = "{items = (FIRST /* first */, SECOND /* second */, THIRD /* third */,); untouched = YES;}"
        let result = try NativePBXDocument(text).updating(["items": ["THIRD", "FIRST"], "untouched": "YES"])
        XCTAssertEqual(result, "{items = ( THIRD /* third */,FIRST /* first */,); untouched = YES;}")
        XCTAssertEqual((try graph(result))["items"] as? [String], ["THIRD", "FIRST"])
    }

    func testDeletingObjectsAndAddingInlineFieldsPreservesTheRemainingGraph() throws {
        let result = try edit {
            $0.removeValue(forKey: "SOURCE")
            $0["GROUP"]?["children"] = []
            $0["PROJECT"]?["newField"] = "$(SRCROOT)/spaces and $dollars"
        }
        XCTAssertFalse(result.contains("SOURCE /* café 🧩 */"))
        XCTAssertTrue(result.contains("/* Begin PBXFileReference section */"))
        XCTAssertTrue(result.contains("mainGroup = GROUP /* Sources */; targets = ();"))
    }

    func testScalarContainersEmptyArraysAndRepeatedValuesRoundTrip() throws {
        let text = #"{values = (); repeated = (A /* one */, A /* two */,); nested = {"escaped\"key" = old; };}"#
        let value: [String: Any] = [
            "values": ["a b", "a//b", "a/*b", "🧩", "line\nnext", "$(PODS_ROOT)"],
            "repeated": ["A", "A", "A"], "nested": ["escaped\"key": "new"],
        ]
        let result = try NativePBXDocument(text).updating(value)
        XCTAssertEqual(NativePBX.serialize(try graph(result)), NativePBX.serialize(value))
        XCTAssertTrue(result.contains("A /* one */, A /* two */,"))
    }

    func testNativePBXSavesKeepLayoutAcrossRepeatedEditsAndRejectConcurrentChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("project.pbxproj")
        try Data(source.utf8).write(to: file)
        let project = try NativePBX(file, existing: true)
        try project.save()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source)
        project.objects["CONFIG"]?["name"] = "Release"
        try project.save()
        let expected = source.replacingOccurrences(of: "name = Debug", with: "name = Release")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), expected)
        try project.save()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), expected)
        try Data((expected + "// outside edit\n").utf8).write(to: file)
        XCTAssertThrowsError(try project.save()) { XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-XCODE-CONFLICT") }
    }

    func testNewObjectClassesShareOneSectionAndKeepCRLFLineEndings() throws {
        let text = source.replacingOccurrences(of: "\n", with: "\r\n")
        var root = try graph(text)
        var objects = try XCTUnwrap(root["objects"] as? [String: [String: Any]])
        for id in ["PACKAGE_A", "PACKAGE_B"] {
            objects[id] = ["isa": "XCRemoteSwiftPackageReference", "repositoryURL": "https://example.com/\(id).git"]
        }
        root["objects"] = objects
        let result = try NativePBXDocument(text).updating(root)
        XCTAssertEqual(NativePBX.serialize(try graph(result)), NativePBX.serialize(root))
        XCTAssertEqual(result.components(separatedBy: "/* Begin XCRemoteSwiftPackageReference section */").count, 2)
        XCTAssertFalse(result.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    func testRemovingTheLastObjectInASectionWhileAddingItsReplacementKeepsValidSyntax() throws {
        let result = try edit {
            $0.removeValue(forKey: "SOURCE")
            $0["NEW"] = ["isa": "PBXFileReference", "path": "New.m", "sourceTree": "SOURCE_ROOT"]
            $0["GROUP"]?["children"] = ["NEW"]
        }
        XCTAssertFalse(result.contains("SOURCE /* café 🧩 */"))
        XCTAssertTrue(result.contains("/* End PBXFileReference section */"))
    }
}
