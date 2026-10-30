import Foundation
import SwiftPodsKit
import SwiftPodsTestSupport
import XCTest

/// Builds an iOS app with Xcode after `swiftpods install`. Needs Xcode, an iOS SDK and network access
/// to GitHub, so it runs only with SWIFTPODS_E2E=1.
final class EndToEndTests: XCTestCase {
    func testXcodeBuildsTheIntegratedApp() throws {
        guard ProcessInfo.processInfo.environment["SWIFTPODS_E2E"] == "1" else {
            throw XCTSkip("Set SWIFTPODS_E2E=1 to build with Xcode")
        }
        let shell = ProcessRunner()
        let directory = try Fixtures.directory(
            podfile: """
                platform :ios, '15.0'

                group :common do
                  settings 'GENERATE_INFOPLIST_FILE' => 'YES', 'PRODUCT_BUNDLE_IDENTIFIER' => 'org.swiftpods.e2e',
                           'CODE_SIGNING_ALLOWED' => 'NO', 'SWIFT_VERSION' => '5.0', 'IPHONEOS_DEPLOYMENT_TARGET' => '15.0',
                           'ENABLE_USER_SCRIPT_SANDBOXING' => 'YES'
                end

                target 'App' do
                  use :common
                  spm 'https://github.com/apple/swift-collections.git', '~> 1.1', products: ['DequeModule']
                  binary 'Answer', path: 'Vendor/Answer.xcframework', linker_flags: ['-ObjC'], system_frameworks: ['Foundation']
                  script_phase name: 'Stamp', script: 'echo stamped > "$DERIVED_FILE_DIR/stamp.txt"',
                               output_files: ['$(DERIVED_FILE_DIR)/stamp.txt'], execution_position: :before_compile
                end
                """,
            files: [
                "main.swift": "import Answer\nimport DequeModule\n\nlet values: Deque = [Int(answer())]\nprint(values)\n",
                "AnswerSource/answer.c": "int answer(void) { return 42; }\n",
                "AnswerSource/include/Answer.h": "int answer(void);\n",
                "AnswerSource/include/module.modulemap": "module Answer {\n  header \"Answer.h\"\n  export *\n}\n",
            ])
        defer { try? FileManager.default.removeItem(at: directory) }

        // A real static-library xcframework for the simulator.
        let source = directory.appendingPathComponent("AnswerSource")
        _ = try shell.run("/usr/bin/xcrun", [
            "--sdk", "iphonesimulator", "clang", "-arch", "arm64", "-mios-simulator-version-min=15.0", "-c", "answer.c", "-o", "answer.o",
        ], in: source)
        _ = try shell.run("/usr/bin/xcrun", ["libtool", "-static", "-o", "libAnswer.a", "answer.o"], in: source)
        _ = try shell.run("/usr/bin/xcrun", [
            "xcodebuild", "-create-xcframework", "-library", "libAnswer.a", "-headers", "include",
            "-output", directory.appendingPathComponent("Vendor/Answer.xcframework").path,
        ], in: source)

        var options = InstallOptions()
        options.resolve = true
        let installer = Installer(directory: directory, cache: directory.appendingPathComponent(".cache"))
        _ = try installer.install(options)

        let derived = directory.appendingPathComponent("DerivedData")
        let log = try shell.run("/usr/bin/xcrun", [
            "xcodebuild", "build", "-project", "App.xcodeproj", "-scheme", "App",
            "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", derived.path, "ARCHS=arm64",
        ], in: directory)
        XCTAssertTrue(log.contains("** BUILD SUCCEEDED **"))
        let stamps = FileManager.default.enumerator(atPath: derived.path)?.compactMap { $0 as? String }.filter { $0.hasSuffix("/stamp.txt") }
        XCTAssertEqual(stamps?.count, 1, "The script phase ran")
        let app = derived.appendingPathComponent("Build/Products/Debug-iphonesimulator/App.app/App")
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
        let symbols = try shell.run("/usr/bin/xcrun", ["nm", "-gU", app.path], in: nil)
        XCTAssertTrue(symbols.contains("_answer"), "The binary SDK is linked")

        let again = try installer.install(InstallOptions())
        XCTAssertEqual(again.projects.flatMap(\.changes), [])
    }
}
