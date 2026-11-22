import CryptoKit
import Darwin
import Foundation
@testable import SwiftPodsKit
import SwiftPodsManifest
import XCTest

final class CatalogSupplyChainTests: XCTestCase {
    private var temporaryDirectories: [URL] = []
    private let runner = ProcessRunner()

    private final class RecordingRunner: CommandRunner, @unchecked Sendable {
        private let runner = ProcessRunner()
        private let lock = NSLock()
        private var values: [[String]] = []

        var invocations: [[String]] { lock.withLock { values } }

        func run(_ executable: String, _ arguments: [String], in directory: URL?) throws -> String {
            lock.withLock { values.append(arguments) }
            return try runner.run(executable, arguments, in: directory)
        }

        func runData(_ executable: String, _ arguments: [String], in directory: URL?) throws -> Data {
            lock.withLock { values.append(arguments) }
            return try runner.runData(executable, arguments, in: directory)
        }
    }

    /// Counts Git fetches that overlap in time.
    private final class CollisionDetectingRunner: CommandRunner, @unchecked Sendable {
        private let runner = ProcessRunner()
        private let lock = NSLock()
        private var activeFetches = 0
        private(set) var maximumConcurrentFetches = 0

        func run(_ executable: String, _ arguments: [String], in directory: URL?) throws -> String {
            String(decoding: try runData(executable, arguments, in: directory), as: UTF8.self)
        }

        func runData(_ executable: String, _ arguments: [String], in directory: URL?) throws -> Data {
            let fetch = arguments.contains("fetch")
            if fetch {
                lock.withLock {
                    activeFetches += 1
                    maximumConcurrentFetches = max(maximumConcurrentFetches, activeFetches)
                }
                Thread.sleep(forTimeInterval: 0.15)
            }
            defer {
                if fetch { lock.withLock { activeFetches -= 1 } }
            }
            return try runner.runData(executable, arguments, in: directory)
        }
    }

    private final class ConcurrentErrors: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Error] = []

        func append(_ error: Error) { lock.withLock { values.append(error) } }
        var count: Int { lock.withLock { values.count } }
        var firstDescription: String? { lock.withLock { values.first.map(String.init(describing:)) } }
    }

    override func tearDown() {
        for directory in temporaryDirectories { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    private func temporaryDirectory(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftpods-\(name)-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func repository(in parent: URL, name: String = "catalog") throws -> URL {
        let repository = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent("Packages", isDirectory: true), withIntermediateDirectories: true)
        _ = try runner.run("/usr/bin/git", ["init", "-q"], in: repository)
        return repository
    }

    @discardableResult
    private func publish(_ text: String, to repository: URL, name: String = "Kit") throws -> String {
        try text.write(
            to: repository.appendingPathComponent("Packages/\(name).podfile"), atomically: true, encoding: .utf8)
        _ = try runner.run("/usr/bin/git", ["add", "-A"], in: repository)
        _ = try runner.run(
            "/usr/bin/git", ["-c", "user.name=SwiftPods Tests", "-c", "user.email=tests@swiftpods.invalid", "commit", "-q", "-m", name],
            in: repository)
        return try runner.run("/usr/bin/git", ["rev-parse", "HEAD"], in: repository)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func testLockedOverridesMatchInAnyOrder() throws {
        func override(_ identity: String) -> SwiftPodsLock.Override {
            SwiftPodsLock.Override(
                identity: identity, url: "https://example.com/\(identity).git", revision: String(repeating: "a", count: 40),
                submodules: false, sha256: String(repeating: "b", count: 64), metadataPaths: [])
        }
        let actual = SwiftPodsLock(resolutions: [], overrides: [override("alpha"), override("beta")])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: actual.data()) as? [String: Any])
        json["overrides"] = Array(try XCTUnwrap(json["overrides"] as? [Any]).reversed())
        let file = URL(fileURLWithPath: "/project/SwiftPods.lock")
        let merged = try SwiftPodsLock(data: JSONSerialization.data(withJSONObject: json), file: file)
        XCTAssertEqual(merged.pinnedOverrides.map(\.identity), ["beta", "alpha"])
        XCTAssertEqual(merged.problems(comparedTo: actual), [])
        XCTAssertFalse(SwiftPodsLock(resolutions: [], overrides: [override("alpha")]).problems(comparedTo: actual).isEmpty)
    }

    func testLockRoundTripsDeterministicallyAndPinsAnUnpinnedCatalogOnAColdCache() throws {
        let parent = try temporaryDirectory("catalog-lock")
        let repository = try repository(in: parent)
        let first = "package 'Kit', git: 'https://github.com/example/first.git'\n"
        let firstRevision = try publish(first, to: repository)
        let source = Source(url: repository.path)
        let cache = parent.appendingPathComponent("cache")
        let catalog = GitCatalog(cache: cache, runner: runner, update: false, offline: false)

        XCTAssertEqual(try catalog.entry(named: "kit", in: [source])?.url, "https://github.com/example/first.git")
        let lock = SwiftPodsLock(resolutions: catalog.resolutions)
        XCTAssertEqual(lock.catalogs, [
            .init(url: repository.path, revision: firstRevision, entries: [.init(name: "Kit", sha256: digest(first))])
        ])
        XCTAssertEqual(try lock.data(), try lock.data())
        let lockFile = parent.appendingPathComponent(SwiftPodsLock.fileName)
        try lock.data().write(to: lockFile)
        XCTAssertEqual(try SwiftPodsLock(contentsOf: lockFile), lock)

        _ = try publish("package 'Kit', git: 'https://github.com/example/second.git'\n", to: repository)
        let coldCache = parent.appendingPathComponent("cold-cache")
        let coldRunner = RecordingRunner()
        let deployment = GitCatalog(
            cache: coldCache, runner: coldRunner, update: true, offline: false,
            requiresLock: true, lockProvider: { lock })
        XCTAssertEqual(try deployment.entry(named: "Kit", in: [source])?.url, "https://github.com/example/first.git")
        XCTAssertEqual(deployment.resolutions.first?.revision, firstRevision)
        XCTAssertEqual(lock.problems(comparedTo: SwiftPodsLock(resolutions: deployment.resolutions)), [])
        XCTAssertFalse(coldRunner.invocations.contains { $0.contains("clone") }, "A pinned cold fetch must not clone full history")
        XCTAssertTrue(coldRunner.invocations.contains { $0.contains("fetch") && $0.contains(firstRevision) })
    }

    func testCatalogSearchReadsOnlyMatchingEntries() throws {
        let parent = try temporaryDirectory("catalog-search-success")
        let repository = try repository(in: parent)
        for name in ["KitOne", "KitTwo", "Other"] {
            try "package '\(name)', git: 'https://github.com/example/\(name).git'\n".write(
                to: repository.appendingPathComponent("Packages/\(name).podfile"), atomically: true, encoding: .utf8)
        }
        _ = try runner.run("/usr/bin/git", ["add", "-A"], in: repository)
        _ = try runner.run(
            "/usr/bin/git",
            ["-c", "user.name=SwiftPods Tests", "-c", "user.email=tests@swiftpods.invalid", "commit", "-q", "-m", "search"],
            in: repository)
        let recording = RecordingRunner()

        let entries = try CatalogTools.search(
            "kit", sources: [Source(url: repository.path)], runner: recording,
            cache: parent.appendingPathComponent("cache"), update: false)

        XCTAssertEqual(entries.map(\.name), ["KitOne", "KitTwo"])
        XCTAssertEqual(recording.invocations.filter { $0.contains("cat-file") }.count, 2)
    }

    func testDeploymentRejectsMissingOrChangedCatalogEvidence() throws {
        let parent = try temporaryDirectory("catalog-evidence")
        let repository = try repository(in: parent)
        let text = "package 'Kit', git: 'https://github.com/example/Kit.git'\n"
        _ = try publish(text, to: repository)
        let source = Source(url: repository.path)
        let cache = parent.appendingPathComponent("cache")

        let missing = GitCatalog(
            cache: cache, runner: runner, update: false, offline: false, requiresLock: true)
        XCTAssertThrowsError(try missing.entry(named: "Kit", in: [source])) {
            XCTAssertTrue("\($0)".contains("not recorded in SwiftPods.lock"), "\($0)")
        }

        let unlocked = GitCatalog(cache: cache, runner: runner, update: false, offline: false)
        _ = try unlocked.entry(named: "Kit", in: [source])
        let valid = SwiftPodsLock(resolutions: unlocked.resolutions)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid.data()) as? [String: Any])
        var catalogs = try XCTUnwrap(object["catalogs"] as? [[String: Any]])
        var entries = try XCTUnwrap(catalogs[0]["entries"] as? [[String: Any]])
        entries[0]["sha256"] = String(repeating: "0", count: 64)
        catalogs[0]["entries"] = entries
        object["catalogs"] = catalogs
        let changedFile = parent.appendingPathComponent("changed.lock")
        try JSONSerialization.data(withJSONObject: object).write(to: changedFile)
        let changed = try SwiftPodsLock(contentsOf: changedFile)
        let deployment = GitCatalog(
            cache: cache, runner: runner, update: false, offline: true,
            requiresLock: true, lockProvider: { changed })
        XCTAssertThrowsError(try deployment.entry(named: "Kit", in: [source])) {
            XCTAssertTrue("\($0)".contains("does not match SwiftPods.lock"), "\($0)")
        }
    }

    func testLockPinsEveryConsultedCatalogToPreserveSourcePrecedence() throws {
        let parent = try temporaryDirectory("catalog-precedence")
        let first = try repository(in: parent, name: "first")
        let second = try repository(in: parent, name: "second")
        _ = try publish("package 'Other', git: 'https://github.com/example/Other.git'\n", to: first, name: "Other")
        _ = try publish("package 'Kit', git: 'https://github.com/example/selected.git'\n", to: second)
        let sources = [Source(url: first.path), Source(url: second.path)]
        let catalog = GitCatalog(
            cache: parent.appendingPathComponent("cache"), runner: runner, update: false, offline: false)
        XCTAssertEqual(try catalog.entry(named: "Kit", in: sources)?.url, "https://github.com/example/selected.git")
        let lock = SwiftPodsLock(resolutions: catalog.resolutions)
        XCTAssertEqual(lock.catalog(url: first.path)?.entries, [])
        XCTAssertEqual(lock.catalog(url: second.path)?.entries.map(\.name), ["Kit"])

        _ = try publish("package 'Kit', git: 'https://github.com/example/hijack.git'\n", to: first)
        let deployment = GitCatalog(
            cache: parent.appendingPathComponent("deployment-cache"), runner: runner, update: true, offline: false,
            requiresLock: true, lockProvider: { lock })
        XCTAssertEqual(try deployment.entry(named: "Kit", in: sources)?.url, "https://github.com/example/selected.git")
        XCTAssertEqual(lock.problems(comparedTo: SwiftPodsLock(resolutions: deployment.resolutions)), [])
    }

    func testFullObjectIDsAndRegularCatalogFilesAreRequired() throws {
        let parent = try temporaryDirectory("catalog-tree")
        let repository = try repository(in: parent)
        _ = try publish("package 'Kit', git: 'https://github.com/example/Kit.git'\n", to: repository)
        let cache = parent.appendingPathComponent("cache")
        let abbreviated = GitCatalog(cache: cache, runner: runner, update: false, offline: false)
        XCTAssertThrowsError(try abbreviated.entry(
            named: "Kit", in: [Source(url: repository.path, revision: "0123456789ab")])) {
            XCTAssertTrue("\($0)".contains("full 40- or 64-character"), "\($0)")
        }

        let linked = repository.appendingPathComponent("Packages/Linked.podfile")
        try FileManager.default.createSymbolicLink(atPath: linked.path, withDestinationPath: "Kit.podfile")
        _ = try runner.run("/usr/bin/git", ["add", "Packages/Linked.podfile"], in: repository)
        _ = try runner.run(
            "/usr/bin/git", ["-c", "user.name=SwiftPods Tests", "-c", "user.email=tests@swiftpods.invalid", "commit", "-q", "-m", "symlink"],
            in: repository)
        XCTAssertTrue(CatalogTools.lint(repository).contains { $0.contains("cannot be symbolic links") })
        let catalog = GitCatalog(cache: parent.appendingPathComponent("linked-cache"), runner: runner, update: false, offline: false)
        XCTAssertThrowsError(try catalog.entry(named: "Kit", in: [Source(url: repository.path)])) {
            XCTAssertTrue("\($0)".contains("symbolic link or special entry"), "\($0)")
        }
    }

    func testLintUsesFetchIdentityForDuplicateRepositoryOrigins() throws {
        let parent = try temporaryDirectory("catalog-lint-origins")
        let repository = try repository(in: parent)
        let packages = repository.appendingPathComponent("Packages")
        try "package 'Upper', git: 'https://EXAMPLE.com/Team/Kit.git'\n"
            .write(to: packages.appendingPathComponent("Upper.podfile"), atomically: true, encoding: .utf8)
        try "package 'Lower', git: 'https://example.com/team/Kit.git'\n"
            .write(to: packages.appendingPathComponent("Lower.podfile"), atomically: true, encoding: .utf8)
        XCTAssertEqual(CatalogTools.lint(repository), [], "Case-sensitive repository paths are distinct fetch origins")

        try "package 'Duplicate', git: 'https://example.com/Team/Kit.git'\n"
            .write(to: packages.appendingPathComponent("Duplicate.podfile"), atomically: true, encoding: .utf8)
        let problems = CatalogTools.lint(repository)
        XCTAssertEqual(problems.count, 1, "\(problems)")
        XCTAssertTrue(problems[0].contains("is already declared by"), "\(problems)")
    }

    func testEntryDigestUsesRawUTF8BytesAndInvalidUTF8IsRejected() throws {
        let parent = try temporaryDirectory("catalog-encoding")
        let repository = try repository(in: parent)
        let valid = Data("package 'Kit', git: 'https://github.com/example/Kit.git'\n# �\n".utf8)
        try valid.write(to: repository.appendingPathComponent("Packages/Kit.podfile"))
        _ = try runner.run("/usr/bin/git", ["add", "-A"], in: repository)
        _ = try runner.run(
            "/usr/bin/git", ["-c", "user.name=SwiftPods Tests", "-c", "user.email=tests@swiftpods.invalid", "commit", "-q", "-m", "valid utf8"],
            in: repository)
        let source = Source(url: repository.path)
        let catalog = GitCatalog(
            cache: parent.appendingPathComponent("valid-cache"), runner: runner, update: false, offline: false)
        XCTAssertEqual(try catalog.entry(named: "Kit", in: [source])?.name, "Kit")
        let expected = SHA256.hash(data: valid).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(catalog.resolutions.first?.entries.first?.sha256, expected)

        var invalid = Data("package 'Kit', git: 'https://github.com/example/Kit.git'\n# ".utf8)
        invalid.append(0xFF)
        invalid.append(0x0A)
        try invalid.write(to: repository.appendingPathComponent("Packages/Kit.podfile"))
        _ = try runner.run("/usr/bin/git", ["add", "-A"], in: repository)
        _ = try runner.run(
            "/usr/bin/git", ["-c", "user.name=SwiftPods Tests", "-c", "user.email=tests@swiftpods.invalid", "commit", "-q", "-m", "invalid utf8"],
            in: repository)
        let rejected = GitCatalog(
            cache: parent.appendingPathComponent("invalid-cache"), runner: runner, update: false, offline: false)
        XCTAssertThrowsError(try rejected.entry(named: "Kit", in: [source])) {
            XCTAssertTrue("\($0)".contains("not valid UTF-8"), "\($0)")
        }
    }

    func testConcurrentCatalogUpdatesSerializeTheSharedCacheTransaction() throws {
        let parent = try temporaryDirectory("catalog-concurrency")
        let repository = try repository(in: parent)
        _ = try publish("package 'Kit', git: 'https://github.com/example/Kit.git'\n", to: repository)
        let cache = parent.appendingPathComponent("cache")
        let source = Source(url: repository.path)
        let sharedRunner = CollisionDetectingRunner()
        let errors = ConcurrentErrors()
        let ready = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        for _ in 0..<2 {
            ready.enter()
            finished.enter()
            DispatchQueue.global().async {
                ready.leave()
                start.wait()
                defer { finished.leave() }
                do {
                    let catalog = GitCatalog(cache: cache, runner: sharedRunner, update: true, offline: false)
                    _ = try catalog.entry(named: "Kit", in: [source])
                } catch {
                    errors.append(error)
                }
            }
        }
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
        start.signal()
        start.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(errors.count, 0, errors.firstDescription ?? "")
        XCTAssertEqual(sharedRunner.maximumConcurrentFetches, 1)
    }

}
