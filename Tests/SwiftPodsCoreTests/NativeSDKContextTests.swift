import Foundation
import XCTest

@testable import SwiftPodsCore

final class NativeSDKContextTests: XCTestCase {
    private func sdk(_ canonical: String = "macosx99.4") throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sdk")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        try metadata(canonical, path)
        return path
    }

    private func metadata(_ canonical: String, _ sdk: URL) throws {
        try JSONSerialization.data(withJSONObject: ["CanonicalName": canonical])
            .write(to: sdk.appendingPathComponent("SDKSettings.json"))
    }

    func testOneEvaluationReusesItsSymbolicLookup() throws {
        let sdk = try sdk()
        var calls: [String] = []
        let context = NativeSDKContext(locate: { value, _ in
            calls.append(value)
            return sdk
        })
        XCTAssertEqual(context.name("macosx"), "macosx99.4")
        XCTAssertEqual(context.name("macosx"), "macosx99.4")
        XCTAssertEqual(calls, ["macosx"])
    }

    func testDeveloperEnvironmentsCannotShareAnotherCommandsSDK() throws {
        let first = try sdk()
        let second = try sdk("macosx88.2")
        var observed: [String] = []
        let locate: NativeSDKContext.Locator = { _, environment in
            let developer = environment["DEVELOPER_DIR"] ?? ""
            observed.append(developer)
            return developer == "/Developer/First" ? first : second
        }
        let a = NativeSDKContext(environment: ["DEVELOPER_DIR": "/Developer/First"], locate: locate)
        let b = NativeSDKContext(environment: ["DEVELOPER_DIR": "/Developer/Second"], locate: locate)
        XCTAssertEqual(a.name("macosx"), "macosx99.4")
        XCTAssertEqual(b.name("macosx"), "macosx88.2")
        XCTAssertEqual(observed, ["/Developer/First", "/Developer/Second"])
    }

    func testFailedLookupsDoNotEscapeTheirEvaluationScope() throws {
        let sdk = try sdk()
        var calls = 0
        let missing = NativeSDKContext(locate: { _, _ in
            calls += 1
            return nil
        })
        XCTAssertEqual(missing.name("macosx"), "macosx")
        XCTAssertEqual(missing.name("macosx"), "macosx")
        let available = NativeSDKContext(locate: { _, _ in
            calls += 1
            return sdk
        })
        XCTAssertEqual(available.name("macosx"), "macosx99.4")
        XCTAssertEqual(calls, 2)
    }

    func testBundleMetadataRemainsFreshWithinTheSameContext() throws {
        let sdk = try sdk()
        var calls = 0
        let context = NativeSDKContext(locate: { _, _ in
            calls += 1
            return sdk
        })
        XCTAssertEqual(context.name("macosx"), "macosx99.4")
        try metadata("macosx88.2", sdk)
        XCTAssertEqual(context.name("macosx"), "macosx88.2")
        XCTAssertEqual(calls, 1)
    }

    func testAbsolutePathsDoNotInvokeTheSymbolicLocator() throws {
        let sdk = try sdk()
        let context = NativeSDKContext(locate: { _, _ in
            XCTFail("Absolute SDK did not need xcrun")
            return nil
        })
        XCTAssertEqual(context.name(sdk.path), "macosx99.4")
    }

    func testInvalidSymbolicNamesNeverReachTheTool() {
        let context = NativeSDKContext(locate: { _, _ in
            XCTFail("Invalid SDK reached xcrun")
            return nil
        })
        for value in ["--sdk", "-\u{301}sdk", "macosx\0tail", "$(SDK_ALIAS)", "\"macosx\"", "macosx\nother"] {
            _ = context.name(value)
        }
        XCTAssertFalse(
            NativeBuildSettings.conditions("VALUE[sdk=macosx*]", context: ["sdk": "macosx\0tail"], sdkContext: context)
                .1)
    }

    func testQuotedAbsoluteSDKDoesNotSelectItsLastComponent() {
        let context = NativeSDKContext(locate: { _, _ in
            XCTFail("Quoted SDK reached xcrun")
            return nil
        })
        for delimiter in ["\"", "\"\u{301}", "'\u{301}"] {
            let value = delimiter + "/SDKs/MacOSX.sdk" + delimiter
            XCTAssertEqual(context.name(value), "")
            XCTAssertFalse(
                NativeBuildSettings.conditions("VALUE[sdk=macosx*]", context: ["sdk": value], sdkContext: context).1)
        }
    }
}
