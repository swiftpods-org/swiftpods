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

        func run(
            _ executable: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval
        ) throws -> String {
            lock.withLock { values.append(arguments) }
            return try runner.run(executable, arguments, in: directory, timeout: timeout)
        }

        func runData(
            _ executable: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval,
            maximumOutputBytes: Int
        ) throws -> Data {
            lock.withLock { values.append(arguments) }
            return try runner.runData(
                executable, arguments, in: directory, timeout: timeout, maximumOutputBytes: maximumOutputBytes)
        }
    }

    private final class CacheRebindingRunner: CommandRunner, @unchecked Sendable {
        private let runner = ProcessRunner()
        private let cache: URL
        private let movedCache: URL
        private let replacement: URL
        private let lock = NSLock()
        private var rebound = false

        init(cache: URL, movedCache: URL, replacement: URL) {
            self.cache = cache
            self.movedCache = movedCache
            self.replacement = replacement
        }

        var didRebind: Bool { lock.withLock { rebound } }

        func run(_ executable: String, _ arguments: [String], in directory: URL?) throws -> String {
            try runner.run(executable, arguments, in: directory)
        }

        func run(
            _ executable: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval
        ) throws -> String {
            try runner.run(executable, arguments, in: directory, timeout: timeout)
        }

        func runData(
            _ executable: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval,
            maximumOutputBytes: Int
        ) throws -> Data {
            let result = try runner.runData(
                executable, arguments, in: directory, timeout: timeout,
                maximumOutputBytes: maximumOutputBytes)
            let shouldRebind = lock.withLock { () -> Bool in
                guard !rebound, arguments.contains("ls-tree") else { return false }
                rebound = true
                return true
            }
            if shouldRebind {
                guard rename(cache.path, movedCache.path) == 0 else {
                    throw SwiftPodsError("Test could not move the authenticated catalog cache")
                }
                try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: replacement)
            }
            return result
        }
    }

    private final class IntermediateLinkFlippingRunner: CommandRunner, @unchecked Sendable {
        private let runner = ProcessRunner()
        private let link: URL
        private let replacement: URL
        private let lock = NSLock()
        private var flipped = false

        init(link: URL, replacement: URL) {
            self.link = link
            self.replacement = replacement
        }

        var didFlip: Bool { lock.withLock { flipped } }

        func run(_ executable: String, _ arguments: [String], in directory: URL?) throws -> String {
            try runner.run(executable, arguments, in: directory)
        }

        func run(
            _ executable: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval
        ) throws -> String {
            try runner.run(executable, arguments, in: directory, timeout: timeout)
        }

        func runData(
            _ executable: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval,
            maximumOutputBytes: Int
        ) throws -> Data {
            let result = try runner.runData(
                executable, arguments, in: directory, timeout: timeout,
                maximumOutputBytes: maximumOutputBytes)
            let shouldFlip = lock.withLock { () -> Bool in
                guard !flipped, arguments.contains("ls-tree") else { return false }
                flipped = true
                return true
            }
            if shouldFlip {
                try FileManager.default.removeItem(at: link)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: replacement)
            }
            return result
        }
    }

    private final class CollisionDetectingRunner: CommandRunner, @unchecked Sendable {
        private let runner = ProcessRunner()
        private let lock = NSLock()
        private var activeClones = 0
        private(set) var maximumConcurrentClones = 0

        func run(_ executable: String, _ arguments: [String], in directory: URL?) throws -> String {
            let clone = arguments.contains("clone")
            if clone {
                lock.withLock {
                    activeClones += 1
                    maximumConcurrentClones = max(maximumConcurrentClones, activeClones)
                }
                Thread.sleep(forTimeInterval: 0.15)
            }
            defer {
                if clone { lock.withLock { activeClones -= 1 } }
            }
            return try runner.run(executable, arguments, in: directory)
        }

        func run(
            _ executable: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval
        ) throws -> String {
            let clone = arguments.contains("clone")
            if clone {
                lock.withLock {
                    activeClones += 1
                    maximumConcurrentClones = max(maximumConcurrentClones, activeClones)
                }
                Thread.sleep(forTimeInterval: 0.15)
            }
            defer {
                if clone { lock.withLock { activeClones -= 1 } }
            }
            return try runner.run(executable, arguments, in: directory, timeout: timeout)
        }

        func runData(
            _ executable: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval,
            maximumOutputBytes: Int
        ) throws -> Data {
            let clone = arguments.contains("clone")
            if clone {
                lock.withLock {
                    activeClones += 1
                    maximumConcurrentClones = max(maximumConcurrentClones, activeClones)
                }
                Thread.sleep(forTimeInterval: 0.15)
            }
            defer {
                if clone { lock.withLock { activeClones -= 1 } }
            }
            return try runner.runData(
                executable, arguments, in: directory, timeout: timeout, maximumOutputBytes: maximumOutputBytes)
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

    private func diskFootprint(of directory: URL) throws -> Int64 {
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: [],
            errorHandler: { _, error in enumerationError = error; return false })
        else { throw SwiftPodsError("Cannot enumerate \(directory.path)") }
        var bytes: Int64 = 0
        for case let path as URL in enumerator {
            var status = stat()
            guard path.path.withCString({ lstat($0, &status) }) == 0 else {
                throw SwiftPodsError("Cannot inspect \(path.path)")
            }
            if status.st_mode & S_IFMT == S_IFREG {
                let amount = max(status.st_size, Int64(status.st_blocks) * 512)
                let sum = bytes.addingReportingOverflow(amount)
                guard amount >= 0, !sum.overflow else { throw SwiftPodsError("Invalid directory footprint") }
                bytes = sum.partialValue
            }
        }
        if let enumerationError { throw enumerationError }
        return bytes
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
        try lock.write(to: lockFile)
        XCTAssertEqual(try SwiftPodsLock(contentsOf: lockFile), lock)

        _ = try publish("package 'Kit', git: 'https://github.com/example/second.git'\n", to: repository)
        let coldCache = parent.appendingPathComponent("cold-cache")
        let coldRunner = RecordingRunner()
        let deployment = GitCatalog(
            cache: coldCache, runner: coldRunner, update: true, offline: false,
            deploymentLock: lock, requiresLock: true)
        XCTAssertEqual(try deployment.entry(named: "Kit", in: [source])?.url, "https://github.com/example/first.git")
        XCTAssertEqual(deployment.resolutions.first?.revision, firstRevision)
        XCTAssertEqual(lock.problems(comparedTo: SwiftPodsLock(resolutions: deployment.resolutions)), [])
        XCTAssertFalse(coldRunner.invocations.contains { $0.contains("clone") }, "A pinned cold fetch must not clone full history")
        XCTAssertTrue(coldRunner.invocations.contains { $0.contains("fetch") && $0.contains(firstRevision) })
        XCTAssertTrue(coldRunner.invocations.contains { $0.contains("count-objects") }, "Staging must be budgeted before caching")
        XCTAssertTrue(coldRunner.invocations.allSatisfy { arguments in
            guard arguments.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"),
                arguments.contains("GIT_CONFIG_NOSYSTEM=1"),
                arguments.contains("GIT_CONFIG_GLOBAL=/dev/null"),
                arguments.contains("/usr/bin/git"),
                arguments.contains("credential.helper=osxkeychain"),
                arguments.contains("http.sslVerify=true"),
                arguments.contains("http.followRedirects=false"),
                let value = arguments.firstIndex(where: {
                    $0.hasPrefix("core.sshCommand=/usr/bin/ssh -F /dev/null -oBatchMode=yes")
                }),
                value > arguments.startIndex
            else {
                return false
            }
            return arguments[arguments.index(before: value)] == "-c"
        }, "Every Git invocation must use the absolute system SSH executable without interactive prompts")
    }

    func testRemoteGitPoliciesPinAddressesAndDisableRedirectsProxiesAndSSHConfig() throws {
        let https = try XCTUnwrap(PackageLocation.remoteEndpoint("https://github.com/example/catalog.git"))
        let httpsPolicy = try GitCatalog.makeGitNetworkPolicy(
            endpoint: https, addresses: ["93.184.216.34", "2606:4700:4700::1111"])
        XCTAssertTrue(httpsPolicy.configuration.contains(
            "http.curloptResolve=github.com:443:93.184.216.34,[2606:4700:4700::1111]"))
        XCTAssertTrue(httpsPolicy.configuration.contains("http.followRedirects=false"))
        XCTAssertTrue(httpsPolicy.configuration.contains("http.sslVerify=true"))
        XCTAssertTrue(httpsPolicy.configuration.contains("http.proxy="))

        let ssh = try XCTUnwrap(PackageLocation.remoteEndpoint(
            "ssh://git@example.com:2222/example/catalog.git"))
        let sshPolicy = try GitCatalog.makeGitNetworkPolicy(
            endpoint: ssh, addresses: ["93.184.216.34"])
        let command = try XCTUnwrap(sshPolicy.configuration.last)
        XCTAssertTrue(command.contains("/usr/bin/ssh -F /dev/null"), command)
        XCTAssertTrue(command.contains("-oStrictHostKeyChecking=yes"), command)
        XCTAssertTrue(command.contains("-oProxyCommand=none"), command)
        XCTAssertTrue(command.contains("'-oHostname=93.184.216.34'"), command)
        XCTAssertTrue(command.contains("'-oHostKeyAlias=[example.com]:2222'"), command)
    }

    func testCatalogCloneIgnoresAmbientGlobalURLRewritesAndTLSDowngrades() throws {
        let parent = try temporaryDirectory("catalog-ambient-config")
        let expectedRepository = try repository(in: parent, name: "expected")
        let attacker = try repository(in: parent, name: "rewritten")
        _ = try publish(
            "package 'Kit', git: 'https://github.com/example/expected.git'\n",
            to: expectedRepository)
        _ = try publish(
            "package 'Kit', git: 'https://github.com/example/rewritten.git'\n",
            to: attacker)
        let home = parent.appendingPathComponent("ambient-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        try """
            [url "\(attacker.path)"]
                insteadOf = \(expectedRepository.path)
            [http]
                sslVerify = false
                followRedirects = true
                proxy = http://127.0.0.1:1
            """.write(
                to: home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)

        let previousHome = getenv("HOME").map { String(cString: $0) }
        XCTAssertEqual(setenv("HOME", home.path, 1), 0)
        defer {
            if let previousHome { _ = setenv("HOME", previousHome, 1) } else { _ = unsetenv("HOME") }
        }
        let catalog = GitCatalog(
            cache: parent.appendingPathComponent("cache"), runner: runner,
            update: false, offline: false)
        XCTAssertEqual(
            try catalog.entry(named: "Kit", in: [Source(url: expectedRepository.path)])?.url,
            "https://github.com/example/expected.git")
    }

    func testRemoteCatalogsRejectLocalAndPrivateNetworkDestinationsBeforeGitConnects() throws {
        let parent = try temporaryDirectory("catalog-private-network")
        for source in [
            "https://127.0.0.1/catalog.git",
            "ssh://git@10.0.0.1/catalog.git",
            "https://catalog.local/catalog.git",
        ] {
            let catalog = GitCatalog(
                cache: parent.appendingPathComponent(UUID().uuidString),
                runner: runner, update: false, offline: false)
            XCTAssertThrowsError(try catalog.entry(named: "Kit", in: [Source(url: source)])) { error in
                XCTAssertTrue("\(error)".contains("public IP addresses"), "\(error)")
                XCTAssertTrue("\(error)".contains("absolute local path"), "\(error)")
            }
        }
    }

    func testCatalogCacheLockWaitIsBounded() throws {
        let parent = try temporaryDirectory("catalog-lock-timeout")
        let repository = try repository(in: parent)
        _ = try publish("package 'Kit', git: 'https://github.com/example/Kit.git'\n", to: repository)
        let cache = parent.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cache, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let key = SHA256.hash(data: Data(repository.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let lockFile = cache.appendingPathComponent(".lock-source-" + String(key.prefix(2)))
        let descriptor = lockFile.path.withCString {
            open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { if descriptor >= 0 { _ = flock(descriptor, LOCK_UN); close(descriptor) } }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)

        let catalog = GitCatalog(
            cache: cache, runner: runner, update: false, offline: false, cacheLockTimeout: 0)
        XCTAssertThrowsError(try catalog.entry(named: "Kit", in: [Source(url: repository.path)])) {
            XCTAssertTrue("\($0)".contains("Timed out waiting for the catalog cache lock"), "\($0)")
        }
    }

    func testCatalogCacheRejectsLockPathReplacementWhileWaitingWithoutMutatingReplacement() throws {
        let parent = try temporaryDirectory("catalog-lock-replacement")
        let repository = try repository(in: parent)
        _ = try publish("package 'Kit', git: 'https://github.com/example/Kit.git'\n", to: repository)
        let source = Source(url: repository.path)
        let cache = parent.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cache, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let key = SHA256.hash(data: Data(repository.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let lockName = ".lock-source-" + String(key.prefix(2))
        let lockFile = cache.appendingPathComponent(lockName)
        let holder = lockFile.path.withCString {
            open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        XCTAssertGreaterThanOrEqual(holder, 0)
        defer { if holder >= 0 { _ = flock(holder, LOCK_UN); close(holder) } }
        XCTAssertEqual(flock(holder, LOCK_EX | LOCK_NB), 0)

        let waiting = DispatchSemaphore(value: 0)
        let pathReplaced = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        let errors = ConcurrentErrors()
        let recordingRunner = RecordingRunner()
        let catalog = GitCatalog(
            cache: cache, runner: recordingRunner, update: false, offline: false,
            cacheLockTimeout: 5,
            _cacheLockWaitHook: { name in
                guard name == lockName else { return }
                waiting.signal()
                _ = pathReplaced.wait(timeout: .now() + 5)
            })

        finished.enter()
        DispatchQueue.global().async {
            defer { finished.leave() }
            do {
                _ = try catalog.entry(named: "Kit", in: [source])
            } catch {
                errors.append(error)
            }
        }
        XCTAssertEqual(waiting.wait(timeout: .now() + 5), .success)

        let replacement = cache.appendingPathComponent(".replacement-lock")
        let replacementBytes = Data("replacement must remain untouched".utf8)
        try replacementBytes.write(to: replacement)
        XCTAssertEqual(chmod(replacement.path, 0o600), 0)
        XCTAssertEqual(rename(replacement.path, lockFile.path), 0)
        let replacementStatus = try SecureFileTree.statusNoFollow(lockFile)
        pathReplaced.signal()
        XCTAssertEqual(flock(holder, LOCK_UN), 0)

        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(
            errors.firstDescription?.contains("lock changed while it was being acquired") == true,
            errors.firstDescription ?? "missing error")
        XCTAssertEqual(recordingRunner.invocations, [], "Git must not run after the lock pathname changes")
        let finalStatus = try SecureFileTree.statusNoFollow(lockFile)
        XCTAssertEqual(finalStatus.st_dev, replacementStatus.st_dev)
        XCTAssertEqual(finalStatus.st_ino, replacementStatus.st_ino)
        XCTAssertEqual(finalStatus.st_mode, replacementStatus.st_mode)
        XCTAssertEqual(finalStatus.st_nlink, replacementStatus.st_nlink)
        XCTAssertEqual(finalStatus.st_uid, replacementStatus.st_uid)
        XCTAssertEqual(finalStatus.st_size, replacementStatus.st_size)
        XCTAssertEqual(finalStatus.st_mtimespec.tv_sec, replacementStatus.st_mtimespec.tv_sec)
        XCTAssertEqual(finalStatus.st_mtimespec.tv_nsec, replacementStatus.st_mtimespec.tv_nsec)
        XCTAssertEqual(finalStatus.st_ctimespec.tv_sec, replacementStatus.st_ctimespec.tv_sec)
        XCTAssertEqual(finalStatus.st_ctimespec.tv_nsec, replacementStatus.st_ctimespec.tv_nsec)
        XCTAssertEqual(try Data(contentsOf: lockFile), replacementBytes)
        let rawLabel = PackageLocation.identity(repository.path)
        let label = String(rawLabel.filter {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".")
        }.prefix(64))
        let cachedRepository = cache.appendingPathComponent(
            (label.isEmpty ? "catalog" : label) + "-" + String(key.prefix(32)) + ".git")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cachedRepository.path))
    }

    func testCatalogCacheRejectsExtendedACLAndNormalizesItsOwnedLock() throws {
        let parent = try temporaryDirectory("catalog-cache-acl")
        let repository = try repository(in: parent)
        _ = try publish("package 'Kit', git: 'https://github.com/example/Kit.git'\n", to: repository)
        let cache = parent.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cache, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        _ = try runner.run("/bin/chmod", ["+a", "everyone allow write", cache.path], in: nil)
        XCTAssertTrue(try SecureFileTree.hasExtendedACL(cache))

        let rejected = GitCatalog(cache: cache, runner: runner, update: false, offline: false)
        XCTAssertThrowsError(try rejected.entry(named: "Kit", in: [Source(url: repository.path)])) {
            XCTAssertTrue("\($0)".contains("extended ACL"), "\($0)")
        }
        XCTAssertTrue(try SecureFileTree.hasExtendedACL(cache), "Existing cache roots must fail closed, not be rewritten")
        _ = try runner.run("/bin/chmod", ["-N", cache.path], in: nil)

        let key = SHA256.hash(data: Data(repository.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let lockFile = cache.appendingPathComponent(".lock-source-" + String(key.prefix(2)))
        try Data().write(to: lockFile)
        _ = try runner.run("/bin/chmod", ["+a", "everyone allow write", lockFile.path], in: nil)
        XCTAssertTrue(try SecureFileTree.hasExtendedACL(lockFile))

        let accepted = GitCatalog(cache: cache, runner: runner, update: false, offline: false)
        XCTAssertEqual(
            try accepted.entry(named: "Kit", in: [Source(url: repository.path)])?.name, "Kit")
        XCTAssertFalse(try SecureFileTree.hasExtendedACL(lockFile))
        XCTAssertEqual(try SecureFileTree.statusNoFollow(lockFile).st_mode & 0o777, 0o600)
    }

    func testCatalogCacheReapsExactLegacyLocksAndInterruptedClones() throws {
        let parent = try temporaryDirectory("catalog-cache-residue")
        let repository = try repository(in: parent)
        _ = try publish("package 'Kit', git: 'https://github.com/example/Kit.git'\n", to: repository)
        let cache = parent.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cache, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])

        let key = SHA256.hash(data: Data(repository.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let legacyLock = cache.appendingPathComponent(".lock-" + key)
        try Data().write(to: legacyLock)
        XCTAssertEqual(chmod(legacyLock.path, 0o600), 0)
        let interruptedClone = cache.appendingPathComponent(
            ".clone-00000000-0000-0000-0000-000000000000.git", isDirectory: true)
        try FileManager.default.createDirectory(
            at: interruptedClone.appendingPathComponent("objects", isDirectory: true),
            withIntermediateDirectories: true)
        try Data("partial".utf8).write(
            to: interruptedClone.appendingPathComponent("objects/partial"))

        let catalog = GitCatalog(cache: cache, runner: runner, update: false, offline: false)
        XCTAssertEqual(
            try catalog.entry(named: "Kit", in: [Source(url: repository.path)])?.name,
            "Kit")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyLock.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: interruptedClone.path))

        let names = try FileManager.default.contentsOfDirectory(atPath: cache.path)
        XCTAssertTrue(names.contains(".lock-global"), "\(names)")
        XCTAssertEqual(names.filter { $0.hasPrefix(".lock-source-") }, [".lock-source-" + String(key.prefix(2))])
        XCTAssertFalse(names.contains { $0.hasPrefix(".lock-") && $0.count == 70 }, "\(names)")
    }

    func testCatalogCacheDoesNotBypassAHeldLegacyOriginLock() throws {
        let parent = try temporaryDirectory("catalog-cache-legacy-lock")
        let repository = try repository(in: parent)
        _ = try publish("package 'Kit', git: 'https://github.com/example/Kit.git'\n", to: repository)
        let cache = parent.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cache, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let key = SHA256.hash(data: Data(repository.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let legacyLock = cache.appendingPathComponent(".lock-" + key)
        let descriptor = legacyLock.path.withCString {
            open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { if descriptor >= 0 { _ = flock(descriptor, LOCK_UN); close(descriptor) } }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)

        let catalog = GitCatalog(
            cache: cache, runner: runner, update: false, offline: false, cacheLockTimeout: 0)
        XCTAssertThrowsError(
            try catalog.entry(named: "Kit", in: [Source(url: repository.path)])) { error in
            XCTAssertTrue("\(error)".contains("Timed out waiting for the catalog cache lock"), "\(error)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyLock.path))
    }

    func testCatalogCacheTightensAnOwnedLegacyModeButRejectsSharedWrites() throws {
        let parent = try temporaryDirectory("catalog-cache-mode")
        let repository = try repository(in: parent)
        _ = try publish("package 'Kit', git: 'https://github.com/example/Kit.git'\n", to: repository)
        let cache = parent.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cache, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])

        let catalog = GitCatalog(cache: cache, runner: runner, update: false, offline: false)
        XCTAssertEqual(try catalog.entry(named: "Kit", in: [Source(url: repository.path)])?.name, "Kit")
        XCTAssertEqual(try SecureFileTree.statusNoFollow(cache).st_mode & 0o7777, 0o700)

        let shared = parent.appendingPathComponent("shared-cache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: shared, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o770])
        let rejected = GitCatalog(cache: shared, runner: runner, update: false, offline: false)
        XCTAssertThrowsError(try rejected.entry(named: "Kit", in: [Source(url: repository.path)])) {
            XCTAssertTrue("\($0)".contains("writable non-sticky"), "\($0)")
        }
        XCTAssertEqual(try SecureFileTree.statusNoFollow(shared).st_mode & 0o7777, 0o770)
    }

    func testCatalogCacheRejectsARebindAfterRepositoryValidation() throws {
        let parent = try temporaryDirectory("catalog-cache-rebind")
        let repository = try repository(in: parent)
        _ = try publish("package 'Kit', git: 'https://github.com/example/Kit.git'\n", to: repository)
        let source = Source(url: repository.path)
        let cache = parent.appendingPathComponent("cache", isDirectory: true)
        XCTAssertEqual(
            try GitCatalog(cache: cache, runner: runner, update: false, offline: false)
                .entry(named: "Kit", in: [source])?.name,
            "Kit")

        let movedCache = parent.appendingPathComponent("moved-cache", isDirectory: true)
        let replacement = parent.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
        let sentinel = replacement.appendingPathComponent("sentinel")
        try Data("unchanged".utf8).write(to: sentinel)
        let rebindingRunner = CacheRebindingRunner(
            cache: cache, movedCache: movedCache, replacement: replacement)
        let catalog = GitCatalog(cache: cache, runner: rebindingRunner, update: false, offline: false)

        XCTAssertThrowsError(try catalog.entry(named: "Kit", in: [source])) { error in
            XCTAssertTrue("\(error)".contains("cache root changed"), "\(error)")
        }
        XCTAssertTrue(rebindingRunner.didRebind)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("unchanged".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: replacement.path), ["sentinel"])
    }

    func testCatalogCacheUsesCanonicalTargetAfterAnIntermediateSymlinkIsFlipped() throws {
        let parent = try temporaryDirectory("catalog-cache-intermediate-link")
        let repository = try repository(in: parent)
        _ = try publish("package 'Kit', git: 'https://github.com/example/Kit.git'\n", to: repository)
        let realParent = parent.appendingPathComponent("real-parent", isDirectory: true)
        let replacement = parent.appendingPathComponent("replacement-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
        let sentinel = replacement.appendingPathComponent("sentinel")
        try Data("unchanged".utf8).write(to: sentinel)
        let link = parent.appendingPathComponent("cache-parent", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realParent)
        let flippingRunner = IntermediateLinkFlippingRunner(link: link, replacement: replacement)
        let catalog = GitCatalog(
            cache: link.appendingPathComponent("cache", isDirectory: true),
            runner: flippingRunner, update: false, offline: false)

        XCTAssertEqual(
            try catalog.entry(named: "Kit", in: [Source(url: repository.path)])?.name,
            "Kit")
        XCTAssertTrue(flippingRunner.didFlip)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("unchanged".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: replacement.path), ["sentinel"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: realParent.appendingPathComponent("cache").path))
    }

    func testCatalogCacheRejectsAWorldWritableNonStickyAncestor() throws {
        let parent = try temporaryDirectory("catalog-cache-ancestor")
        let repository = try repository(in: parent)
        _ = try publish("package 'Kit', git: 'https://github.com/example/Kit.git'\n", to: repository)
        let shared = parent.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(shared.path, 0o777), 0)
        let catalog = GitCatalog(
            cache: shared.appendingPathComponent("cache"), runner: runner, update: false, offline: false)

        XCTAssertThrowsError(try catalog.entry(named: "Kit", in: [Source(url: repository.path)])) { error in
            XCTAssertTrue("\(error)".contains("writable non-sticky"), "\(error)")
        }
    }

    func testCatalogCacheRejectsAnUnsafeLexicalAncestorBeforeFollowingItsSymlink() throws {
        let parent = try temporaryDirectory("catalog-cache-lexical-ancestor")
        let repository = try repository(in: parent)
        _ = try publish("package 'Kit', git: 'https://github.com/example/Kit.git'\n", to: repository)
        let trusted = parent.appendingPathComponent("trusted", isDirectory: true)
        try FileManager.default.createDirectory(at: trusted, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(trusted.path, 0o700), 0)
        let sentinel = trusted.appendingPathComponent("sentinel")
        try Data("unchanged".utf8).write(to: sentinel)
        let shared = parent.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(shared.path, 0o777), 0)
        let link = shared.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: trusted)
        let catalog = GitCatalog(
            cache: link.appendingPathComponent("cache", isDirectory: true),
            runner: runner, update: false, offline: false)

        XCTAssertThrowsError(try catalog.entry(named: "Kit", in: [Source(url: repository.path)])) { error in
            XCTAssertTrue("\(error)".contains("writable non-sticky"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("unchanged".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trusted.path), ["sentinel"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: trusted.appendingPathComponent("cache").path))
    }

    func testCatalogCacheValidatesEverySymlinkHopBeforeCreatingItsCanonicalTarget() throws {
        let parent = try temporaryDirectory("catalog-cache-link-chain")
        let repository = try repository(in: parent)
        _ = try publish("package 'Kit', git: 'https://github.com/example/Kit.git'\n", to: repository)
        let trusted = parent.appendingPathComponent("trusted", isDirectory: true)
        try FileManager.default.createDirectory(at: trusted, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(trusted.path, 0o700), 0)
        let sentinel = trusted.appendingPathComponent("sentinel")
        try Data("unchanged".utf8).write(to: sentinel)
        let shared = parent.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(shared.path, 0o777), 0)
        let secondLink = shared.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: secondLink, withDestinationURL: trusted)
        let firstLink = parent.appendingPathComponent("first", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: firstLink, withDestinationURL: secondLink)
        let catalog = GitCatalog(
            cache: firstLink.appendingPathComponent("cache", isDirectory: true),
            runner: runner, update: false, offline: false)

        XCTAssertThrowsError(try catalog.entry(named: "Kit", in: [Source(url: repository.path)])) { error in
            XCTAssertTrue("\(error)".contains("writable non-sticky"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("unchanged".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trusted.path), ["sentinel"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: trusted.appendingPathComponent("cache").path))
    }

    func testCatalogCacheKeepsPrivateVarAsALexicalCanonicalPath() throws {
        let parent = try temporaryDirectory("catalog-cache-private-var")
        guard parent.path.hasPrefix("/var/") else {
            throw XCTSkip("This Darwin alias regression requires a /var temporary directory")
        }
        let repository = try repository(in: parent)
        _ = try publish("package 'Kit', git: 'https://github.com/example/Kit.git'\n", to: repository)
        let privateCache = URL(
            fileURLWithPath: "/private" + parent.path + "/cache", isDirectory: true)
        let catalog = GitCatalog(
            cache: privateCache, runner: runner, update: false, offline: false)

        XCTAssertEqual(
            try catalog.entry(named: "Kit", in: [Source(url: repository.path)])?.name,
            "Kit")
    }

    func testCatalogCacheAllowsAStandardDenyOnlyAncestorACL() throws {
        let parent = try temporaryDirectory("catalog-cache-deny-acl")
        let repository = try repository(in: parent)
        _ = try publish("package 'Kit', git: 'https://github.com/example/Kit.git'\n", to: repository)
        let ancestor = parent.appendingPathComponent("protected", isDirectory: true)
        try FileManager.default.createDirectory(at: ancestor, withIntermediateDirectories: false)
        _ = try runner.run("/bin/chmod", ["+a", "everyone deny delete", ancestor.path], in: nil)
        defer { _ = try? runner.run("/bin/chmod", ["-N", ancestor.path], in: nil) }
        let catalog = GitCatalog(
            cache: ancestor.appendingPathComponent("cache"), runner: runner, update: false, offline: false)

        XCTAssertEqual(
            try catalog.entry(named: "Kit", in: [Source(url: repository.path)])?.name,
            "Kit")
    }

    func testCatalogFetchHasARuntimeFileSizeLimitBeforePostFetchValidation() throws {
        let parent = try temporaryDirectory("catalog-runtime-budget")
        let repository = try repository(in: parent)
        let entry = "package 'Kit', git: 'https://github.com/example/Kit.git'\n"
        _ = try publish(entry, to: repository)
        var payload = Data(count: 2 * 1_024 * 1_024)
        payload.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var state: UInt64 = 0x9e37_79b9_7f4a_7c15
            for index in bytes.indices {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                bytes[index] = UInt8(truncatingIfNeeded: state)
            }
        }
        try payload.write(to: repository.appendingPathComponent("payload.bin"))
        _ = try runner.run("/usr/bin/git", ["add", "payload.bin"], in: repository)
        _ = try runner.run(
            "/usr/bin/git",
            ["-c", "user.name=SwiftPods Tests", "-c", "user.email=tests@swiftpods.invalid", "commit", "-q", "-m", "large"],
            in: repository)

        let source = Source(url: repository.path)
        let baseline = GitCatalog(
            cache: parent.appendingPathComponent("baseline-cache"), runner: runner, update: false, offline: false)
        XCTAssertEqual(try baseline.entry(named: "Kit", in: [source])?.name, "Kit")
        let lock = SwiftPodsLock(resolutions: baseline.resolutions)

        let constrainedCache = parent.appendingPathComponent("constrained-cache")
        let constrained = GitCatalog(
            cache: constrainedCache, runner: runner, update: false, offline: false,
            deploymentLock: lock, requiresLock: true, maximumFetchFileBytes: 32 * 1_024)
        XCTAssertThrowsError(try constrained.entry(named: "Kit", in: [source])) {
            XCTAssertTrue("\($0)".contains("runtime file-size budget"), "\($0)")
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: constrainedCache.path)
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".clone-") || $0.hasSuffix(".git") }, "\(leftovers)")
    }

    func testCatalogFetchesShareOneAggregateDiskBudgetPerRun() throws {
        let parent = try temporaryDirectory("catalog-aggregate-budget")
        let first = try repository(in: parent, name: "first")
        let second = try repository(in: parent, name: "second")
        _ = try publish(
            "package 'Other', git: 'https://github.com/example/Other.git'\n",
            to: first, name: "Other")
        _ = try publish(
            "package 'Kit', git: 'https://github.com/example/Kit.git'\n",
            to: second)

        let firstSource = Source(url: first.path)
        let secondSource = Source(url: second.path)
        let baselineCache = parent.appendingPathComponent("baseline-cache", isDirectory: true)
        let baseline = GitCatalog(
            cache: baselineCache, runner: runner, update: false, offline: false)
        XCTAssertEqual(try baseline.entry(named: "Other", in: [firstSource])?.name, "Other")
        let baselineRepositories = try FileManager.default.contentsOfDirectory(
            at: baselineCache, includingPropertiesForKeys: nil).filter { $0.pathExtension == "git" }
        XCTAssertEqual(baselineRepositories.count, 1, "\(baselineRepositories)")
        let firstFetchBytes = try diskFootprint(of: XCTUnwrap(baselineRepositories.first))
        XCTAssertGreaterThan(firstFetchBytes, 0)

        let constrainedCache = parent.appendingPathComponent("constrained-cache", isDirectory: true)
        let constrained = GitCatalog(
            cache: constrainedCache, runner: runner, update: false, offline: false,
            maximumAggregateFetchBytes: firstFetchBytes)
        XCTAssertThrowsError(try constrained.entry(named: "Kit", in: [firstSource, secondSource])) {
            XCTAssertTrue("\($0)".contains("aggregate disk budget for this run"), "\($0)")
        }

        let installed = try FileManager.default.contentsOfDirectory(
            at: constrainedCache, includingPropertiesForKeys: nil)
        XCTAssertEqual(installed.filter { $0.pathExtension == "git" }.count, 1, "\(installed)")
        XCTAssertFalse(installed.contains { $0.lastPathComponent.hasPrefix(".clone-") }, "\(installed)")
    }

    func testPersistentCatalogCacheEvictsTheLeastRecentlyUsedRepository() throws {
        let parent = try temporaryDirectory("catalog-persistent-quota")
        let first = try repository(in: parent, name: "first")
        let second = try repository(in: parent, name: "second")
        _ = try publish(
            "package 'Other', git: 'https://github.com/example/Other.git'\n",
            to: first, name: "Other")
        _ = try publish(
            "package 'Kit', git: 'https://github.com/example/Kit.git'\n",
            to: second)
        let cache = parent.appendingPathComponent("cache", isDirectory: true)
        let firstSource = Source(url: first.path)
        let secondSource = Source(url: second.path)
        let initial = GitCatalog(
            cache: cache, runner: runner, update: false, offline: false,
            maximumPersistentRepositories: 1)
        XCTAssertEqual(try initial.entry(named: "Other", in: [firstSource])?.name, "Other")
        let firstCached = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: cache, includingPropertiesForKeys: nil).first { $0.pathExtension == "git" })
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: firstCached.path)

        let replacement = GitCatalog(
            cache: cache, runner: runner, update: false, offline: false,
            maximumPersistentRepositories: 1)
        XCTAssertEqual(try replacement.entry(named: "Kit", in: [secondSource])?.name, "Kit")
        let repositories = try FileManager.default.contentsOfDirectory(
            at: cache, includingPropertiesForKeys: nil).filter { $0.pathExtension == "git" }
        XCTAssertEqual(repositories.count, 1, "\(repositories)")

        let missing = GitCatalog(
            cache: cache, runner: runner, update: false, offline: true,
            maximumPersistentRepositories: 1)
        XCTAssertThrowsError(try missing.entry(named: "Other", in: [firstSource])) {
            XCTAssertTrue("\($0)".contains("is not cached"), "\($0)")
        }
    }

    func testCatalogRejectsUnsafeGitTreePathsWithoutReflectingThem() throws {
        let parent = try temporaryDirectory("catalog-unsafe-tree-path")
        let repository = try repository(in: parent)
        let injected = "untrusted\n::error title=Catalog injection::payload"
        let directory = repository.appendingPathComponent("Packages").appendingPathComponent(injected)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try "package 'Kit', git: 'https://github.com/example/Kit.git'\n".write(
            to: directory.appendingPathComponent("Kit.podfile"), atomically: true, encoding: .utf8)
        _ = try runner.run("/usr/bin/git", ["add", "-A"], in: repository)
        _ = try runner.run(
            "/usr/bin/git",
            ["-c", "user.name=SwiftPods Tests", "-c", "user.email=tests@swiftpods.invalid", "commit", "-q", "-m", "unsafe"],
            in: repository)

        let catalog = GitCatalog(
            cache: parent.appendingPathComponent("cache"), runner: runner, update: false, offline: false)
        XCTAssertThrowsError(try catalog.entry(named: "Kit", in: [Source(url: repository.path)])) { error in
            let diagnostic = "\(error)"
            XCTAssertTrue(diagnostic.contains("unsafe Git tree path"), diagnostic)
            XCTAssertFalse(diagnostic.contains("Catalog injection"), diagnostic)
            XCTAssertFalse(diagnostic.contains("::error"), diagnostic)
            XCTAssertFalse(diagnostic.contains("\n"), diagnostic)
        }
    }

    func testBroadCatalogSearchStopsBeforeReadingAnyEntryBlob() throws {
        let parent = try temporaryDirectory("catalog-search-budget")
        let repository = try repository(in: parent)
        for index in 0...256 {
            let name = "Kit\(index)"
            try "package '\(name)', git: 'https://github.com/example/\(name).git'\n".write(
                to: repository.appendingPathComponent("Packages/\(name).podfile"), atomically: true, encoding: .utf8)
        }
        _ = try runner.run("/usr/bin/git", ["add", "-A"], in: repository)
        _ = try runner.run(
            "/usr/bin/git",
            ["-c", "user.name=SwiftPods Tests", "-c", "user.email=tests@swiftpods.invalid", "commit", "-q", "-m", "search"],
            in: repository)
        let recording = RecordingRunner()

        XCTAssertThrowsError(try CatalogTools.search(
            "Kit", sources: [Source(url: repository.path)], runner: recording,
            cache: parent.appendingPathComponent("cache"), update: false
        )) { error in
            XCTAssertTrue("\(error)".contains("more than 256 packages"), "\(error)")
        }
        XCTAssertFalse(
            recording.invocations.contains(where: { $0.contains("cat-file") }),
            "The match cap must be checked before catalog entry blobs are read")
    }

    func testCatalogSearchWithinBudgetReadsOnlyMatchingEntries() throws {
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

    func testLockWriteRejectsSymlinksAndAFileChangedSinceRead() throws {
        let directory = try temporaryDirectory("lock-cas")
        let file = directory.appendingPathComponent(SwiftPodsLock.fileName)
        let lock = SwiftPodsLock(resolutions: [])
        try lock.write(to: file)
        let observed = try SwiftPodsLock.read(at: file)
        var concurrentContents = try Data(contentsOf: file)
        concurrentContents.append(contentsOf: " \n".utf8)
        try concurrentContents.write(to: file)

        XCTAssertThrowsError(try lock.write(to: file, replacing: observed.state)) {
            XCTAssertTrue("\($0)".contains("changed after it was read"), "\($0)")
        }
        XCTAssertEqual(try Data(contentsOf: file), concurrentContents)
        XCTAssertThrowsError(try SwiftPodsLock.remove(at: file, replacing: observed.state)) {
            XCTAssertTrue("\($0)".contains("changed after it was read"), "\($0)")
        }
        XCTAssertEqual(try Data(contentsOf: file), concurrentContents)

        try FileManager.default.removeItem(at: file)
        let victim = directory.appendingPathComponent("victim")
        let victimContents = Data("do not replace\n".utf8)
        try victimContents.write(to: victim)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: victim)
        XCTAssertThrowsError(try lock.write(to: file))
        XCTAssertEqual(try Data(contentsOf: victim), victimContents)
    }

    func testDeploymentLockVerificationRejectsAPathSwapDuringItsFinalRead() throws {
        let directory = try temporaryDirectory("lock-final-read-race")
        let file = directory.appendingPathComponent(SwiftPodsLock.fileName)
        let displaced = directory.appendingPathComponent("displaced.lock")
        let lock = SwiftPodsLock(resolutions: [])
        try lock.write(to: file)
        let observed = try SwiftPodsLock.read(at: file)
        let concurrent = Data("concurrent evidence\n".utf8)

        XCTAssertThrowsError(
            try SwiftPodsLock.verifyUnchanged(
                at: file, since: observed.state,
                _beforeFinalPathCheck: {
                    try FileManager.default.moveItem(at: file, to: displaced)
                    try concurrent.write(to: file)
                })
        ) { error in
            XCTAssertTrue("\(error)".contains("changed after it was read"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: file), concurrent)

        let absent = directory.appendingPathComponent("Absent.lock")
        let absentState = try SwiftPodsLock.deferredRead(at: absent).replacementState()
        XCTAssertThrowsError(
            try SwiftPodsLock.verifyUnchanged(
                at: absent, since: absentState,
                _beforeFinalPathCheck: { try concurrent.write(to: absent) })
        ) { error in
            XCTAssertTrue("\(error)".contains("changed after it was read"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: absent), concurrent)
    }

    func testLockWriteAndRemovalRejectAParentPathSwapBeforeReturning() throws {
        let root = try temporaryDirectory("lock-parent-race")
        let lock = SwiftPodsLock(resolutions: [])
        let sentinel = Data("concurrent directory\n".utf8)

        func makeCase(_ name: String) throws -> (directory: URL, file: URL, state: SwiftPodsLock.FileState) {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let file = directory.appendingPathComponent(SwiftPodsLock.fileName)
            try lock.write(to: file)
            return (directory, file, try SwiftPodsLock.read(at: file).state)
        }

        let writeCase = try makeCase("write")
        let movedWrite = root.appendingPathComponent("write-moved", isDirectory: true)
        XCTAssertThrowsError(
            try lock.write(
                to: writeCase.file, replacing: writeCase.state,
                _beforeFinalPathCheck: {
                    try FileManager.default.moveItem(at: writeCase.directory, to: movedWrite)
                    try FileManager.default.createDirectory(at: writeCase.directory, withIntermediateDirectories: false)
                    try sentinel.write(to: writeCase.file)
                })
        ) { error in
            XCTAssertTrue("\(error)".contains("changed after it was read"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: writeCase.file), sentinel)

        let removeCase = try makeCase("remove")
        let movedRemove = root.appendingPathComponent("remove-moved", isDirectory: true)
        XCTAssertThrowsError(
            try SwiftPodsLock.remove(
                at: removeCase.file, replacing: removeCase.state,
                _beforeFinalPathCheck: {
                    try FileManager.default.moveItem(at: removeCase.directory, to: movedRemove)
                    try FileManager.default.createDirectory(at: removeCase.directory, withIntermediateDirectories: false)
                    try sentinel.write(to: removeCase.file)
                })
        ) { error in
            XCTAssertTrue("\(error)".contains("changed after it was read"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: removeCase.file), sentinel)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: movedRemove.appendingPathComponent(SwiftPodsLock.fileName).path))
    }

    func testDeploymentRejectsMissingOrChangedCatalogEvidence() throws {
        let parent = try temporaryDirectory("catalog-evidence")
        let repository = try repository(in: parent)
        let text = "package 'Kit', git: 'https://github.com/example/Kit.git'\n"
        _ = try publish(text, to: repository)
        let source = Source(url: repository.path)
        let cache = parent.appendingPathComponent("cache")

        let missing = GitCatalog(
            cache: cache, runner: runner, update: false, offline: false,
            deploymentLock: nil, requiresLock: true)
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
            deploymentLock: changed, requiresLock: true)
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
            deploymentLock: lock, requiresLock: true)
        XCTAssertEqual(try deployment.entry(named: "Kit", in: sources)?.url, "https://github.com/example/selected.git")
        XCTAssertEqual(lock.problems(comparedTo: SwiftPodsLock(resolutions: deployment.resolutions)), [])
    }

    func testCacheUsesExactOriginAndRejectsAnOriginRewriteOffline() throws {
        let parent = try temporaryDirectory("catalog-origin")
        let firstParent = parent.appendingPathComponent("one")
        let secondParent = parent.appendingPathComponent("two")
        try FileManager.default.createDirectory(at: firstParent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondParent, withIntermediateDirectories: true)
        let first = try repository(in: firstParent)
        let second = try repository(in: secondParent)
        _ = try publish("package 'Kit', git: 'https://github.com/example/one.git'\n", to: first)
        _ = try publish("package 'Kit', git: 'https://github.com/example/two.git'\n", to: second)
        let cache = parent.appendingPathComponent("cache")

        let catalog = GitCatalog(cache: cache, runner: runner, update: false, offline: false)
        XCTAssertEqual(try catalog.entry(named: "Kit", in: [Source(url: first.path)])?.url, "https://github.com/example/one.git")
        XCTAssertEqual(try catalog.entry(named: "Kit", in: [Source(url: second.path)])?.url, "https://github.com/example/two.git")
        let repositories = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "git" }
        XCTAssertEqual(repositories.count, 2, "Origins with the same repository name must never share a cache")

        let firstCache = try XCTUnwrap(repositories.first { repository in
            (try? runner.run("/usr/bin/git", ["-C", repository.path, "remote", "get-url", "origin"], in: nil)
                .trimmingCharacters(in: .whitespacesAndNewlines)) == first.path
        })
        _ = try runner.run("/usr/bin/git", ["-C", firstCache.path, "remote", "set-url", "origin", second.path], in: nil)
        let offline = GitCatalog(cache: cache, runner: runner, update: false, offline: true)
        XCTAssertThrowsError(try offline.entry(named: "Kit", in: [Source(url: first.path)])) {
            XCTAssertTrue("\($0)".contains("clean exact-origin"), "\($0)")
        }

        let repaired = GitCatalog(cache: cache, runner: runner, update: false, offline: false)
        XCTAssertEqual(try repaired.entry(named: "Kit", in: [Source(url: first.path)])?.url, "https://github.com/example/one.git")

        let commit = try runner.run("/usr/bin/git", ["-C", firstCache.path, "rev-parse", "HEAD"], in: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try runner.run(
            "/usr/bin/git", ["-C", firstCache.path, "update-ref", "refs/replace/" + commit, commit], in: nil)
        let replacements = GitCatalog(cache: cache, runner: runner, update: false, offline: true)
        XCTAssertThrowsError(try replacements.entry(named: "Kit", in: [Source(url: first.path)])) {
            XCTAssertTrue("\($0)".contains("replacement objects"), "\($0)")
        }
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
        XCTAssertEqual(sharedRunner.maximumConcurrentClones, 1)
    }

    func testLintBoundsAndStrictlyDecodesLocalCatalogEntries() throws {
        let parent = try temporaryDirectory("catalog-lint-bounds")
        let repository = try repository(in: parent)
        let entry = repository.appendingPathComponent("Packages/Huge.podfile")
        try Data(repeating: 0x61, count: 1024 * 1024 + 1).write(to: entry)
        XCTAssertTrue(CatalogTools.lint(repository).contains { $0.contains("larger than 1048576 bytes") })

        var invalid = Data("package 'Invalid', git: 'https://github.com/example/Invalid.git'\n# ".utf8)
        invalid.append(0xFF)
        try invalid.write(to: entry)
        XCTAssertTrue(CatalogTools.lint(repository).contains { $0.contains("not valid UTF-8") })

        var deeplyNested = repository.appendingPathComponent("Packages")
        for index in 0..<33 {
            deeplyNested.appendPathComponent("level-\(index)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: deeplyNested, withIntermediateDirectories: true)
        try "package 'Deep', git: 'https://github.com/example/Deep.git'\n"
            .write(to: deeplyNested.appendingPathComponent("Deep.podfile"), atomically: true, encoding: .utf8)
        XCTAssertTrue(CatalogTools.lint(repository).contains { $0.contains("nested more than 32 levels") })
    }

    func testLintDoesNotSkipHiddenOrLinkedDirectories() throws {
        let parent = try temporaryDirectory("catalog-lint-hidden")
        let repository = try repository(in: parent)
        let packages = repository.appendingPathComponent("Packages", isDirectory: true)
        try Data("not a podfile\n".utf8).write(to: packages.appendingPathComponent(".hidden"))
        try Data("not a podfile\n".utf8).write(to: packages.appendingPathComponent("bad\nname"))

        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try "package 'Escaped', git: 'https://github.com/example/Escaped.git'\n"
            .write(to: outside.appendingPathComponent("Escaped.podfile"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: packages.appendingPathComponent("Linked", isDirectory: true), withDestinationURL: outside)

        let problems = CatalogTools.lint(repository)
        XCTAssertTrue(problems.contains { $0.contains(".hidden: catalog files end in .podfile") }, "\(problems)")
        XCTAssertTrue(problems.contains {
            $0 == "Packages contains a catalog entry name with controls, backslashes, or more than 4096 bytes"
        }, "\(problems)")
        XCTAssertFalse(problems.contains { $0.contains("bad\nname") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("Linked: catalog entries cannot be symbolic links") }, "\(problems)")
        XCTAssertFalse(problems.contains { $0.contains("Escaped") }, "\(problems)")
    }
}
