import Darwin
import Foundation
@testable import SwiftPodsKit
import SwiftPodsTestSupport
import XCTest

final class PackageOverrideTests: XCTestCase {
    private struct Runner: DescriptorWorkingDirectoryCommandRunner {
        let onResolve: @Sendable () throws -> Void
        private let process = ProcessRunner()

        func run(_ executable: String, _ arguments: [String], in directory: URL?) throws -> String {
            try process.run(executable, arguments, in: directory)
        }

        func runData(
            _ executable: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval,
            maximumOutputBytes: Int
        ) throws -> Data {
            try process.runData(executable, arguments, in: directory, timeout: timeout, maximumOutputBytes: maximumOutputBytes)
        }

        func runDescriptorBacked(
            _ executable: String, _ arguments: [String], workingDirectoryDescriptor: Int32, timeout: TimeInterval
        ) throws -> String {
            try onResolve()
            return ""
        }
    }

    private let git = ProcessRunner()
    private let origin = "https://example.com/OverrideKit.git"
    private let grammarOrigin = "https://example.com/Grammar.git"
    private let package = """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(
            name: "OverrideKit",
            products: [.library(name: "OverrideKit", targets: ["OverrideKit"])],
            targets: [.target(name: "OverrideKit")]
        )
        """
    private var workspaces: [URL] = []

    override func tearDown() {
        for directory in workspaces { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    private func fixture() throws -> URL {
        let directory = try Fixtures.directory(podfile: "target 'App' do\nend\n")
        workspaces.append(directory)
        return directory
    }

    private func command(_ arguments: [String], in repo: URL? = nil) throws -> String {
        try git.run("/usr/bin/git", [
            "-c", "user.name=SwiftPods Tests", "-c", "user.email=tests@example.com",
            "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
        ] + arguments, in: repo)
    }

    private func write(_ text: String, to location: URL) throws {
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: location)
    }

    private func repository(_ directory: URL, files: [String: String], sha256: Bool = false) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let objectFormat = sha256 ? ["--object-format=sha256"] : []
        _ = try command(["init", "--quiet", "--template=", "-b", "main"] + objectFormat, in: directory)
        for (path, text) in files { try write(text, to: directory.appendingPathComponent(path)) }
    }

    private func commit(_ repository: URL) throws -> String {
        _ = try command(["add", "--all"], in: repository)
        return try commitIndex(repository)
    }

    private func commitIndex(_ repository: URL) throws -> String {
        _ = try command(["commit", "--quiet", "-m", "Test fixture"], in: repository)
        return try command(["rev-parse", "HEAD"], in: repository).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cache(_ repository: URL, in directory: URL, origin: String, revision: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let cached = directory.appendingPathComponent(GitCatalog.pinnedTreeCacheName(url: origin, revision: revision))
        _ = try command(["clone", "--bare", "--quiet", "--no-local", "--template=", repository.path, cached.path])
        _ = try command(["remote", "set-url", "origin", origin], in: cached)
    }

    private func addSubmodule(
        to repository: URL, path: String, origin: String, revision: String
    ) throws -> String {
        try write(
            "[submodule \"fixture\"]\n\tpath = \(path)\n\turl = \(origin)\n\tbranch = main\n",
            to: repository.appendingPathComponent(".gitmodules"))
        _ = try command(["add", "--all"], in: repository)
        _ = try command(["update-index", "--add", "--cacheinfo", "160000,\(revision),\(path)"], in: repository)
        return try commitIndex(repository)
    }

    private func podfile(_ revision: String, submodules: Bool = false) -> String {
        """
        target 'App' do
          spm '\(origin)', revision: '\(revision)', override: true, submodules: \(submodules)
        end
        """
    }

    func testExactBareExportReadsRawBlobsAndChecksBudgets() throws {
        let directory = try fixture()
        let repository = directory.appendingPathComponent("source")
        try self.repository(
            repository, files: ["Package.swift": package, "Kept.txt": "raw\n",
                                ".gitattributes": "Kept.txt export-ignore\n"], sha256: true)
        let revision = try commit(repository)
        XCTAssertEqual(revision.count, 64)
        let cache = directory.appendingPathComponent("cache")
        let online = GitCatalog(cache: cache, runner: git, update: false, offline: false)
        var budget = GitPackageTree.Budget()
        var files: [String: Data] = [:]
        _ = try online.exportPackageTree(url: repository.path, revision: revision, submodules: false, budget: &budget) {
            entry, data in files[entry.path] = data
        }
        XCTAssertEqual(files["Kept.txt"], Data("raw\n".utf8))
        let offline = GitCatalog(cache: cache, runner: git, update: false, offline: true)
        budget = GitPackageTree.Budget(remainingEntries: 1)
        XCTAssertThrowsError(try offline.exportPackageTree(
            url: repository.path, revision: revision, submodules: false, budget: &budget
        ) { _, _ in }) { XCTAssertTrue("\($0)".contains("entry or byte limit"), "\($0)") }
        budget = GitPackageTree.Budget(remainingBytes: 1)
        XCTAssertThrowsError(try offline.exportPackageTree(
            url: repository.path, revision: revision, submodules: false, budget: &budget
        ) { _, _ in }) { XCTAssertTrue("\($0)".contains("entry or byte limit"), "\($0)") }
        XCTAssertThrowsError(try offline.exportPackageTree(
            url: repository.path, revision: String(revision.prefix(12)), submodules: false, budget: &budget
        ) { _, _ in }) { XCTAssertTrue("\($0)".contains("full commit ID"), "\($0)") }
    }

    func testOneLevelOverrideInstallDeploymentAndOfflineRecovery() throws {
        let directory = try fixture()
        let cache = directory.appendingPathComponent("cache")
        let grammar = directory.appendingPathComponent("grammar")
        try repository(grammar, files: ["parser.c": "int pinned(void) { return 7; }\n"])
        let grammarRevision = try commit(grammar)
        try write("int moved(void) { return 8; }\n", to: grammar.appendingPathComponent("parser.c"))
        _ = try commit(grammar)
        try self.cache(grammar, in: cache, origin: grammarOrigin, revision: grammarRevision)

        let source = directory.appendingPathComponent("package")
        let scheme = ".swiftpm/xcode/Managed.xcscheme"
        try repository(source, files: ["Package.swift": package, scheme: "tracked scheme", "tool.sh": "#!/bin/sh\n"])
        XCTAssertEqual(chmod(source.appendingPathComponent("tool.sh").path, 0o755), 0)
        try FileManager.default.createSymbolicLink(
            atPath: source.appendingPathComponent("package-link").path, withDestinationPath: "Package.swift")
        let revision = try addSubmodule(to: source, path: "Grammar", origin: grammarOrigin, revision: grammarRevision)
        try self.cache(source, in: cache, origin: origin, revision: revision)

        let output = directory.appendingPathComponent("SwiftPods/Overrides/overridekit")
        let derived = output.appendingPathComponent(".swiftpm/xcode/LocalState")
        let resolved = directory.appendingPathComponent("App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        let runner = Runner {
            if !FileManager.default.fileExists(atPath: derived.path) {
                try Data("derived".utf8).write(to: derived)
            }
        }
        let installer = Installer(directory: directory, runner: runner, sourcesCache: cache)
        var offline = InstallOptions()
        offline.offline = true
        try write(podfile(revision), to: directory.appendingPathComponent("Podfile"))
        XCTAssertThrowsError(try installer.install(offline)) { XCTAssertTrue("\($0)".contains("submodules: true"), "\($0)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))

        try write(podfile(revision, submodules: true), to: directory.appendingPathComponent("Podfile"))
        try write(#"{"version":3,"pins":[]}"#, to: resolved)
        var resolving = offline
        resolving.resolve = true
        _ = try installer.install(resolving)
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("Grammar/parser.c"), encoding: .utf8),
                       "int pinned(void) { return 7; }\n")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: output.appendingPathComponent("tool.sh").path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: output.appendingPathComponent("package-link").path),
                       "Package.swift")
        XCTAssertTrue(FileManager.default.fileExists(atPath: derived.path))

        let lockURL = directory.appendingPathComponent(SwiftPodsLock.fileName)
        let lockData = try Data(contentsOf: lockURL)
        let lock = try SwiftPodsLock(contentsOf: lockURL)
        XCTAssertEqual(lock.version, 2)
        XCTAssertEqual(lock.pinnedOverrides.first?.revision, revision)
        XCTAssertEqual(lock.pinnedOverrides.first?.metadataPaths, [".swiftpm", ".swiftpm/xcode", scheme])
        let project = directory.appendingPathComponent("App.xcodeproj/project.pbxproj")
        let written = try String(contentsOf: project, encoding: .utf8)
        XCTAssertTrue(written.contains("SwiftPods/Overrides/overridekit"))
        XCTAssertFalse(written.contains("productName = OverrideKit;"))

        let before = try FileManager.default.attributesOfItem(atPath: output.path)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(try installer.install(offline).projects.flatMap(\.changes), [])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: output.path)[.systemFileNumber] as? NSNumber, before)
        var deployment = offline
        deployment.deployment = true
        let resolvedData = try Data(contentsOf: resolved)
        let coldCache = directory.appendingPathComponent("unused-cache")
        _ = try Installer(directory: directory, runner: runner, sourcesCache: coldCache).install(deployment)
        XCTAssertFalse(FileManager.default.fileExists(atPath: coldCache.path))
        XCTAssertEqual(try Data(contentsOf: resolved), resolvedData)
        XCTAssertEqual(try Data(contentsOf: lockURL), lockData)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: output.path)[.systemFileNumber] as? NSNumber, before)
        try write("""
            {"version":3,"pins":[{"identity":"overridekit","kind":"remoteSourceControl","location":"\(origin)",
            "state":{"revision":"\(revision)","branch":"main"}}]}
            """, to: resolved)
        XCTAssertThrowsError(try installer.install(deployment)) {
            XCTAssertTrue("\($0)".contains("must not have a remote pin"), "\($0)")
        }
        try resolvedData.write(to: resolved)

        try write("changed", to: output.appendingPathComponent(scheme))
        XCTAssertThrowsError(try installer.install(deployment)) { XCTAssertTrue("\($0)".contains("do not match SwiftPods.lock"), "\($0)") }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("SwiftPods"))
        XCTAssertThrowsError(try installer.install(deployment))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        _ = try installer.install(offline)
        XCTAssertEqual(try Data(contentsOf: lockURL), lockData)
        try write(podfile(revision, submodules: true).replacingOccurrences(
            of: "submodules: true", with: "submodules: true, products: ['OverrideKit']"),
            to: directory.appendingPathComponent("Podfile"))
        _ = try installer.install(offline)
        XCTAssertTrue(try String(contentsOf: project, encoding: .utf8).contains("productName = OverrideKit;"))
        _ = try installer.deintegrate()
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(try String(contentsOf: project, encoding: .utf8).contains("SwiftPods/Overrides"))
    }

    func testNestedSubmodulesAreRejectedWithoutLookingUpTheirOrigins() throws {
        let directory = try fixture()
        let cache = directory.appendingPathComponent("cache")
        let grammar = directory.appendingPathComponent("grammar")
        try repository(grammar, files: ["parser.c": ""])
        let child = try addSubmodule(
            to: grammar, path: "Nested", origin: "https://example.com/Nested.git", revision: String(repeating: "a", count: 40))
        try self.cache(grammar, in: cache, origin: grammarOrigin, revision: child)
        let source = directory.appendingPathComponent("package")
        try repository(source, files: ["Package.swift": package])
        let revision = try addSubmodule(to: source, path: "Grammar", origin: grammarOrigin, revision: child)
        try self.cache(source, in: cache, origin: origin, revision: revision)
        try write(podfile(revision, submodules: true), to: directory.appendingPathComponent("Podfile"))
        let installer = Installer(directory: directory, sourcesCache: cache)
        var offline = InstallOptions()
        offline.offline = true
        XCTAssertThrowsError(try installer.install(offline)) { XCTAssertTrue("\($0)".contains("nested gitlink"), "\($0)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("SwiftPods/Overrides").path))
    }

    func testOverrideRejectsAbsoluteAndEscapingSymbolicLinks() throws {
        for target in ["/tmp", "../outside"] {
            let directory = try fixture()
            let source = directory.appendingPathComponent("package")
            let cache = directory.appendingPathComponent("cache")
            try repository(source, files: ["Package.swift": package])
            try FileManager.default.createSymbolicLink(
                atPath: source.appendingPathComponent("link").path, withDestinationPath: target)
            let revision = try commit(source)
            try self.cache(source, in: cache, origin: origin, revision: revision)
            try write(podfile(revision), to: directory.appendingPathComponent("Podfile"))
            let installer = Installer(directory: directory, sourcesCache: cache)
            var offline = InstallOptions()
            offline.offline = true
            XCTAssertThrowsError(try installer.install(offline)) { XCTAssertTrue("\($0)".contains("symbolic link"), "\($0)") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("SwiftPods/Overrides").path))
        }
    }

    func testXcodeBuildsATransitiveBranchWithAnUnlinkedOverride() throws {
        guard ProcessInfo.processInfo.environment["SWIFTPODS_E2E"] == "1" else {
            throw XCTSkip("Set SWIFTPODS_E2E=1 to build with Xcode")
        }
        let directory = try fixture()
        let source = directory.appendingPathComponent("git/OverrideKit")
        let cache = directory.appendingPathComponent("cache")
        let code = "Sources/OverrideKit/Version.swift"
        try repository(source, files: [
            "Package.swift": package, code: "public func pinnedValue() -> Int { 42 }\n",
        ])
        let revision = try commit(source)
        try write("public func latestValue() -> Int { 99 }\n", to: source.appendingPathComponent(code))
        _ = try commit(source)
        try self.cache(source, in: cache, origin: origin, revision: revision)

        try write("""
            // swift-tools-version: 5.9
            import PackageDescription
            let package = Package(
                name: "UpstreamKit",
                products: [.library(name: "UpstreamKit", targets: ["UpstreamKit"])],
                dependencies: [.package(url: "\(source.absoluteString)", branch: "main")],
                targets: [.target(name: "UpstreamKit", dependencies: [
                    .product(name: "OverrideKit", package: "overridekit")
                ])]
            )
            """, to: directory.appendingPathComponent("UpstreamKit/Package.swift"))
        try write("import OverrideKit\npublic func selectedValue() -> Int { pinnedValue() }\n",
                  to: directory.appendingPathComponent("UpstreamKit/Sources/UpstreamKit/Value.swift"))
        try write("import UpstreamKit\nprint(selectedValue())\n", to: directory.appendingPathComponent("main.swift"))
        try write("""
            platform :ios, '15.0'
            target 'App' do
              settings 'GENERATE_INFOPLIST_FILE' => 'YES', 'PRODUCT_BUNDLE_IDENTIFIER' => 'org.swiftpods.override-e2e',
                       'SWIFT_VERSION' => '5.0', 'ALWAYS_SEARCH_USER_PATHS' => 'NO'
              spm 'UpstreamKit', path: 'UpstreamKit'
              spm '\(origin)', revision: '\(revision)', override: true
            end
            """, to: directory.appendingPathComponent("Podfile"))
        var options = InstallOptions()
        options.offline = true
        _ = try Installer(directory: directory, sourcesCache: cache).install(options)
        let build = try git.run("/usr/bin/xcrun", [
            "xcodebuild", "build", "-project", "App.xcodeproj", "-scheme", "App",
            "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", directory.appendingPathComponent("DerivedData").path,
            "ARCHS=arm64", "CODE_SIGNING_ALLOWED=NO",
        ], in: directory, timeout: 180)
        XCTAssertTrue(build.contains("** BUILD SUCCEEDED **"))
    }
}
