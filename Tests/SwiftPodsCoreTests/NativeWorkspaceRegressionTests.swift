import Foundation
import XCTest

@testable import SwiftPodsCore

#if canImport(FoundationXML)
    import FoundationXML
#endif

final class NativeWorkspaceRegressionTests: XCTestCase {
    func testUnchangedXcodeWorkspaceKeepsItsOriginalBytesAndOwnership() throws {
        let path = try workspace(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <Workspace
               version = "1.0">
               <!-- User formatting must survive installation. -->
               <FileRef
                  location = "group:App.xcodeproj">
               </FileRef>
               <FileRef
                  location = "group:Pods/Pods.xcodeproj">
               </FileRef>
            </Workspace>

            """)
        let original = try Data(contentsOf: path)
        let references = ["group:App.xcodeproj", "group:Pods/Pods.xcodeproj"]
        for previous in [[], ["group:Pods/Pods.xcodeproj"]] {
            let owned = try NativeWorkspace.update(path, references: references, previous: previous)
            XCTAssertEqual(owned, previous)
            XCTAssertEqual(try Data(contentsOf: path), original)
        }
    }

    func testUnchangedUTF16WorkspaceKeepsItsEncodingAndBytes() throws {
        let path = try workspace("<Workspace version=\"1.0\"/>")
        let input =
            "<?xml version=\"1.0\" encoding=\"UTF-16\"?><Workspace version=\"1.0\"><FileRef location=\"group:App.xcodeproj\"/></Workspace>"
        let original = try XCTUnwrap(input.data(using: .utf16))
        try original.write(to: path)
        _ = try NativeWorkspace.update(path, references: ["group:App.xcodeproj"], previous: [])
        XCTAssertEqual(try Data(contentsOf: path), original)
    }

    func testLocationSeparatorsRemainBoundariesBeforeCombiningMarks() throws {
        let path = try workspace("<Workspace version=\"1.0\"/>")
        let references = ["group:\u{301}One.xcodeproj", "container:\u{301}Two.xcodeproj"]
        var owned = try NativeWorkspace.update(path, references: references, previous: [])
        for _ in 0..<2 {
            let document = try XMLDocument(contentsOf: path)
            XCTAssertEqual(
                Set(try document.nodes(forXPath: "//FileRef/@location").compactMap(\.stringValue)), Set(references))
            owned = try NativeWorkspace.update(path, references: references, previous: owned)
        }
        _ = try NativeWorkspace.update(path, references: [], previous: owned)
        XCTAssertTrue(try XMLDocument(contentsOf: path).nodes(forXPath: "//FileRef").isEmpty)
    }

    func testWorkspacePreparationDoesNotWriteAndRejectsChangesBeforeSaving() throws {
        let path = try workspace("<Workspace version=\"1.0\"/>")
        let before = try Data(contentsOf: path)
        let update = try NativeWorkspace.prepare(path, references: ["group:Pods/Pods.xcodeproj"], previous: [])
        XCTAssertEqual(try Data(contentsOf: path), before)
        let edited = Data("<Workspace version=\"1.0\"><FileRef location=\"group:User.xcodeproj\"/></Workspace>".utf8)
        try edited.write(to: path)
        XCTAssertThrowsError(try update.save()) {
            XCTAssertEqual(($0 as? Diagnostic)?.code, "SP-WORKSPACE-CONFLICT")
        }
        XCTAssertEqual(try Data(contentsOf: path), edited)
    }

    func testPreparingNewWorkspaceDoesNotCreateFiles() throws {
        let old = try workspace("<Workspace version=\"1.0\"/>")
        let path = old.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("New.xcworkspace/contents.xcworkspacedata")
        let update = try NativeWorkspace.prepare(path, references: ["group:Pods/Pods.xcodeproj"], previous: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.deletingLastPathComponent().path))
        try update.save()
        XCTAssertEqual(update.owned, ["group:Pods/Pods.xcodeproj"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    private func workspace(_ contents: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = root.appendingPathComponent("Demo.xcworkspace/contents.xcworkspacedata")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: path)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return path
    }

    func testManagedReferencesPreserveXMLWhitespaceAndLiteralEntities() throws {
        let references = [
            "group:Tab\tName.xcodeproj", "group:Line\nName.xcodeproj", "group:CR\rName.xcodeproj",
            "group:Pair\r\nName.xcodeproj", "group:Literal &#9; & \"東京\".xcodeproj",
        ]
        let path = try workspace("<Workspace version=\"1.0\"/>")
        var owned = try NativeWorkspace.update(path, references: references, previous: [])
        for _ in 0..<2 {
            let document = try XMLDocument(contentsOf: path)
            XCTAssertEqual(
                Set(try document.nodes(forXPath: "//FileRef/@location").compactMap(\.stringValue)), Set(references))
            XCTAssertEqual(try document.nodes(forXPath: "//FileRef").count, references.count)
            owned = try NativeWorkspace.update(path, references: references, previous: owned)
        }
        _ = try NativeWorkspace.update(path, references: [], previous: owned)
        XCTAssertTrue(try XMLDocument(contentsOf: path).nodes(forXPath: "//FileRef").isEmpty)
    }

    func testExistingUserAttributesCommentsAndCDATAKeepTheirValues() throws {
        let path = try workspace(
            """
            <!DOCTYPE Workspace [<!ENTITY fixture "<Fake attr='DTD&#9;text'/>">]>
            <Workspace version="1.0" custom="before&#9;after&#10;end&#13;finish">
              <!-- <FileRef location="comment&#9;literal"/> "comment\ttext" -->
              <?fixture keep="instruction\ttext"?>
              <Group location="group:Sub&#9;Folder" name="Group&#10;Name">
                <FileRef location="group:User&#13;Name.xcodeproj" custom="literal &amp;#9; &quot; &apos; &lt; &gt;"/>
                <Text><![CDATA[<FileRef location="cdata\ttext"/>]]></Text>
              </Group>
            </Workspace>
            """)
        let original = try XMLDocument(contentsOf: path)
        let owned = try NativeWorkspace.update(path, references: ["group:Pods/Pods.xcodeproj"], previous: [])
        _ = try NativeWorkspace.update(path, references: [], previous: owned)
        let current = try XMLDocument(contentsOf: path)
        XCTAssertEqual(current.dtd?.xmlString, original.dtd?.xmlString)
        for query in ["//@*", "//comment()", "//processing-instruction()", "//Text/text()"] {
            XCTAssertEqual(
                try current.nodes(forXPath: query).map(\.stringValue),
                try original.nodes(forXPath: query).map(\.stringValue), query)
        }
    }

    func testExistingUTF16WorkspaceIsSavedWithConsistentEncoding() throws {
        let path = try workspace("<Workspace version=\"1.0\"/>")
        let input =
            "<?xml version=\"1.0\" encoding=\"UTF-16\"?><Workspace name=\"東京\"><FileRef location=\"group:Before&#9;After.xcodeproj\"/></Workspace>"
        try XCTUnwrap(input.data(using: .utf16)).write(to: path)
        _ = try NativeWorkspace.update(path, references: ["group:Pods/Pods.xcodeproj"], previous: [])
        let saved = try XMLDocument(contentsOf: path)
        XCTAssertEqual(saved.rootElement()?.attribute(forName: "name")?.stringValue, "東京")
        XCTAssertEqual(
            try saved.nodes(forXPath: "//FileRef/@location").compactMap(\.stringValue),
            ["group:Before\tAfter.xcodeproj", "group:Pods/Pods.xcodeproj"])
    }

    func testWhitespaceDistinctPathsRemainDistinctAcrossReinstalls() throws {
        let references = ["group:Same Name.xcodeproj", "group:Same\tName.xcodeproj", "group:Same\nName.xcodeproj"]
        let path = try workspace(
            "<Workspace version=\"1.0\"><FileRef location=\"group:Same Name.xcodeproj\"/></Workspace>")
        let owned = try NativeWorkspace.update(path, references: references, previous: [])
        XCTAssertEqual(Set(owned), Set(references.dropFirst()))
        let next = try NativeWorkspace.update(path, references: references, previous: owned)
        XCTAssertEqual(Set(next), Set(owned))
        XCTAssertEqual(try XMLDocument(contentsOf: path).nodes(forXPath: "//FileRef").count, 3)
        _ = try NativeWorkspace.update(path, references: [], previous: next)
        XCTAssertEqual(
            try XMLDocument(contentsOf: path).nodes(forXPath: "//FileRef/@location").compactMap(\.stringValue),
            [references[0]])
    }

    func testLegacyOwnershipNeverClaimsNestedUserReferences() throws {
        let reference = "group:Pods/Pods.xcodeproj"
        let path = try workspace(
            """
            <Workspace version="1.0">
              <FileRef location="group:Pods/Pods.xcodeproj"/>
              <Group location="group:Sub" name="User projects">
                <FileRef location="group:Pods/Pods.xcodeproj"/>
                <FileRef location="group:Unrelated.xcodeproj"/>
              </Group>
            </Workspace>
            """)
        let owned = try NativeWorkspace.update(path, references: [reference], previous: [reference])
        XCTAssertEqual(owned, [reference])
        _ = try NativeWorkspace.update(path, references: [], previous: owned)
        let document = try XMLDocument(contentsOf: path)
        XCTAssertEqual(try document.nodes(forXPath: "/Workspace/FileRef").count, 0)
        XCTAssertEqual(
            try document.nodes(forXPath: "/Workspace/Group/FileRef/@location").compactMap(\.stringValue),
            [reference, "group:Unrelated.xcodeproj"])
    }

    func testExistingReferencesResolveAllParentGroupsAndContainerLocations() throws {
        let path = try workspace(
            """
            <Workspace version="1.0">
              <Group location="group:Sub">
                <Group location="group:Deeper">
                  <FileRef location="group:../../Pods/Pods.xcodeproj"/>
                  <FileRef location="container:App.xcodeproj"/>
                </Group>
              </Group>
            </Workspace>
            """)
        XCTAssertTrue(
            try NativeWorkspace.update(
                path, references: ["group:Pods/Pods.xcodeproj", "group:App.xcodeproj"], previous: []
            ).isEmpty)
        XCTAssertEqual(try XMLDocument(contentsOf: path).nodes(forXPath: "//FileRef").count, 2)
        _ = try NativeWorkspace.update(path, references: [], previous: [])
        XCTAssertEqual(try XMLDocument(contentsOf: path).nodes(forXPath: "//FileRef").count, 2)
    }

    func testNestedReferenceToAnotherProjectDoesNotSuppressManagedReference() throws {
        let reference = "group:Pods/Pods.xcodeproj"
        let path = try workspace(
            """
            <Workspace version="1.0"><Group location="group:Sub">
              <FileRef location="group:Pods/Pods.xcodeproj"/>
            </Group></Workspace>
            """)
        let owned = try NativeWorkspace.update(path, references: [reference], previous: [])
        XCTAssertEqual(owned, [reference])
        XCTAssertEqual(try XMLDocument(contentsOf: path).nodes(forXPath: "//FileRef").count, 2)
        _ = try NativeWorkspace.update(path, references: [], previous: owned)
        XCTAssertEqual(try XMLDocument(contentsOf: path).nodes(forXPath: "/Workspace/Group/FileRef").count, 1)
    }

    func testLegacyReceiptRemovesOnlyOneDirectReference() throws {
        let reference = "group:Pods/Pods.xcodeproj"
        let path = try workspace(
            """
            <Workspace version="1.0">
              <FileRef location="group:Pods/Pods.xcodeproj"/>
              <FileRef location="group:Pods/Pods.xcodeproj"/>
            </Workspace>
            """)
        _ = try NativeWorkspace.update(path, references: [], previous: [reference])
        XCTAssertEqual(try XMLDocument(contentsOf: path).nodes(forXPath: "/Workspace/FileRef").count, 1)
    }
}
