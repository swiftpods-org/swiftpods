import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeDictionaryKeyBoundaryTests: XCTestCase {
    private let collision = #"{"CAF\u00c9":"first","CAFE\u0301":"second"}"#

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func rejected(_ operation: () throws -> Any, file: String? = nil) {
        XCTAssertThrowsError(try operation()) {
            let diagnostic = $0 as? Diagnostic
            XCTAssertEqual(diagnostic?.code, "SP-DATA-KEY")
            XCTAssertEqual(diagnostic?.file, file)
        }
    }

    func testJSONReadRejectsCanonicallyEquivalentKeysBeforeBridging() throws {
        let file = try directory().appendingPathComponent("input.json")
        try Data(collision.utf8).write(to: file)
        rejected({ try readObject(file) }, file: file.path)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), collision)
    }

    func testNestedJSONObjectsAndArraysCannotHideKeyCollisions() throws {
        let file = try directory().appendingPathComponent("input.json")
        for text in [#"{"outer": "# + collision + "}", #"{"array":[null,{"nested": "# + collision + "}]}"] {
            try Data(text.utf8).write(to: file)
            rejected({ try readObject(file) }, file: file.path)
        }
    }

    func testJSONSerializationDoesNotCollapseFoundationDictionaryKeys() throws {
        for text in [collision, #"{"floating":1.0,"nested": "# + collision + "}"] {
            let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
            for pretty in [true, false] { rejected { try NativeJSON.data(object, pretty: pretty) } }
        }
    }

    func testIndependentUnicodeKeysAndOriginalScalarSpellingsArePreserved() throws {
        let file = try directory().appendingPathComponent("input.json")
        for key in ["CAF\u{c9}", "CAFE\u{301}", "東京🧩"] {
            let original: [String: Any] = [key: 1.0, "distinct": ["東京": true, "🧩": "value"]]
            let data = try NativeJSON.data(original)
            try data.write(to: file)
            let object = try readObject(file)
            let retained = try XCTUnwrap(object.keys.first { $0 != "distinct" })
            XCTAssertEqual(Array(retained.unicodeScalars), Array(key.unicodeScalars))
            XCTAssertEqual(object.count, 2)
            XCTAssertTrue(NativeScalarString.isFloating(try XCTUnwrap(object[retained] as? NSNumber)))
        }
    }

    func testLockfileJSONCannotBypassYAMLKeyValidation() throws {
        rejected(
            { try NativeYAML.object(#"{"metadata": "# + collision + "}", file: "Podfile.lock") }, file: "Podfile.lock")
        XCTAssertThrowsError(try NativeYAML.object("'CAFÉ': first\n'CAFE\u{301}': second\n"))
    }

    func testPodspecProjectionRejectsCollisionBeforeCreatingCacheEntries() throws {
        let root = try directory()
        let cache = root.appendingPathComponent("cache")
        let content = Data(
            (#"{"name":"Kit","version":"1.0","scheme":{"environment_variables": "# + collision + "}}").utf8)
        rejected { try NativePodspecCache(cache: cache).project(content) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }

    func testExistingPBXGraphRejectsCollisionWithoutRewritingProject() throws {
        let file = try directory().appendingPathComponent("project.pbxproj")
        let data = Data((#"{"objects":{},"attributes": "# + collision + "}").utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        let plist = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        try plist.write(to: file)
        rejected({ try NativePBX(file, existing: true) }, file: file.path)
        XCTAssertEqual(try Data(contentsOf: file), plist)
    }
}
