import XCTest
@testable import SwiftPodsCore

final class NativeVendorTests: XCTestCase {
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: path) }
        return path
    }
    private func macho(platform: UInt32, cpu: UInt32 = 0x0100000c, subtype: UInt32 = 0, kind: UInt32 = 6) -> Data {
        let words: [UInt32] = [0xfeedfacf, cpu, subtype, kind, 1, 24, 0, 0, 0x32, 24, platform, 0x000f0000, 0x001b0000, 0]
        return Data(words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } })
    }
    private func plist(_ value: [String: Any], at path: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: path)
    }
    private func xcframework(_ root: URL, entries: [[String: Any]]) throws -> URL {
        let sdk = root.appendingPathComponent("Kit.xcframework")
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        for entry in entries {
            let identifier = entry["LibraryIdentifier"] as! String
            guard !identifier.contains("..") else { continue }
            let payload = sdk.appendingPathComponent(identifier + "/Kit.framework")
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
            let variant = entry["SupportedPlatformVariant"] as? String
            try macho(platform: variant == "simulator" ? 7 : 2).write(to: payload.appendingPathComponent("Kit"))
        }
        try plist(["XCFrameworkFormatVersion": "1.0", "AvailableLibraries": entries], at: sdk.appendingPathComponent("Info.plist"))
        return sdk
    }
    private func entry(_ id: String, variant: String? = nil) -> [String: Any] {
        var result: [String: Any] = ["LibraryIdentifier": id, "LibraryPath": "Kit.framework", "SupportedPlatform": "ios", "SupportedArchitectures": ["arm64"]]
        if let variant { result["SupportedPlatformVariant"] = variant }
        return result
    }
    func testArm64SelectionDistinguishesDeviceAndSimulator() throws {
        let path = try xcframework(directory(), entries: [entry("device"), entry("simulator", variant: "simulator")])
        let sdk = try NativeVendorSDK(path)
        XCTAssertEqual(try sdk.select(platform: "ios", variant: "device", architectures: ["arm64"]).identifier, "device")
        XCTAssertEqual(try sdk.select(platform: "ios", variant: "simulator", architectures: ["arm64"]).identifier, "simulator")
        XCTAssertThrowsError(try sdk.select(platform: "ios", variant: "maccatalyst", architectures: ["arm64"]))
        XCTAssertThrowsError(try sdk.select(platform: "ios", variant: "simulator", architectures: ["x86_64"]))
        XCTAssertThrowsError(try sdk.select(platform: "ios", variant: "device", architectures: []))
        XCTAssertTrue(sdk.dynamic)
        XCTAssertTrue(sdk.supports(platform: "ios"))
        XCTAssertFalse(sdk.supports(platform: "osx"))
    }
    func testMetadataMustMatchBinaryArchitectureAndPlatform() throws {
        let root = try directory()
        var metadata = entry("device")
        metadata["SupportedArchitectures"] = ["x86_64"]
        let path = try xcframework(root, entries: [metadata])
        XCTAssertThrowsError(try NativeVendorSDK(path))
        metadata["SupportedArchitectures"] = ["arm64"]
        metadata["SupportedPlatform"] = "macos"
        try plist(["XCFrameworkFormatVersion": "1.0", "AvailableLibraries": [metadata]], at: path.appendingPathComponent("Info.plist"))
        XCTAssertThrowsError(try NativeVendorSDK(path))
    }
    func testRejectsTraversalAndSymlinksOutsideSDK() throws {
        let root = try directory()
        let path = try xcframework(root, entries: [entry("device")])
        let payload = path.appendingPathComponent("device/Kit.framework/Kit")
        let outside = root.appendingPathComponent("outside")
        try macho(platform: 2).write(to: outside)
        try FileManager.default.removeItem(at: payload)
        try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: outside)
        XCTAssertThrowsError(try NativeVendorSDK(path))
        var metadata = entry("device")
        metadata["LibraryPath"] = "../../outside"
        try plist(["XCFrameworkFormatVersion": "1.0", "AvailableLibraries": [metadata]], at: path.appendingPathComponent("Info.plist"))
        XCTAssertThrowsError(try NativeVendorSDK(path))
    }
    func testRejectsOverlappingSlicesAndMixedLinkage() throws {
        let path = try xcframework(directory(), entries: [entry("first"), entry("second")])
        XCTAssertThrowsError(try NativeVendorSDK(path))
        let object = macho(platform: 2, kind: 1)
        // A BSD archive member wrapping a real Mach-O object header.
        let header = "object.o/".padding(toLength: 16, withPad: " ", startingAt: 0)
            + "0".padding(toLength: 12, withPad: " ", startingAt: 0)
            + "0".padding(toLength: 6, withPad: " ", startingAt: 0)
            + "0".padding(toLength: 6, withPad: " ", startingAt: 0)
            + "644".padding(toLength: 8, withPad: " ", startingAt: 0)
            + String(object.count).padding(toLength: 10, withPad: " ", startingAt: 0) + "`\n"
        try (Data("!<arch>\n".utf8) + Data(header.utf8) + object).write(to: path.appendingPathComponent("second/Kit.framework/Kit"))
        XCTAssertThrowsError(try NativeVendorSDK(path))
    }
    func testRawSDKAndHistoricalArchitectures() throws {
        let root = try directory()
        let library = root.appendingPathComponent("Kit.dylib")
        try macho(platform: 1).write(to: library)
        let sdk = try NativeVendorSDK(library)
        XCTAssertEqual(sdk.fileType, "compiled.mach-o.dylib")
        XCTAssertEqual(try sdk.select(platform: "osx", variant: "device", architectures: ["arm64"]).library, library)
        for (cpu, subtype, expected): (UInt32, UInt32, String) in [(12, 9, "armv7"), (12, 11, "armv7s"), (12, 12, "armv7k"), (0x0200000c, 0, "arm64_32")] {
            try macho(platform: 4, cpu: cpu, subtype: subtype).write(to: library)
            XCTAssertEqual(try BinaryInspection.inspect(library).first?.architecture, expected)
        }
        try Data("not a binary".utf8).write(to: library)
        XCTAssertThrowsError(try NativeVendorSDK(library))
    }
}
