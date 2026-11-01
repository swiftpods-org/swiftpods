import CryptoKit
import Darwin
import Foundation
@testable import SwiftPodsKit
import SwiftPodsManifest
import SwiftPodsTestSupport
import XCTest

final class PathArchiveSecurityTests: XCTestCase {
    private final class FailingDownloadClient: BinaryDownloadClient, @unchecked Sendable {
        let transient: Bool
        private let lock = NSLock()
        private var calls = 0
        private var timeouts: [TimeInterval] = []
        private var urls: [URL] = []

        init(transient: Bool = false) { self.transient = transient }

        var invocationCount: Int { lock.withLock { calls } }
        var recordedTimeouts: [TimeInterval] { lock.withLock { timeouts } }
        var requestedURLs: [URL] { lock.withLock { urls } }

        func download(
            from url: URL, to destination: URL, maximumBytes: Int64, timeout: TimeInterval
        ) throws -> BinaryDownloadResult {
            lock.withLock {
                calls += 1
                timeouts.append(timeout)
                urls.append(url)
            }
            Thread.sleep(forTimeInterval: 0.002)
            throw BinaryDownloadFailure("injected download failure", transient: transient)
        }
    }

    private final class ArchiveDownloadClient: BinaryDownloadClient, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var archives: [String: Data] = [:]

        var invocationCount: Int { lock.withLock { calls } }

        func add(_ data: Data, for url: URL) { lock.withLock { archives[url.absoluteString] = data } }

        func download(
            from url: URL, to destination: URL, maximumBytes: Int64, timeout: TimeInterval
        ) throws -> BinaryDownloadResult {
            let data = try lock.withLock { () throws -> Data in
                calls += 1
                guard let data = archives[url.absoluteString] else {
                    throw BinaryDownloadFailure("missing test archive")
                }
                return data
            }
            guard data.count <= maximumBytes else { throw BinaryDownloadFailure("test archive too large") }
            try data.write(to: destination, options: .withoutOverwriting)
            return BinaryDownloadResult(storedBytes: Int64(data.count), transferredBytes: Int64(data.count))
        }
    }

    private final class CacheRebindingDownloadClient: BinaryDownloadClient, @unchecked Sendable {
        let archive: Data
        let cache: URL
        let movedCache: URL
        let replacement: URL

        init(archive: Data, cache: URL, movedCache: URL, replacement: URL) {
            self.archive = archive
            self.cache = cache
            self.movedCache = movedCache
            self.replacement = replacement
        }

        func download(
            from url: URL, to destination: URL, maximumBytes: Int64, timeout: TimeInterval
        ) throws -> BinaryDownloadResult {
            guard archive.count <= maximumBytes else { throw BinaryDownloadFailure("test archive too large") }
            try archive.write(to: destination, options: .withoutOverwriting)
            guard rename(cache.path, movedCache.path) == 0 else {
                throw SwiftPodsError("Test could not move the authenticated cache root")
            }
            try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: replacement)
            return BinaryDownloadResult(
                storedBytes: Int64(archive.count), transferredBytes: Int64(archive.count))
        }
    }

    private final class StagingRebindingDownloadClient: BinaryDownloadClient, @unchecked Sendable {
        private let archive: Data
        private let lock = NSLock()
        private var replacementDirectory: URL?

        init(archive: Data) { self.archive = archive }

        var replacement: URL? { lock.withLock { replacementDirectory } }

        func download(
            from url: URL, to destination: URL, maximumBytes: Int64, timeout: TimeInterval
        ) throws -> BinaryDownloadResult {
            guard archive.count <= maximumBytes else { throw BinaryDownloadFailure("test archive too large") }
            try archive.write(to: destination, options: .withoutOverwriting)
            let staging = destination.deletingLastPathComponent()
            let moved = staging.deletingLastPathComponent()
                .appendingPathComponent(".attacker-moved-" + UUID().uuidString, isDirectory: true)
            guard rename(staging.path, moved.path) == 0 else {
                throw SwiftPodsError("Test could not move the retained staging directory")
            }
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            guard chmod(staging.path, 0o700) == 0 else {
                throw SwiftPodsError("Test could not secure the replacement staging directory")
            }
            try archive.write(to: destination, options: .withoutOverwriting)
            lock.withLock { replacementDirectory = staging }
            return BinaryDownloadResult(
                storedBytes: Int64(archive.count), transferredBytes: Int64(archive.count))
        }
    }

    private final class CountingProcessRunner: CommandRunner, @unchecked Sendable {
        private let delegate = ProcessRunner()
        private let lock = NSLock()
        private var calls: [String: Int] = [:]
        private var argumentLists: [[String]] = []

        func count(_ executable: String) -> Int { lock.withLock { calls[executable, default: 0] } }
        var allArguments: [[String]] { lock.withLock { argumentLists } }

        func run(_ executable: String, _ arguments: [String], in directory: URL?) throws -> String {
            lock.withLock {
                calls[executable, default: 0] += 1
                argumentLists.append(arguments)
            }
            return try delegate.run(executable, arguments, in: directory)
        }

        func run(
            _ executable: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval
        ) throws -> String {
            lock.withLock {
                calls[executable, default: 0] += 1
                argumentLists.append(arguments)
            }
            return try delegate.run(executable, arguments, in: directory, timeout: timeout)
        }

        func runData(
            _ executable: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval,
            maximumOutputBytes: Int, passingFileDescriptors: [Int32]
        ) throws -> Data {
            lock.withLock {
                calls[executable, default: 0] += 1
                argumentLists.append(arguments)
            }
            return try delegate.runData(
                executable, arguments, in: directory, timeout: timeout, maximumOutputBytes: maximumOutputBytes,
                passingFileDescriptors: passingFileDescriptors)
        }
    }

    /// Simulates curl while inspecting the descriptor-backed config synchronously, before the downloader closes it.
    private final class PinnedCurlRunner: CommandRunner, @unchecked Sendable {
        struct Response {
            let status: Int
            let headers: [String: String]
            let body: Data

            init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
                self.status = status
                self.headers = headers
                self.body = body
            }
        }

        private let delegate = ProcessRunner()
        private let lock = NSLock()
        private var responses: [Response]
        private var curlArguments: [[String]] = []
        private var curlConfigurations: [String] = []
        private var curlTimeouts: [TimeInterval] = []

        init(_ responses: [Response]) { self.responses = responses }

        var arguments: [[String]] { lock.withLock { curlArguments } }
        var configurations: [String] { lock.withLock { curlConfigurations } }
        var timeouts: [TimeInterval] { lock.withLock { curlTimeouts } }

        func run(_ executable: String, _ arguments: [String], in directory: URL?) throws -> String {
            try run(executable, arguments, in: directory, timeout: 30 * 60)
        }

        func run(
            _ executable: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval
        ) throws -> String {
            String(decoding: try runData(
                executable, arguments, in: directory, timeout: timeout, maximumOutputBytes: 64 * 1024 * 1024,
                passingFileDescriptors: []), as: UTF8.self)
        }

        func runData(
            _ executable: String, _ arguments: [String], in directory: URL?, timeout: TimeInterval,
            maximumOutputBytes: Int, passingFileDescriptors: [Int32]
        ) throws -> Data {
            guard executable == "/bin/sh" else {
                return try delegate.runData(
                    executable, arguments, in: directory, timeout: timeout, maximumOutputBytes: maximumOutputBytes,
                    passingFileDescriptors: passingFileDescriptors)
            }
            guard arguments.count == 5, arguments[0] == "-c", arguments[2] == "swiftpods-curl",
                Int64(arguments[3]) != nil
            else { throw SwiftPodsError("Pinned curl test did not receive a config descriptor") }
            let configuration = try String(
                contentsOf: URL(fileURLWithPath: arguments[4]), encoding: .utf8)
            let response = try lock.withLock { () throws -> Response in
                guard !responses.isEmpty else { throw SwiftPodsError("Pinned curl test ran out of responses") }
                curlArguments.append(arguments)
                curlConfigurations.append(configuration)
                curlTimeouts.append(timeout)
                return responses.removeFirst()
            }
            guard let output = Self.quotedValue("output", in: configuration),
                let outputDescriptor = Int32(URL(fileURLWithPath: output).lastPathComponent),
                passingFileDescriptors.contains(outputDescriptor)
            else { throw SwiftPodsError("Pinned curl test received an invalid descriptor config") }
            try Self.write(response.body, to: outputDescriptor)
            let fields = response.headers.map { "\($0.key): \($0.value)\r\n" }.joined()
            let headerData = Data("HTTP/1.1 \(response.status) Test\r\n\(fields)\r\n".utf8)
            guard headerData.count <= maximumOutputBytes else {
                throw SwiftPodsError("Pinned curl test exceeded its output limit")
            }
            return headerData
        }

        private static func quotedValue(_ name: String, in configuration: String) -> String? {
            let prefix = name + " = \""
            guard let line = configuration.split(separator: "\n", omittingEmptySubsequences: false)
                .first(where: { $0.hasPrefix(prefix) }), line.hasSuffix("\"")
            else { return nil }
            return String(line.dropFirst(prefix.count).dropLast())
        }

        private static func write(_ data: Data, to descriptor: Int32) throws {
            guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) == 0 else {
                throw SwiftPodsError("Pinned curl test cannot reset descriptor")
            }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count > 0 { offset += count; continue }
                    if count < 0, errno == EINTR { continue }
                    throw SwiftPodsError("Pinned curl test cannot write descriptor")
                }
            }
        }
    }

    private final class BlockingArchiveDownloadClient: BinaryDownloadClient, @unchecked Sendable {
        private let archive: Data
        private let lock = NSLock()
        private var calls = 0
        let firstDownloadStarted = DispatchSemaphore(value: 0)
        let releaseFirstDownload = DispatchSemaphore(value: 0)

        init(archive: Data) { self.archive = archive }

        var invocationCount: Int { lock.withLock { calls } }

        func download(
            from url: URL, to destination: URL, maximumBytes: Int64, timeout: TimeInterval
        ) throws -> BinaryDownloadResult {
            guard archive.count <= maximumBytes else { throw BinaryDownloadFailure("test archive too large") }
            let first = lock.withLock { () -> Bool in
                calls += 1
                return calls == 1
            }
            try archive.write(to: destination, options: .withoutOverwriting)
            if first {
                firstDownloadStarted.signal()
                guard releaseFirstDownload.wait(timeout: .now() + 5) == .success else {
                    throw BinaryDownloadFailure("timed out waiting to release test download")
                }
            }
            return BinaryDownloadResult(
                storedBytes: Int64(archive.count), transferredBytes: Int64(archive.count))
        }
    }

    private final class StoreBox: @unchecked Sendable {
        let store: BinaryStore
        init(_ store: BinaryStore) { self.store = store }
    }

    private final class ConcurrentContentResults: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        private var leases: [BinaryStore.SnapshotLease] = []
        private var failures: [String] = []

        func append(_ operation: () throws -> BinaryStore.Contents) {
            do {
                let contents = try operation()
                lock.withLock {
                    names += contents.xcframeworks.map(\.lastPathComponent)
                    if let lease = contents.snapshotLease { leases.append(lease) }
                }
            } catch {
                lock.withLock { failures.append("\(error)") }
            }
        }

        var snapshot: (names: [String], leases: [BinaryStore.SnapshotLease], failures: [String]) {
            lock.withLock { (names, leases, failures) }
        }
    }

    private final class ProcessRunResult: @unchecked Sendable {
        private let lock = NSLock()
        private var storedFailure: String?
        let completion = DispatchSemaphore(value: 0)

        var failure: String? { lock.withLock { storedFailure } }

        func run(_ operation: () throws -> Void) {
            defer { completion.signal() }
            do {
                try operation()
            } catch {
                lock.withLock { storedFailure = "\(error)" }
            }
        }
    }

    private struct TarEntry {
        let name: String
        let type: UInt8
        let link: String
        let contents: Data
        let mode: Int

        static func file(_ name: String, _ text: String, mode: Int = 0o644) -> TarEntry {
            TarEntry(name: name, type: 0x30, link: "", contents: Data(text.utf8), mode: mode)
        }

        static func symlink(_ name: String, to destination: String) -> TarEntry {
            TarEntry(name: name, type: 0x32, link: destination, contents: Data(), mode: 0o777)
        }

        static func hardlink(_ name: String, to destination: String) -> TarEntry {
            TarEntry(name: name, type: 0x31, link: destination, contents: Data(), mode: 0o644)
        }
    }

    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    private func fixture(_ podfile: String = "target 'App' do\nend\n") throws -> URL {
        let directory = try Fixtures.directory(podfile: podfile)
        directories.append(directory)
        return directory
    }

    private func builtSwiftPodsExecutable() throws -> URL {
        var capacity = max(Int(PATH_MAX), 4_096)
        while capacity <= 1 * 1_024 * 1_024 {
            var buffer = [CChar](repeating: 0, count: capacity)
            var size = UInt32(buffer.count)
            let result = buffer.withUnsafeMutableBufferPointer {
                _NSGetExecutablePath($0.baseAddress, &size)
            }
            if result == 0 {
                let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                var current = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
                while current.path != "/", current.pathExtension != "xctest" {
                    current.deleteLastPathComponent()
                }
                let loaded = Bundle.allBundles.map(\.bundleURL).filter { $0.pathExtension == "xctest" }
                guard let testBundle = current.pathExtension == "xctest"
                    ? current : (loaded.count == 1 ? loaded[0] : nil)
                else {
                    throw SwiftPodsError("Test host is not inside an xctest bundle")
                }
                let executable = testBundle.deletingLastPathComponent().appendingPathComponent("swiftpods")
                guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                    throw SwiftPodsError("Built swiftpods executable is unavailable beside the xctest bundle")
                }
                return executable
            }
            guard size > UInt32(capacity) else { break }
            capacity = Int(size)
        }
        throw SwiftPodsError("Cannot resolve the test host executable")
    }

    private func makeXCFramework(_ url: URL, name: String, frameworkInfo: Bool = true) throws -> URL {
        let framework = url.appendingPathComponent("ios-arm64/\(name).framework", isDirectory: true)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "AvailableLibraries": [[
                "LibraryIdentifier": "ios-arm64", "LibraryPath": "\(name).framework",
                "SupportedArchitectures": ["arm64"], "SupportedPlatform": "ios",
            ]],
            "CFBundlePackageType": "XFWK", "XCFrameworkFormatVersion": "1.0",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Info.plist"))
        if frameworkInfo {
            try Data("plist".utf8).write(to: framework.appendingPathComponent("Info.plist"))
        }
        return framework
    }

    private func tar(_ entries: [TarEntry]) throws -> Data {
        func field(_ text: String, width: Int) throws -> [UInt8] {
            let bytes = Array(text.utf8)
            guard bytes.count < width else { throw CocoaError(.fileWriteInvalidFileName) }
            return bytes + Array(repeating: 0, count: width - bytes.count)
        }
        func octal(_ value: Int, width: Int, checksum: Bool = false) -> [UInt8] {
            let digits = String(value, radix: 8)
            let count = width - digits.count - (checksum ? 2 : 1)
            return Array((String(repeating: "0", count: count) + digits).utf8) + (checksum ? [0, 0x20] : [0])
        }

        var result = Data()
        for entry in entries {
            var header = Data(repeating: 0, count: 512)
            header.replaceSubrange(0..<100, with: try field(entry.name, width: 100))
            header.replaceSubrange(100..<108, with: octal(entry.mode, width: 8))
            header.replaceSubrange(108..<116, with: octal(0, width: 8))
            header.replaceSubrange(116..<124, with: octal(0, width: 8))
            header.replaceSubrange(124..<136, with: octal(entry.contents.count, width: 12))
            header.replaceSubrange(136..<148, with: octal(0, width: 12))
            header.replaceSubrange(148..<156, with: Array(repeating: 0x20, count: 8))
            header[156] = entry.type
            header.replaceSubrange(157..<257, with: try field(entry.link, width: 100))
            header.replaceSubrange(257..<263, with: [0x75, 0x73, 0x74, 0x61, 0x72, 0])
            header.replaceSubrange(263..<265, with: [0x30, 0x30])
            let checksum = header.reduce(0) { $0 + Int($1) }
            header.replaceSubrange(148..<156, with: octal(checksum, width: 8, checksum: true))
            result.append(header)
            result.append(entry.contents)
            let padding = (512 - entry.contents.count % 512) % 512
            result.append(Data(repeating: 0, count: padding))
        }
        result.append(Data(repeating: 0, count: 1024))
        return result
    }

    private func rewriteTarChecksum(_ archive: inout Data, headerOffset: Int = 0) {
        archive.replaceSubrange(headerOffset + 148..<headerOffset + 156, with: Array(repeating: 0x20, count: 8))
        let checksum = archive[headerOffset..<headerOffset + 512].reduce(0) { $0 + Int($1) }
        archive.replaceSubrange(
            headerOffset + 148..<headerOffset + 156,
            with: Array(String(format: "%06o", checksum).utf8) + [0, 0x20])
    }

    private func rewriteTarDeclaredSize(_ archive: inout Data, size: Int) {
        let digits = String(size, radix: 8)
        precondition(digits.count < 12)
        archive.replaceSubrange(
            124..<136,
            with: Array((String(repeating: "0", count: 11 - digits.count) + digits).utf8) + [0])
        rewriteTarChecksum(&archive)
    }

    private func paxTar(path: String, contents: String) throws -> Data {
        let body = "path=\(path)\n"
        var length = body.utf8.count + 2
        while true {
            let record = "\(length) \(body)"
            let actual = record.utf8.count
            if actual == length {
                return try tar([
                    TarEntry(name: "PaxHeader", type: 0x78, link: "", contents: Data(record.utf8), mode: 0o600),
                    .file("placeholder", contents),
                ])
            }
            length = actual
        }
    }

    private func emptyZIP(entryCount: Int) throws -> Data {
        guard entryCount > 0, entryCount <= Int(UInt16.max) else {
            throw CocoaError(.fileWriteUnknown)
        }
        func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
            var encoded = value.littleEndian
            withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
        }

        var local = Data()
        var central = Data()
        for index in 0..<entryCount {
            let name = Data(String(format: "entry-%05d", index).utf8)
            let offset = local.count
            appendLittleEndian(UInt32(0x0403_4b50), to: &local)
            appendLittleEndian(UInt16(20), to: &local)
            for value in [UInt16(0), 0, 0, 0] { appendLittleEndian(value, to: &local) }
            for value in [UInt32(0), 0, 0] { appendLittleEndian(value, to: &local) }
            appendLittleEndian(UInt16(name.count), to: &local)
            appendLittleEndian(UInt16(0), to: &local)
            local.append(name)

            appendLittleEndian(UInt32(0x0201_4b50), to: &central)
            appendLittleEndian(UInt16(20), to: &central)
            appendLittleEndian(UInt16(20), to: &central)
            for value in [UInt16(0), 0, 0, 0] { appendLittleEndian(value, to: &central) }
            for value in [UInt32(0), 0, 0] { appendLittleEndian(value, to: &central) }
            appendLittleEndian(UInt16(name.count), to: &central)
            for value in [UInt16(0), 0, 0, 0] { appendLittleEndian(value, to: &central) }
            appendLittleEndian(UInt32(0), to: &central)
            appendLittleEndian(UInt32(offset), to: &central)
            central.append(name)
        }
        let centralOffset = local.count
        local.append(central)
        appendLittleEndian(UInt32(0x0605_4b50), to: &local)
        appendLittleEndian(UInt16(0), to: &local)
        appendLittleEndian(UInt16(0), to: &local)
        appendLittleEndian(UInt16(entryCount), to: &local)
        appendLittleEndian(UInt16(entryCount), to: &local)
        appendLittleEndian(UInt32(central.count), to: &local)
        appendLittleEndian(UInt32(centralOffset), to: &local)
        appendLittleEndian(UInt16(0), to: &local)
        return local
    }

    private func newcCPIO(name: String, contents: Data) throws -> Data {
        func appendEntry(_ name: String, mode: UInt32, contents: Data, to archive: inout Data) throws {
            let nameBytes = Data(name.utf8) + Data([0])
            guard nameBytes.count <= Int(UInt32.max), contents.count <= Int(UInt32.max) else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            let fields: [UInt32] = [
                1, mode, 0, 0, 1, 0, UInt32(contents.count), 0, 0, 0, 0, UInt32(nameBytes.count), 0,
            ]
            archive.append(Data("070701".utf8))
            for field in fields {
                archive.append(Data(String(format: "%08x", field).utf8))
            }
            archive.append(nameBytes)
            archive.append(Data(repeating: 0, count: (4 - archive.count % 4) % 4))
            archive.append(contents)
            archive.append(Data(repeating: 0, count: (4 - archive.count % 4) % 4))
        }

        var archive = Data()
        try appendEntry(name, mode: UInt32(S_IFREG | 0o644), contents: contents, to: &archive)
        try appendEntry("TRAILER!!!", mode: 0, contents: Data(), to: &archive)
        return archive
    }

    func testFrameworkRepairRejectsEscapingCurrentLinkWithoutMovingVictim() throws {
        let directory = try fixture()
        let framework = try makeXCFramework(directory.appendingPathComponent("Kit.xcframework"), name: "Kit")
        let versions = framework.appendingPathComponent("Versions", isDirectory: true)
        try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let victim = outside.appendingPathComponent("victim")
        try Data("unchanged".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(
            at: versions.appendingPathComponent("Current"), withDestinationURL: outside)

        XCTAssertThrowsError(try FrameworkRepair.repair(
            xcframework: directory.appendingPathComponent("Kit.xcframework"), minimumOS: nil
        )) { XCTAssertTrue("\($0)".contains("escapes"), "\($0)") }
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "unchanged")
    }

    func testFrameworkRepairDoesNotUsePredictableThinPath() throws {
        let directory = try fixture()
        let framework = try makeXCFramework(directory.appendingPathComponent("Kit.xcframework"), name: "Kit")
        let binary = framework.appendingPathComponent("Kit")
        var fat = Data(repeating: 0, count: 48)
        func write(_ value: UInt32, at offset: Int) {
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { fat.replaceSubrange(offset..<offset + 4, with: $0) }
        }
        write(0xCAFE_BABE, at: 0)
        write(1, at: 4)
        write(48, at: 16)
        write(8, at: 20)
        fat.append(Data("!<arch>\n".utf8))
        try fat.write(to: binary)

        let victim = directory.appendingPathComponent("victim")
        try Data("unchanged".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(
            at: binary.appendingPathExtension("thin"), withDestinationURL: victim)

        let notes = try FrameworkRepair.repair(
            xcframework: directory.appendingPathComponent("Kit.xcframework"), minimumOS: nil)
        XCTAssertTrue(notes.contains { $0.contains("unwrapped") }, "\(notes)")
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "unchanged")
        XCTAssertEqual(try Data(contentsOf: binary), Data("!<arch>\n".utf8))
    }

    func testFrameworkRepairRejectsSymlinkAndOversizedInfoPlist() throws {
        let directory = try fixture()
        let linked = directory.appendingPathComponent("Linked.xcframework")
        _ = try makeXCFramework(linked, name: "Linked")
        let info = linked.appendingPathComponent("Info.plist")
        let real = linked.appendingPathComponent("Real.plist")
        try FileManager.default.moveItem(at: info, to: real)
        try FileManager.default.createSymbolicLink(at: info, withDestinationURL: real)
        XCTAssertThrowsError(try FrameworkRepair.repair(xcframework: linked, minimumOS: nil)) {
            XCTAssertTrue("\($0)".contains("safely read"), "\($0)")
        }

        let oversized = directory.appendingPathComponent("Oversized.xcframework")
        _ = try makeXCFramework(oversized, name: "Oversized")
        let oversizedInfo = oversized.appendingPathComponent("Info.plist")
        let handle = try FileHandle(forWritingTo: oversizedInfo)
        try handle.truncate(atOffset: 8 * 1_024 * 1_024 + 1)
        try handle.close()
        XCTAssertThrowsError(try FrameworkRepair.repair(xcframework: oversized, minimumOS: nil)) {
            XCTAssertTrue("\($0)".contains("8 MiB"), "\($0)")
        }
    }

    func testFrameworkRepairBoundsDecodedPlistGraphInIsolatedWorker() throws {
        let directory = try fixture()
        let framework = directory.appendingPathComponent("Deep.xcframework", isDirectory: true)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        var nested: Any = "leaf"
        for _ in 0..<40 { nested = [nested] }
        let info: [String: Any] = ["AvailableLibraries": [], "UntrustedMetadata": nested]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: framework.appendingPathComponent("Info.plist"))

        XCTAssertThrowsError(try FrameworkRepair.repair(xcframework: framework, minimumOS: nil)) { error in
            XCTAssertTrue("\(error)".contains("nested too deeply"), "\(error)")
        }
    }

    func testFrameworkRepairAcceptsBoundedBinaryInfoPlist() throws {
        let directory = try fixture()
        let xcframework = directory.appendingPathComponent("Binary.xcframework", isDirectory: true)
        let framework = try makeXCFramework(xcframework, name: "Binary", frameworkInfo: false)
        let info: [String: Any] = [
            "AvailableLibraries": [[
                "LibraryIdentifier": "ios-arm64", "LibraryPath": "Binary.framework",
                "SupportedArchitectures": ["arm64"], "SupportedPlatform": "ios",
            ]],
            "CFBundlePackageType": "XFWK", "XCFrameworkFormatVersion": "1.0",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: xcframework.appendingPathComponent("Info.plist"))

        let notes = try FrameworkRepair.repair(xcframework: xcframework, minimumOS: "15.0")
        XCTAssertTrue(notes.contains { $0.contains("added a minimal Info.plist") }, "\(notes)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: framework.appendingPathComponent("Info.plist").path))
    }

    func testFrameworkRepairRejectsControlCharactersWithoutReflectingThemInDiagnostics() throws {
        let directory = try fixture()
        let framework = directory.appendingPathComponent("Control.xcframework", isDirectory: true)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        let forged = "ios-arm64\n\u{1B}[31m::error::forged"
        let info: [String: Any] = [
            "AvailableLibraries": [[
                "LibraryIdentifier": forged, "LibraryPath": "Kit.framework",
                "SupportedPlatform": "ios",
            ]]
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: framework.appendingPathComponent("Info.plist"))

        XCTAssertThrowsError(try FrameworkRepair.repair(xcframework: framework, minimumOS: nil)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("unsafe library identifier or path"), message)
            XCTAssertFalse(message.contains("forged"), message)
            XCTAssertFalse(message.contains("\n"), message)
            XCTAssertFalse(message.contains("\u{1B}"), message)
        }
    }

    func testFrameworkRepairRejectsFatSliceTooSmallForArchiveMagic() throws {
        let directory = try fixture()
        let framework = try makeXCFramework(
            directory.appendingPathComponent("Small.xcframework"), name: "Small")
        let binary = framework.appendingPathComponent("Small")
        var fat = Data(repeating: 0, count: 48)
        func write(_ value: UInt32, at offset: Int) {
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { fat.replaceSubrange(offset..<offset + 4, with: $0) }
        }
        write(0xCAFE_BABE, at: 0)
        write(1, at: 4)
        write(48, at: 16)
        write(4, at: 20)
        fat.append(Data("!<arch>\n".utf8))
        try fat.write(to: binary)

        XCTAssertThrowsError(try FrameworkRepair.repair(
            xcframework: directory.appendingPathComponent("Small.xcframework"), minimumOS: nil
        )) { error in
            XCTAssertTrue("\(error)".contains("Malformed universal binary slice"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: binary), fat)
    }

    func testExplicitBinaryPathCannotEscapeOrSelectASymlink() throws {
        let directory = try fixture("target 'App' do\n  binary 'Kit', path: 'Vendor'\nend\n")
        let root = directory.appendingPathComponent("Vendor", isDirectory: true)
        let real = root.appendingPathComponent("Real/Kit.xcframework", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: alias.appendingPathComponent("Kit.xcframework"), withDestinationURL: real)
        let outside = directory.appendingPathComponent("Outside/Secret.xcframework", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let binary = try Installer(directory: directory).manifest().binaries[0]

        XCTAssertThrowsError(try BinaryStore.locate(
            "../Outside/Secret.xcframework", in: root, extension: "xcframework", binary: binary))
        XCTAssertThrowsError(try BinaryStore.locate(
            "Alias/Kit.xcframework", in: root, extension: "xcframework", binary: binary))
    }

    func testLocalBinaryRootSymlinkCannotEscapePodfileDirectory() throws {
        let directory = try fixture("target 'App' do\n  binary 'Kit', path: 'Vendor'\nend\n")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftpods-outside-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        directories.append(outside)
        // If containment happened after validation, this child would produce a different traversal error first.
        try FileManager.default.createSymbolicLink(
            at: outside.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/"))
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("Vendor"), withDestinationURL: outside)
        let binary = try Installer(directory: directory).manifest().binaries[0]

        XCTAssertThrowsError(try BinaryStore(cache: directory.appendingPathComponent("cache"), runner: ProcessRunner(), offline: true)
            .contents(binary, podfileDirectory: directory)) {
            XCTAssertTrue("\($0)".contains("outside the Podfile directory"), "\($0)")
        }
    }

    func testLocalTreeAllowsInternalLinksAndRejectsEscapingLinks() throws {
        let directory = try fixture()
        let root = directory.appendingPathComponent("tree", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("file")
        try Data("data".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("inside").path, withDestinationPath: "file")
        XCTAssertNoThrow(try SecureFileTree.validate(
            root, allowRootSymlink: false, limits: .local, hashingContents: true))

        let outside = directory.appendingPathComponent("outside")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        XCTAssertThrowsError(try SecureFileTree.validate(
            root, allowRootSymlink: false, limits: .local, hashingContents: true))
    }

    func testLocalBinaryFingerprintIncludesContent() throws {
        let directory = try fixture("target 'App' do\n  binary 'Kit', path: 'Kit.xcframework'\nend\n")
        let framework = directory.appendingPathComponent("Kit.xcframework", isDirectory: true)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        let file = framework.appendingPathComponent("Info.plist")
        try Data("one".utf8).write(to: file)
        let binary = try Installer(directory: directory).manifest().binaries[0]
        let first = try BinaryPackage(
            entries: [.init(binary: binary, xcframeworks: [framework], resources: [])], platforms: []).fingerprint
        try Data("two".utf8).write(to: file)
        let second = try BinaryPackage(
            entries: [.init(binary: binary, xcframeworks: [framework], resources: [])], platforms: []).fingerprint
        XCTAssertNotEqual(first, second)
    }

    func testDirectLocalBinaryKeepsItsNameAndUsesAuthenticatedSnapshotAfterSourceMutation() throws {
        let directory = try fixture("target 'App' do\n  binary 'Kit', path: 'Vendor/Kit.xcframework'\nend\n")
        let framework = directory.appendingPathComponent("Vendor/Kit.xcframework", isDirectory: true)
        _ = try makeXCFramework(framework, name: "Kit")
        let payload = framework.appendingPathComponent("payload.txt")
        try Data("trusted".utf8).write(to: payload)
        let binary = try Installer(directory: directory).manifest().binaries[0]

        let contents = try BinaryStore(
            cache: directory.appendingPathComponent("cache"), runner: ProcessRunner(), offline: true
        ).contents(binary, podfileDirectory: directory)
        XCTAssertEqual(contents.xcframeworks.map(\.lastPathComponent), ["Kit.xcframework"])
        XCTAssertEqual(contents.xcframeworkPaths, ["Kit.xcframework"])
        XCTAssertNotNil(contents.snapshotLease)
        XCTAssertFalse(SecureFileTree.contains(contents.xcframeworks[0], in: framework, allowRoot: true))
        let package = try BinaryPackage(
            entries: [.init(
                binary: binary, xcframeworks: contents.xcframeworks, resources: contents.resources,
                xcframeworkPaths: contents.xcframeworkPaths, resourcePaths: contents.resourcePaths,
                snapshotLease: contents.snapshotLease)],
            platforms: [])

        // The install must consume the authenticated private copy, not bytes changed after `contents` returned.
        try Data("changed".utf8).write(to: payload)
        let rendered = directory.appendingPathComponent("rendered", isDirectory: true)
        _ = try package.render(into: rendered)
        XCTAssertEqual(
            try String(
                contentsOf: rendered.appendingPathComponent("Artifacts/Kit/Kit.xcframework/payload.txt"),
                encoding: .utf8),
            "trusted")
        XCTAssertTrue(try String(
            contentsOf: rendered.appendingPathComponent("Package.swift"), encoding: .utf8
        ).contains(#".binaryTarget(name: "Kit", path: "Artifacts/Kit/Kit.xcframework")"#))

        // The package also binds the later render to the digest it captured from the private snapshot.
        try Data("tampered snapshot".utf8).write(to: contents.xcframeworks[0].appendingPathComponent("payload.txt"))
        XCTAssertThrowsError(try package.render(into: directory.appendingPathComponent("tampered-render"))) {
            XCTAssertTrue("\($0)".contains("changed before it was copied"), "\($0)")
        }
    }

    func testDirectLocalRootSymlinkPreservesTheDeclaredXCFrameworkName() throws {
        let directory = try fixture("target 'App' do\n  binary 'Alias', path: 'Alias.xcframework'\nend\n")
        let actual = directory.appendingPathComponent("Vendor/Actual", isDirectory: true)
        _ = try makeXCFramework(actual, name: "Alias")
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("Alias.xcframework"), withDestinationURL: actual)
        let binary = try Installer(directory: directory).manifest().binaries[0]

        let contents = try BinaryStore(
            cache: directory.appendingPathComponent("cache"), runner: ProcessRunner(), offline: true
        ).contents(binary, podfileDirectory: directory)

        XCTAssertEqual(contents.xcframeworkPaths, ["Alias.xcframework"])
        XCTAssertEqual(contents.xcframeworks.map(\.lastPathComponent), ["Alias.xcframework"])
    }

    func testInstallReadsFileArchiveThroughLockedWorkspaceAfterPathRebind() throws {
        let directory = try fixture()
        let decoy = try fixture()
        let archive = directory.appendingPathComponent("Kit.tar")
        let decoyArchive = decoy.appendingPathComponent("Kit.tar")
        let plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict/></plist>"
        try tar([
            .file("Kit.xcframework/Info.plist", plist),
            .file("Kit.xcframework/payload.txt", "trusted"),
        ]).write(to: archive)
        try tar([
            .file("Kit.xcframework/Info.plist", plist),
            .file("Kit.xcframework/payload.txt", "decoy"),
        ]).write(to: decoyArchive)
        let checksum = try BinaryStore.sha256(of: archive)
        let podfile =
            "target 'App' do\n  binary 'Kit', url: '\(archive.absoluteString)', sha256: '\(checksum)'\nend\n"
        try podfile.write(
            to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        try podfile.write(
            to: decoy.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let cache = directory.deletingLastPathComponent().appendingPathComponent(
            "swiftpods-archive-cache-" + UUID().uuidString, isDirectory: true)
        directories.append(cache)

        let raced = Installer(
            directory: directory, cache: cache,
            generatedMutationHook: { point in
                switch point {
                case .beforeBinaryRead("Kit"), .afterBinaryRead("Kit"):
                    precondition(renameatx_np(
                        AT_FDCWD, directory.path, AT_FDCWD, decoy.path, UInt32(RENAME_SWAP)) == 0)
                default: break
                }
            })
        _ = try raced.install(.init())

        XCTAssertEqual(
            try String(
                contentsOf: directory.appendingPathComponent(
                    "SwiftPods/SwiftPodsBinaries/Artifacts/Kit/Kit.xcframework/payload.txt"),
                encoding: .utf8),
            "trusted")
    }

    func testSnapshotsAndGeneratedPackagesRemoveAmbientWritableModesAndACLs() throws {
        let directory = try fixture("target 'App' do\n  binary 'Kit', path: 'Kit.xcframework'\nend\n")
        let framework = directory.appendingPathComponent("Kit.xcframework", isDirectory: true)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        let payload = framework.appendingPathComponent("Info.plist")
        try Data("plist".utf8).write(to: payload)
        XCTAssertEqual(chmod(framework.path, 0o777), 0)
        XCTAssertEqual(chmod(payload.path, 0o666), 0)
        let sourceDescriptor = payload.path.withCString { open($0, O_RDWR | O_CLOEXEC | O_NOFOLLOW) }
        XCTAssertGreaterThanOrEqual(sourceDescriptor, 0)
        guard sourceDescriptor >= 0 else { return }
        let resourceFork = Data(repeating: 0x52, count: 128 * 1_024)
        XCTAssertEqual(resourceFork.withUnsafeBytes { bytes in
            "com.apple.ResourceFork".withCString {
                fsetxattr(sourceDescriptor, $0, bytes.baseAddress, bytes.count, 0, 0)
            }
        }, 0)
        close(sourceDescriptor)
        guard payload.path.withCString({ chflags($0, UInt32(UF_IMMUTABLE)) }) == 0 else {
            throw XCTSkip("The test filesystem does not support UF_IMMUTABLE")
        }
        defer { _ = payload.path.withCString { chflags($0, 0) } }
        let binary = try Installer(directory: directory).manifest().binaries[0]

        let contents = try BinaryStore(
            cache: directory.appendingPathComponent("cache"), runner: ProcessRunner(), offline: true
        ).contents(binary, podfileDirectory: directory)
        let snapshot = contents.xcframeworks[0]
        let snapshotPayload = snapshot.appendingPathComponent("Info.plist")
        XCTAssertEqual(try SecureFileTree.statusNoFollow(snapshot).st_mode & 0o022, 0)
        XCTAssertEqual(try SecureFileTree.statusNoFollow(snapshotPayload).st_mode & 0o022, 0)
        XCTAssertEqual(try SecureFileTree.statusNoFollow(snapshotPayload).st_flags, 0)
        let snapshotDescriptor = snapshotPayload.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        XCTAssertGreaterThanOrEqual(snapshotDescriptor, 0)
        if snapshotDescriptor >= 0 {
            XCTAssertEqual(flistxattr(snapshotDescriptor, nil, 0, 0), 0)
            close(snapshotDescriptor)
        }
        XCTAssertFalse(try SecureFileTree.hasExtendedACL(snapshot))
        XCTAssertFalse(try SecureFileTree.hasExtendedACL(snapshotPayload))

        let package = try BinaryPackage(
            entries: [.init(
                binary: binary, xcframeworks: contents.xcframeworks, resources: contents.resources,
                xcframeworkPaths: contents.xcframeworkPaths, resourcePaths: contents.resourcePaths,
                snapshotLease: contents.snapshotLease)],
            platforms: [])
        let rendered = directory.appendingPathComponent("rendered", isDirectory: true)
        _ = try package.render(into: rendered)
        for url in [
            rendered, rendered.appendingPathComponent("Package.swift"),
            rendered.appendingPathComponent("Artifacts/Kit/Kit.xcframework/Info.plist"),
        ] {
            XCTAssertEqual(try SecureFileTree.statusNoFollow(url).st_mode & 0o022, 0, url.path)
            XCTAssertFalse(try SecureFileTree.hasExtendedACL(url), url.path)
        }
        let renderedPayload = rendered.appendingPathComponent("Artifacts/Kit/Kit.xcframework/Info.plist")
        XCTAssertEqual(try SecureFileTree.statusNoFollow(renderedPayload).st_flags, 0)
        let renderedDescriptor = renderedPayload.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        XCTAssertGreaterThanOrEqual(renderedDescriptor, 0)
        if renderedDescriptor >= 0 {
            XCTAssertEqual(flistxattr(renderedDescriptor, nil, 0, 0), 0)
            close(renderedDescriptor)
        }
        let preservedSource = payload.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        XCTAssertGreaterThanOrEqual(preservedSource, 0)
        if preservedSource >= 0 {
            XCTAssertGreaterThan(flistxattr(preservedSource, nil, 0, 0), 0)
            close(preservedSource)
        }
    }

    func testExtendedACLDetectionAndNormalizationUseDarwinReturnSemantics() throws {
        let directory = try fixture()
        let payload = directory.appendingPathComponent("acl-payload")
        try Data("payload".utf8).write(to: payload)
        _ = try ProcessRunner().run(
            "/bin/chmod", ["+a", "everyone allow write", payload.path], in: nil)

        XCTAssertTrue(try SecureFileTree.hasExtendedACL(payload))
        try SecureFileTree.normalizePermissions(in: directory)
        XCTAssertFalse(try SecureFileTree.hasExtendedACL(payload))
        XCTAssertEqual(try SecureFileTree.statusNoFollow(payload).st_mode & 0o022, 0)

        let archive = directory.appendingPathComponent("acl-cache.tar")
        try tar([.file("Kit.xcframework/Info.plist", "plist")]).write(to: archive)
        let checksum = try BinaryStore.sha256(of: archive)
        try "target 'App' do\n  binary 'Kit', url: '\(archive.absoluteString)', sha256: '\(checksum)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
        _ = try ProcessRunner().run(
            "/bin/chmod", ["+a", "everyone allow write", cache.path], in: nil)
        let binary = try Installer(directory: directory).manifest().binaries[0]
        XCTAssertThrowsError(try BinaryStore(cache: cache, runner: ProcessRunner(), offline: false)
            .contents(binary, podfileDirectory: directory)) {
            XCTAssertTrue("\($0)".contains("grants access through an extended ACL"), "\($0)")
        }
    }

    func testLocalBinaryRejectsDuplicateExplicitSelectionsBeforeSnapshotting() throws {
        let directory = try fixture("""
            target 'App' do
              binary 'Kit', path: 'Vendor', xcframeworks: ['Kit.xcframework', 'Kit.xcframework']
            end
            """)
        _ = try makeXCFramework(directory.appendingPathComponent("Vendor/Kit.xcframework"), name: "Kit")
        let binary = try Installer(directory: directory).manifest().binaries[0]

        XCTAssertThrowsError(try BinaryStore(
            cache: directory.appendingPathComponent("cache"), runner: ProcessRunner(), offline: true
        ).contents(binary, podfileDirectory: directory)) { error in
            XCTAssertTrue("\(error)".contains("more than once"), "\(error)")
        }
    }

    func testLocalBinaryRejectsOverlappingExplicitSelectionsBeforeSnapshotting() throws {
        let directory = try fixture("""
            target 'App' do
              binary 'Kit', path: 'Vendor', xcframeworks: [
                'Outer.xcframework', 'Outer.xcframework/Nested.xcframework'
              ]
            end
            """)
        let outer = directory.appendingPathComponent("Vendor/Outer.xcframework", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outer.appendingPathComponent("Nested.xcframework"), withIntermediateDirectories: true)
        let binary = try Installer(directory: directory).manifest().binaries[0]

        XCTAssertThrowsError(try BinaryStore(
            cache: directory.appendingPathComponent("cache"), runner: ProcessRunner(), offline: true
        ).contents(binary, podfileDirectory: directory)) { error in
            XCTAssertTrue("\(error)".contains("overlapping directory trees"), "\(error)")
        }
        XCTAssertThrowsError(try BinaryPackage(
            entries: [.init(
                binary: binary, xcframeworks: [outer, outer.appendingPathComponent("Nested.xcframework")],
                resources: [])],
            platforms: []
        )) { error in
            XCTAssertTrue("\(error)".contains("overlapping artifact directory trees"), "\(error)")
        }
    }

    func testRemoteNestedResourceIsAuthenticatedRenderedAndChargedTwice() throws {
        let directory = try fixture()
        let archive = directory.appendingPathComponent("source.tar")
        let nested = "Kit.xcframework/ios-arm64/Kit.framework/AdsRes.bundle"
        try tar([.file(nested + "/payload.txt", "nested resource")]).write(to: archive)
        let digest = try BinaryStore.sha256(of: archive)
        try "target 'App' do\n  binary 'Kit', url: '\(archive.absoluteString)', sha256: '\(digest)', resources: ['\(nested)']\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]
        let store = BinaryStore(cache: directory.appendingPathComponent("cache"), runner: ProcessRunner(), offline: false)
        let contents = try store.contents(binary, podfileDirectory: directory)
        let resource = try XCTUnwrap(contents.resources.first)
        let inspected = try BinaryStore.inspectArchive(at: archive, url: archive.absoluteString)
        let extra = try SecureFileTree.validate(resource, allowRootSymlink: false, limits: .local, hashingContents: false)
        XCTAssertEqual(store.chargedArtifactWorkForTesting.entries, inspected.entries + extra.entries)
        XCTAssertEqual(store.chargedArtifactWorkForTesting.bytes, inspected.bytes + extra.bytes)

        let package = try BinaryPackage(entries: [.init(
            binary: binary, xcframeworks: contents.xcframeworks, resources: contents.resources,
            xcframeworkPaths: contents.xcframeworkPaths, resourcePaths: contents.resourcePaths,
            snapshotLease: contents.snapshotLease)], platforms: [])
        let destination = directory.appendingPathComponent("generated")
        _ = try package.render(into: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(
            "Artifacts/Kit/Resources/AdsRes.bundle/payload.txt")), Data("nested resource".utf8))
        // Resources remain covered by the snapshot digest, even though their ancestor framework was also selected.
        try Data("tampered".utf8).write(to: resource.appendingPathComponent("payload.txt"))
        XCTAssertThrowsError(try package.render(into: directory.appendingPathComponent("tampered-render")))
    }

    func testNestedResourceExceptionDoesNotPermitResourceOverlapOrDuplicateSelection() throws {
        let nested = "Kit.xcframework/AdsRes.bundle"
        for resources in [[nested, nested + "/Inner.bundle"], [nested, nested.uppercased()]] {
            let directory = try fixture(
                "target 'App' do\n  binary 'Kit', path: 'Vendor', resources: ['\(resources.joined(separator: "', '"))']\nend\n")
            let bundle = directory.appendingPathComponent("Vendor/\(nested)/Inner.bundle")
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            let binary = try Installer(directory: directory).manifest().binaries[0]
            XCTAssertThrowsError(try BinaryStore(
                cache: directory.appendingPathComponent("cache"), runner: ProcessRunner(), offline: true
            ).contents(binary, podfileDirectory: directory))
            XCTAssertThrowsError(try BinaryPackage(entries: [.init(
                binary: binary,
                xcframeworks: [directory.appendingPathComponent("Vendor/Kit.xcframework")],
                resources: resources.map { directory.appendingPathComponent("Vendor/\($0)") })], platforms: []))
        }
    }

    func testNestedResourceExceptionDoesNotCrossBinaryDeclarations() throws {
        let directory = try fixture("""
            target 'App' do
              binary 'Kit', path: 'Vendor', xcframeworks: ['Kit.xcframework']
              binary 'Other', path: 'Vendor', xcframeworks: ['Other.xcframework'], resources: ['Kit.xcframework/AdsRes.bundle']
            end
            """)
        let framework = directory.appendingPathComponent("Vendor/Kit.xcframework")
        let resource = framework.appendingPathComponent("AdsRes.bundle")
        let other = directory.appendingPathComponent("Vendor/Other.xcframework")
        try FileManager.default.createDirectory(at: resource, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let binaries = try Installer(directory: directory).manifest().binaries
        let store = BinaryStore(cache: directory.appendingPathComponent("cache"), runner: ProcessRunner(), offline: true)
        let first = try store.contents(binaries[0], podfileDirectory: directory)
        defer { withExtendedLifetime(first) {} }
        XCTAssertThrowsError(try store.contents(binaries[1], podfileDirectory: directory))
        XCTAssertThrowsError(try BinaryPackage(entries: [
            .init(binary: binaries[0], xcframeworks: [framework], resources: []),
            .init(binary: binaries[1], xcframeworks: [other], resources: [resource]),
        ], platforms: []))
    }

    func testLocalBinaryRejectsFilesystemEquivalentOverlappingExplicitSelectionsBeforeSnapshotting() throws {
        let spellings = [
            ("Outer.xcframework", "outer.xcframework"),
            ("Caf\u{E9}.xcframework", "Cafe\u{301}.xcframework"),
        ]
        for (ancestorName, descendantParentName) in spellings {
            let directory = try fixture("""
                target 'App' do
                  binary 'Kit', path: 'Vendor', xcframeworks: [
                    '\(ancestorName)', '\(descendantParentName)/Nested.xcframework'
                  ]
                end
                """)
            let ancestor = directory.appendingPathComponent("Vendor/\(ancestorName)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: ancestor.appendingPathComponent("Nested.xcframework", isDirectory: true),
                withIntermediateDirectories: true)
            let binary = try Installer(directory: directory).manifest().binaries[0]

            XCTAssertThrowsError(try BinaryStore(
                cache: directory.appendingPathComponent("cache"), runner: ProcessRunner(), offline: true
            ).contents(binary, podfileDirectory: directory)) { error in
                XCTAssertTrue(
                    "\(error)".contains("Binary artifacts select overlapping directory trees"), "\(error)")
            }

            var remote = binary
            remote.source = .remote(
                url: "https://example.invalid/binary.zip", sha256: String(repeating: "0", count: 64))
            let virtualAncestor = URL(fileURLWithPath: "/virtual/\(ancestorName)", isDirectory: true)
            let virtualDescendant = URL(
                fileURLWithPath: "/virtual/\(descendantParentName)/Nested.xcframework", isDirectory: true)
            XCTAssertThrowsError(try BinaryPackage(
                entries: [.init(
                    binary: remote, xcframeworks: [virtualAncestor, virtualDescendant], resources: [])],
                platforms: []
            )) { error in
                XCTAssertTrue(
                    "\(error)".contains("Binary package contains overlapping artifact directory trees"), "\(error)")
            }
        }
    }

    func testAutomaticLocalFrameworkSelectionIsBounded() throws {
        let directory = try fixture("target 'App' do\n  binary 'Kit', path: 'Vendor'\nend\n")
        let root = directory.appendingPathComponent("Vendor", isDirectory: true)
        for index in 0...1_024 {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Kit\(index).xcframework"), withIntermediateDirectories: true)
        }
        let binary = try Installer(directory: directory).manifest().binaries[0]

        XCTAssertThrowsError(try BinaryStore(
            cache: directory.appendingPathComponent("cache"), runner: ProcessRunner(), offline: true
        ).contents(binary, podfileDirectory: directory)) { error in
            XCTAssertTrue("\(error)".contains("more than 1024"), "\(error)")
        }
    }

    func testBinaryPackageFailsClosedWhenALocalDigestCannotBeAuthenticated() throws {
        let directory = try fixture("target 'App' do\n  binary 'Kit', path: 'Kit.xcframework'\nend\n")
        let framework = directory.appendingPathComponent("Kit.xcframework", isDirectory: true)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        let outside = directory.appendingPathComponent("outside")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: framework.appendingPathComponent("escape"), withDestinationURL: outside)
        let binary = try Installer(directory: directory).manifest().binaries[0]

        XCTAssertThrowsError(try BinaryPackage(
            entries: [.init(binary: binary, xcframeworks: [framework], resources: [])], platforms: []))
    }

    func testRemoteBinaryErrorsDoNotExposeSignedURLCredentials() throws {
        let secret = "signed-path-token"
        let signedURL = "https://secret.example/private/\(secret)/archive.bin?token=\(secret)"
        let checksum = String(repeating: "0", count: 64)
        let directory = try fixture(
            "target 'App' do\n  binary 'Remote', url: '\(signedURL)', sha256: '\(checksum)'\nend\n")
        let binary = try Installer(directory: directory).manifest().binaries[0]

        let downloader = FailingDownloadClient()
        let store = BinaryStore(
            cache: directory.appendingPathComponent("cache"), runner: ProcessRunner(), offline: false,
            downloader: downloader)
        XCTAssertThrowsError(try store.contents(binary, podfileDirectory: directory)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("configured https URL"), message)
            XCTAssertFalse(message.contains(secret), message)
            XCTAssertFalse(message.contains("password"), message)
            XCTAssertFalse(message.contains("secret.example"), message)
        }
        XCTAssertEqual(downloader.invocationCount, 1, "An unclassified failure must not be retried")
        XCTAssertEqual(downloader.requestedURLs.map(\.absoluteString), [signedURL])
        XCTAssertThrowsError(try store.contents(binary, podfileDirectory: directory)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("earlier in this install"), message)
            XCTAssertFalse(message.contains(secret), message)
        }
        XCTAssertEqual(downloader.invocationCount, 1, "A failed SHA must be memoized for the rest of the install")

        let invalid = directory.appendingPathComponent("invalid-archive")
        try Data("invalid".utf8).write(to: invalid)
        let credentialURL = "https://user:password@secret.example/private/\(secret)/archive.bin?token=\(secret)#fragment"
        XCTAssertThrowsError(try BinaryStore.format(of: invalid, url: credentialURL)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("configured https URL"), message)
            XCTAssertFalse(message.contains(secret), message)
            XCTAssertFalse(message.contains("password"), message)
            XCTAssertFalse(message.contains("secret.example"), message)
        }
    }

    func testSignedDownloadURLNeverEntersExternalCommandArguments() throws {
        let secret = "signed-argv-secret"
        let signedURL = URL(string: "https://downloads.example.com/private/archive.tar?token=\(secret)")!
        let archiveData = try tar([.file("Kit.xcframework/Info.plist", "plist")])
        let archive = try fixture().appendingPathComponent("digest.tar")
        try archiveData.write(to: archive)
        let checksum = try BinaryStore.sha256(of: archive)
        let directory = archive.deletingLastPathComponent()
        try "target 'App' do\n  binary 'Kit', url: '\(signedURL.absoluteString)', sha256: '\(checksum)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]
        let downloader = ArchiveDownloadClient()
        downloader.add(archiveData, for: signedURL)
        let runner = CountingProcessRunner()

        let contents = try BinaryStore(
            cache: directory.appendingPathComponent("cache"), runner: runner, offline: false,
            downloader: downloader
        ).contents(binary, podfileDirectory: directory)

        XCTAssertEqual(contents.xcframeworks.map(\.lastPathComponent), ["Kit.xcframework"])
        let allArguments = runner.allArguments.flatMap { $0 }
        XCTAssertFalse(allArguments.contains { $0.contains(secret) }, "\(allArguments)")
        XCTAssertFalse(allArguments.contains(signedURL.absoluteString), "\(allArguments)")
        XCTAssertEqual(runner.count("/usr/bin/tar"), 0, "Archive processing must not launch an external parser")
    }

    func testDefaultDownloaderPinsValidatedAddressAndValidatesEveryRedirect() throws {
        let secret = "signed-pinned-secret"
        let signedURL = URL(string: "https://93.184.216.34/private/archive.tar?token=\(secret)")!
        let archiveData = try tar([.file("Kit.xcframework/Info.plist", "plist")])
        let archive = try fixture().appendingPathComponent("pinned.tar")
        try archiveData.write(to: archive)
        let checksum = try BinaryStore.sha256(of: archive)
        let directory = archive.deletingLastPathComponent()
        try "target 'App' do\n  binary 'Kit', url: '\(signedURL.absoluteString)', sha256: '\(checksum)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]
        let finalURL = "https://93.184.216.35/final.tar"
        let runner = PinnedCurlRunner([
            .init(status: 302, headers: ["Location": finalURL]),
            .init(status: 200, body: archiveData),
        ])

        let contents = try BinaryStore(
            cache: directory.appendingPathComponent("cache"), runner: runner, offline: false
        ).contents(binary, podfileDirectory: directory)

        XCTAssertEqual(contents.xcframeworks.map(\.lastPathComponent), ["Kit.xcframework"])
        XCTAssertEqual(runner.arguments.count, 2)
        XCTAssertFalse(runner.arguments.flatMap { $0 }.contains { $0.contains(secret) })
        XCTAssertFalse(runner.arguments.flatMap { $0 }.contains(signedURL.absoluteString))
        XCTAssertTrue(runner.arguments[0][1].contains("ulimit -f"), "\(runner.arguments[0])")
        XCTAssertEqual(
            runner.arguments[0][3], "4193280",
            "The body cap reserves one MiB of the aggregate allowance for bounded response headers")
        XCTAssertTrue(runner.configurations[0].contains("url = \"\(signedURL.absoluteString)\""))
        XCTAssertTrue(
            runner.configurations[0].contains("resolve = \"93.184.216.34:443:93.184.216.34\""),
            runner.configurations[0])
        XCTAssertTrue(
            runner.configurations[0].contains("connect-to = \"::93.184.216.34:443\""),
            runner.configurations[0])
        XCTAssertTrue(runner.configurations[0].contains("dump-header = \"/dev/fd/1\""))
        XCTAssertTrue(runner.configurations[1].contains("url = \"\(finalURL)\""), runner.configurations[1])
        XCTAssertTrue(
            runner.configurations[1].contains("connect-to = \"::93.184.216.35:443\""),
            runner.configurations[1])
        XCTAssertEqual(runner.timeouts.count, 2)
        XCTAssertLessThan(runner.timeouts[1], runner.timeouts[0], "Redirects must consume one shared deadline")

        let redirectedURL = URL(string: "https://93.184.216.34/redirect.tar?token=\(secret)")!
        try "target 'App' do\n  binary 'Redirect', url: '\(redirectedURL.absoluteString)', sha256: '\(checksum)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let redirected = try Installer(directory: directory).manifest().binaries[0]
        let redirectRunner = PinnedCurlRunner([
            .init(status: 302, headers: ["Location": "https://127.0.0.1/private.tar"]),
        ])
        XCTAssertThrowsError(try BinaryStore(
            cache: directory.appendingPathComponent("redirect-cache"), runner: redirectRunner, offline: false
        ).contents(redirected, podfileDirectory: directory))
        XCTAssertEqual(redirectRunner.arguments.count, 1, "The private redirect must be rejected before another connection")
        XCTAssertTrue(redirectRunner.timeouts.allSatisfy { $0 > 0 && $0 <= 600 })
        XCTAssertFalse(redirectRunner.arguments.flatMap { $0 }.contains { $0.contains(secret) })
    }

    func testKernelFileSizeLimitBoundsUnknownLengthDownloadSink() throws {
        let directory = try fixture()
        let sink = directory.appendingPathComponent("bounded-download")
        let descriptor = sink.path.withCString { open($0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        let script = "ulimit -f \"$1\" || exit 125; exec /bin/dd if=/dev/zero of=\"$2\" bs=1024 count=2"

        XCTAssertThrowsError(try ProcessRunner().runData(
            "/bin/sh", ["-c", script, "swiftpods-limit-test", "1", "/dev/fd/\(descriptor)"],
            in: nil, timeout: 5, maximumOutputBytes: 1_024, passingFileDescriptors: [descriptor]))
        XCTAssertLessThanOrEqual(try SecureFileTree.statusNoFollow(sink).st_size, 1_024)
    }

    func testNetworkAndLocalArchivePoliciesRejectPrivateOrEscapingSources() throws {
        XCTAssertThrowsError(try BinaryNetworkPolicy.validate(URL(string: "https://127.0.0.1/sdk.zip")!)) {
            XCTAssertTrue("\($0)".contains("non-public"), "\($0)")
        }
        XCTAssertThrowsError(try BinaryNetworkPolicy.validate(URL(string: "https://[::1]/sdk.zip")!)) {
            XCTAssertTrue("\($0)".contains("non-public"), "\($0)")
        }
        XCTAssertThrowsError(try BinaryNetworkPolicy.validate(URL(string: "https://93.184.216.34./sdk.zip")!)) {
            XCTAssertTrue("\($0)".contains("unsafe host"), "\($0)")
        }
        XCTAssertThrowsError(try BinaryNetworkPolicy.validate(
            URL(string: "https://93.184.216.34/sdk.zip")!, timeout: 0
        )) { error in
            guard let failure = error as? BinaryDownloadFailure else {
                return XCTFail("Expected a DNS download failure, got \(error)")
            }
            XCTAssertFalse(failure.transient, "A non-cancellable timed-out resolver must not be retried")
        }

        let directory = try fixture()
        let outsideDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftpods-outside-archive-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        directories.append(outsideDirectory)
        let outside = outsideDirectory.appendingPathComponent("archive.tar")
        let data = try tar([.file("Kit.xcframework/Info.plist", "plist")])
        try data.write(to: outside)
        let checksum = try BinaryStore.sha256(of: outside)
        try "target 'App' do\n  binary 'Kit', url: '\(outside.absoluteString)', sha256: '\(checksum)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]

        XCTAssertThrowsError(try BinaryStore(
            cache: directory.appendingPathComponent("cache"), runner: ProcessRunner(), offline: false
        ).contents(binary, podfileDirectory: directory)) {
            XCTAssertTrue("\($0)".contains("inside the Podfile directory"), "\($0)")
        }
    }

    func testRemoteDownloadRetriesOnlyTransientFailuresWithinOneDeadline() throws {
        let secret = "signed-path-token"
        let signedURL = "https://secret.example/private/\(secret)/archive.zip?token=\(secret)"
        let checksum = String(repeating: "0", count: 64)
        let directory = try fixture(
            "target 'App' do\n  binary 'Remote', url: '\(signedURL)', sha256: '\(checksum)'\nend\n")
        let binary = try Installer(directory: directory).manifest().binaries[0]

        let transient = FailingDownloadClient(transient: true)
        XCTAssertThrowsError(try BinaryStore(
            cache: directory.appendingPathComponent("transient-cache"), runner: ProcessRunner(), offline: false,
            downloader: transient
        ).contents(binary, podfileDirectory: directory)) { error in
            XCTAssertFalse("\(error)".contains(secret), "\(error)")
        }
        let timeouts = transient.recordedTimeouts
        XCTAssertEqual(timeouts.count, 4)
        XCTAssertTrue(timeouts.allSatisfy { $0 > 0 && $0 <= 600 }, "\(timeouts)")
        XCTAssertTrue(zip(timeouts, timeouts.dropFirst()).allSatisfy { $0 > $1 }, "\(timeouts)")

        let permanent = FailingDownloadClient()
        XCTAssertThrowsError(try BinaryStore(
            cache: directory.appendingPathComponent("permanent-cache"), runner: ProcessRunner(), offline: false,
            downloader: permanent
        ).contents(binary, podfileDirectory: directory))
        XCTAssertEqual(permanent.recordedTimeouts.count, 1, "Permanent HTTP failures must not be retried")
    }

    func testRemoteBinaryWorkCountsAndMemoizesUniqueArchives() throws {
        let checksum = String(repeating: "0", count: 64)
        let directory = try fixture(
            "target 'App' do\n  binary 'Remote', url: 'https://example.com/sdk.zip', sha256: '\(checksum)'\nend\n")
        let template = try Installer(directory: directory).manifest().binaries[0]
        let downloader = ArchiveDownloadClient()
        let store = BinaryStore(
            cache: directory.appendingPathComponent("cache"), runner: ProcessRunner(), offline: false,
            downloader: downloader)

        func invalidBinary(_ index: Int) throws -> Binary {
            let data = Data("invalid archive \(index)".utf8)
            let file = directory.appendingPathComponent("invalid-archive-\(index).bin")
            try data.write(to: file)
            let url = URL(string: "https://example.com/invalid-archive-\(index).bin")!
            downloader.add(data, for: url)
            var binary = template
            binary.name = "Remote\(index)"
            binary.source = .remote(url: url.absoluteString, sha256: try BinaryStore.sha256(of: file))
            return binary
        }

        let repeated = try invalidBinary(0)
        XCTAssertThrowsError(try store.contents(repeated, podfileDirectory: directory)) { error in
            let message = "\(error)"
            XCTAssertTrue(
                message.contains("archive format") || message.contains("not a zip or tar archive"), message)
        }
        for _ in 0..<64 {
            XCTAssertThrowsError(try store.contents(repeated, podfileDirectory: directory)) { error in
                XCTAssertTrue("\(error)".contains("earlier in this install"), "\(error)")
            }
        }
        XCTAssertEqual(downloader.invocationCount, 1, "A failed archive must be processed only once per SHA")

        // The repeated SHA consumes one slot. Sixty-three more unique archives fill the limit without penalizing retries.
        for index in 1..<64 {
            XCTAssertThrowsError(try store.contents(try invalidBinary(index), podfileDirectory: directory))
        }
        XCTAssertThrowsError(try store.contents(try invalidBinary(64), podfileDirectory: directory)) { error in
            XCTAssertTrue("\(error)".contains("more than 64 remote archives"), "\(error)")
        }
        XCTAssertEqual(downloader.invocationCount, 64)
    }

    func testRemoteArchiveSnapshotIsReusedForDifferentSelections() throws {
        let directory = try fixture()
        let source = directory.appendingPathComponent("archive-source", isDirectory: true)
        let firstFramework = source.appendingPathComponent("First.xcframework", isDirectory: true)
        let secondFramework = source.appendingPathComponent("Second.xcframework", isDirectory: true)
        try FileManager.default.createDirectory(at: firstFramework, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFramework, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: firstFramework.appendingPathComponent("Info.plist"))
        try Data("second".utf8).write(to: secondFramework.appendingPathComponent("Info.plist"))
        let archive = directory.appendingPathComponent("Remote.tar")
        _ = try ProcessRunner().run("/usr/bin/tar", ["-cf", archive.path, "-C", source.path, "."], in: nil)
        let digest = try BinaryStore.sha256(of: archive)
        try "target 'App' do\n  binary 'Remote', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let template = try Installer(directory: directory).manifest().binaries[0]
        var first = template
        first.name = "FirstBinary"
        first.xcframeworks = ["First.xcframework"]
        var second = template
        second.name = "SecondBinary"
        second.xcframeworks = ["Second.xcframework"]
        let runner = CountingProcessRunner()
        let store = BinaryStore(cache: directory.appendingPathComponent("cache"), runner: runner, offline: false)
        let snapshot = directory.appendingPathComponent("shared-private-snapshot", isDirectory: true)
        let firstContents = try store.contents(first, podfileDirectory: directory, snapshotDirectory: snapshot)
        let secondContents = try store.contents(second, podfileDirectory: directory, snapshotDirectory: snapshot)

        XCTAssertEqual(firstContents.xcframeworks.map(\.lastPathComponent), ["First.xcframework"])
        XCTAssertEqual(secondContents.xcframeworks.map(\.lastPathComponent), ["Second.xcframework"])
        XCTAssertNotNil(firstContents.snapshotLease)
        XCTAssertTrue(firstContents.snapshotLease === secondContents.snapshotLease)
        XCTAssertEqual(firstContents.snapshotLease?.directory, snapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))
        XCTAssertEqual(runner.count("/usr/bin/curl"), 0)
        XCTAssertEqual(runner.count("/bin/sh"), 0, "A project-local file URL must not launch the network downloader")
        XCTAssertEqual(runner.count("/usr/bin/tar"), 0, "Archive processing must stay in-process")
        XCTAssertEqual(store.artifactIndexBuildCount, 1, "One archive artifact index should serve both selections")
    }

    func testConcurrentRemoteDeclarationsWaitForOneAuthenticatedSnapshot() throws {
        let directory = try fixture()
        let source = directory.appendingPathComponent("concurrent-source", isDirectory: true)
        let firstFramework = source.appendingPathComponent("First.xcframework", isDirectory: true)
        let secondFramework = source.appendingPathComponent("Second.xcframework", isDirectory: true)
        try FileManager.default.createDirectory(at: firstFramework, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFramework, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: firstFramework.appendingPathComponent("Info.plist"))
        try Data("second".utf8).write(to: secondFramework.appendingPathComponent("Info.plist"))
        let archive = directory.appendingPathComponent("Concurrent.tar")
        _ = try ProcessRunner().run("/usr/bin/tar", ["-cf", archive.path, "-C", source.path, "."], in: nil)
        let archiveData = try Data(contentsOf: archive)
        let digest = try BinaryStore.sha256(of: archive)
        try "target 'App' do\n  binary 'Remote', url: 'https://example.com/Concurrent.tar', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let template = try Installer(directory: directory).manifest().binaries[0]
        var first = template
        first.name = "FirstBinary"
        first.xcframeworks = ["First.xcframework"]
        var second = template
        second.name = "SecondBinary"
        second.xcframeworks = ["Second.xcframework"]
        let firstBinary = first
        let secondBinary = second

        let runner = CountingProcessRunner()
        let downloader = BlockingArchiveDownloadClient(archive: archiveData)
        let store = StoreBox(BinaryStore(
            cache: directory.appendingPathComponent("concurrent-cache"), runner: runner, offline: false,
            downloader: downloader))
        let results = ConcurrentContentResults()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "swiftpods.remote-memo-test", attributes: .concurrent)

        group.enter()
        queue.async {
            defer { group.leave() }
            results.append { try store.store.contents(
                firstBinary, podfileDirectory: directory) }
        }
        XCTAssertEqual(downloader.firstDownloadStarted.wait(timeout: .now() + 5), .success)
        let secondStarted = DispatchSemaphore(value: 0)
        group.enter()
        queue.async {
            defer { group.leave() }
            secondStarted.signal()
            results.append { try store.store.contents(
                secondBinary, podfileDirectory: directory) }
        }
        XCTAssertEqual(secondStarted.wait(timeout: .now() + 5), .success)
        Thread.sleep(forTimeInterval: 0.02)
        downloader.releaseFirstDownload.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)

        let captured = results.snapshot
        XCTAssertTrue(captured.failures.isEmpty, "\(captured.failures)")
        XCTAssertEqual(Set(captured.names), ["First.xcframework", "Second.xcframework"])
        XCTAssertEqual(captured.leases.count, 2)
        if captured.leases.count == 2 { XCTAssertTrue(captured.leases[0] === captured.leases[1]) }
        if let lease = captured.leases.first {
            XCTAssertTrue(FileManager.default.fileExists(atPath: lease.directory.path))
        }
        XCTAssertEqual(runner.count("/usr/bin/curl"), 0)
        XCTAssertEqual(runner.count("/bin/sh"), 0, "A project-local file URL must not launch the network downloader")
        XCTAssertEqual(downloader.invocationCount, 1)
        XCTAssertEqual(runner.count("/usr/bin/tar"), 0)
    }

    func testBinaryManifestEscapesSourceControlCharacters() throws {
        let directory = try fixture("target 'App' do\n  binary 'Kit', path: 'Kit.xcframework'\nend\n")
        let framework = directory.appendingPathComponent("Kit.xcframework", isDirectory: true)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: framework.appendingPathComponent("Info.plist"))
        var binary = try Installer(directory: directory).manifest().binaries[0]
        binary.linkerFlags = ["line\nbreak\r\t\0\u{7F}\u{2028}\\\""]
        let manifest = try BinaryPackage(
            entries: [.init(binary: binary, xcframeworks: [framework], resources: [])], platforms: []).manifest()

        XCTAssertTrue(manifest.contains(#""line\nbreak\r\t\u{0}\u{7F}\u{2028}\\\"""#), manifest)
        XCTAssertFalse(manifest.contains("line\nbreak"), manifest)
    }

    func testBinaryPackageRejectsCaseAndUnicodeFilesystemCollisions() throws {
        let directory = try fixture("target 'App' do\n  binary 'Kit', path: 'Kit.xcframework'\nend\n")
        var first = try Installer(directory: directory).manifest().binaries[0]
        var second = first
        first.name = "SDK"
        second.name = "sdk"
        XCTAssertThrowsError(try BinaryPackage(
            entries: [
                .init(binary: first, xcframeworks: [], resources: []),
                .init(binary: second, xcframeworks: [], resources: []),
            ], platforms: []).validate()) { XCTAssertTrue("\($0)".contains("collide"), "\($0)") }

        first.name = "First"
        first.source = .remote(url: "https://example.invalid/binary.zip", sha256: String(repeating: "0", count: 64))
        let composed = URL(fileURLWithPath: "/virtual/Caf\u{E9}.xcframework")
        let decomposed = URL(fileURLWithPath: "/virtual/Cafe\u{301}.xcframework")
        XCTAssertThrowsError(try BinaryPackage(
            entries: [.init(binary: first, xcframeworks: [composed, decomposed], resources: [])], platforms: []).validate()) {
            XCTAssertTrue("\($0)".contains("colliding frameworks"), "\($0)")
        }
    }

    func testOfflineCacheIsRematerializedFromVerifiedArchive() throws {
        let directory = try fixture()
        let source = directory.appendingPathComponent("archive-source", isDirectory: true)
        let framework = source.appendingPathComponent("SDK/Remote.xcframework", isDirectory: true)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: framework.appendingPathComponent("Info.plist"))
        let archive = directory.appendingPathComponent("Remote.zip")
        _ = try ProcessRunner().run("/usr/bin/ditto", ["-c", "-k", source.path, archive.path], in: nil)
        let digest = try BinaryStore.sha256(of: archive)
        try "target 'App' do\n  binary 'Remote', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        let storage = BinaryStore.versionedCacheRoot(for: cache)

        _ = try BinaryStore(cache: cache, runner: ProcessRunner(), offline: false)
            .contents(binary, podfileDirectory: directory)
        let poison = storage.appendingPathComponent("\(digest)/content/poison")
        try Data("poison".utf8).write(to: poison)
        try FileManager.default.removeItem(at: archive)

        let trusted = try BinaryStore(cache: cache, runner: ProcessRunner(), offline: true)
            .contents(binary, podfileDirectory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: poison.path))

        // Changing the shared cache after `contents` returns must not change the private snapshot being installed.
        let cachedInfo = storage.appendingPathComponent("\(digest)/content/SDK/Remote.xcframework/Info.plist")
        try Data("changed after verification".utf8).write(to: cachedInfo)
        let rendered = directory.appendingPathComponent("rendered", isDirectory: true)
        let package = try BinaryPackage(
            entries: [.init(
                binary: binary, xcframeworks: trusted.xcframeworks, resources: trusted.resources,
                xcframeworkPaths: trusted.xcframeworkPaths, resourcePaths: trusted.resourcePaths,
                snapshotLease: trusted.snapshotLease)],
            platforms: [])
        _ = try package.render(into: rendered)
        XCTAssertEqual(
            try Data(contentsOf: rendered.appendingPathComponent("Artifacts/Remote/Remote.xcframework/Info.plist")),
            Data("plist".utf8))

        try Data("tampered private snapshot".utf8)
            .write(to: trusted.xcframeworks[0].appendingPathComponent("Info.plist"))
        XCTAssertThrowsError(try package.render(into: directory.appendingPathComponent("tampered-remote-render"))) {
            XCTAssertTrue("\($0)".contains("changed before it was copied"), "\($0)")
        }
    }

    func testBinaryCacheRejectsRefreshStagingRenameAndRecreateABA() throws {
        let directory = try fixture()
        let archive = directory.appendingPathComponent("Refresh.tar")
        let payload = TarEntry(
            name: "Kit.xcframework/payload", type: 0x30, link: "",
            contents: Data(repeating: 0x41, count: 16 * 1_024 * 1_024), mode: 0o644)
        try tar([
            .file("Kit.xcframework/Info.plist", "plist"),
            payload,
        ]).write(to: archive)
        let digest = try BinaryStore.sha256(of: archive)
        try "target 'App' do\n  binary 'Kit', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]
        let cache = directory.appendingPathComponent("refresh-cache", isDirectory: true)
        let storage = BinaryStore.versionedCacheRoot(for: cache)
        _ = try BinaryStore(
            cache: cache, runner: ProcessRunner(), offline: false, minimumFreeSpaceReserveBytes: 0
        ).contents(binary, podfileDirectory: directory)

        let mutationSucceeded = DispatchSemaphore(value: 0)
        let mutationFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { mutationFinished.signal() }
            let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
            while DispatchTime.now().uptimeNanoseconds < deadline {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: storage.path)) ?? []
                if let name = names.first(where: { $0.hasPrefix(".refresh-") }) {
                    let staging = storage.appendingPathComponent(name, isDirectory: true)
                    let moved = storage.appendingPathComponent(
                        ".attacker-moved-" + UUID().uuidString, isDirectory: true)
                    if rename(staging.path, moved.path) == 0, mkdir(staging.path, 0o700) == 0 {
                        try? Data("replacement".utf8).write(to: staging.appendingPathComponent("sentinel"))
                        mutationSucceeded.signal()
                        return
                    }
                }
                usleep(100)
            }
        }

        XCTAssertThrowsError(try BinaryStore(
            cache: cache, runner: ProcessRunner(), offline: true, minimumFreeSpaceReserveBytes: 0
        ).contents(binary, podfileDirectory: directory)) { error in
            XCTAssertTrue("\(error)".contains("invalid cached archive"), "\(error)")
        }
        XCTAssertEqual(mutationFinished.wait(timeout: .now() + 6), .success)
        XCTAssertEqual(mutationSucceeded.wait(timeout: .now()), .success)
        let replacements = try FileManager.default.contentsOfDirectory(atPath: storage.path)
            .filter { $0.hasPrefix(".refresh-") }
        XCTAssertEqual(replacements.count, 1)
        if let replacement = replacements.first {
            XCTAssertEqual(try Data(contentsOf: storage.appendingPathComponent(replacement + "/sentinel")),
                Data("replacement".utf8))
        }
    }

    func testBinaryCacheRefreshDoesNotDeleteReboundDestination() throws {
        let directory = try fixture()
        let archive = directory.appendingPathComponent("RefreshDestination.tar")
        let payload = TarEntry(
            name: "Kit.xcframework/payload", type: 0x30, link: "",
            contents: Data(repeating: 0x42, count: 16 * 1_024 * 1_024), mode: 0o644)
        try tar([
            .file("Kit.xcframework/Info.plist", "plist"),
            payload,
        ]).write(to: archive)
        let digest = try BinaryStore.sha256(of: archive)
        try "target 'App' do\n  binary 'Kit', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]
        let cache = directory.appendingPathComponent("refresh-destination-cache", isDirectory: true)
        let storage = BinaryStore.versionedCacheRoot(for: cache)
        _ = try BinaryStore(
            cache: cache, runner: ProcessRunner(), offline: false, minimumFreeSpaceReserveBytes: 0
        ).contents(binary, podfileDirectory: directory)

        let entry = storage.appendingPathComponent(digest, isDirectory: true)
        let content = entry.appendingPathComponent("content", isDirectory: true)
        let displaced = entry.appendingPathComponent("content-before-race", isDirectory: true)
        let sentinel = content.appendingPathComponent("sentinel")
        let mutationSucceeded = DispatchSemaphore(value: 0)
        let mutationFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { mutationFinished.signal() }
            let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
            while DispatchTime.now().uptimeNanoseconds < deadline {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: storage.path)) ?? []
                guard names.contains(where: { $0.hasPrefix(".refresh-") }) else {
                    usleep(100)
                    continue
                }
                if rename(content.path, displaced.path) == 0, mkdir(content.path, 0o700) == 0 {
                    try? Data("replacement".utf8).write(to: sentinel)
                    mutationSucceeded.signal()
                    return
                }
                usleep(100)
            }
        }

        XCTAssertThrowsError(try BinaryStore(
            cache: cache, runner: ProcessRunner(), offline: false, minimumFreeSpaceReserveBytes: 0
        ).contents(binary, podfileDirectory: directory)) { error in
            XCTAssertTrue("\(error)".contains("cache changed concurrently"), "\(error)")
        }
        XCTAssertEqual(mutationFinished.wait(timeout: .now() + 6), .success)
        XCTAssertEqual(mutationSucceeded.wait(timeout: .now()), .success)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("replacement".utf8))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: displaced.appendingPathComponent("Kit.xcframework/Info.plist").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.path))
    }

    func testArchiveExtractionCannotTraverseOrWriteThroughSymlink() throws {
        let directory = try fixture()
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let cache = directory.appendingPathComponent("cache", isDirectory: true)

        func reject(_ name: String, entries: [TarEntry]) throws {
            let archive = directory.appendingPathComponent(name + ".tar")
            try tar(entries).write(to: archive)
            let digest = try BinaryStore.sha256(of: archive)
            try "target 'App' do\n  binary 'Remote', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
                .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
            let binary = try Installer(directory: directory).manifest().binaries[0]
            XCTAssertThrowsError(try BinaryStore(cache: cache, runner: ProcessRunner(), offline: false)
                .contents(binary, podfileDirectory: directory))
        }

        try reject("traversal", entries: [.file("../../../outside/traversal", "owned")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("traversal").path))
        try reject("symlink", entries: [
            .symlink("link", to: "../../../outside"),
            .file("link/pwned", "owned"),
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("pwned").path))
        let victim = outside.appendingPathComponent("victim")
        try Data("unchanged".utf8).write(to: victim)
        try reject("hardlink", entries: [
            .hardlink("Kit.xcframework/Info.plist", to: "../../outside/victim"),
        ])
        XCTAssertEqual(try Data(contentsOf: victim), Data("unchanged".utf8))
    }

    func testArchiveExtractionPreservesSafeLinksAndExecutableBitsWithoutTar() throws {
        let directory = try fixture()
        let archive = directory.appendingPathComponent("Links.tar")
        try tar([
            .file("Kit.xcframework/Info.plist", "plist"),
            .file("Kit.xcframework/tool", "executable", mode: 0o755),
            .hardlink("Kit.xcframework/tool-copy", to: "Kit.xcframework/tool"),
            .symlink("Kit.xcframework/tool-link", to: "tool"),
        ]).write(to: archive)
        let digest = try BinaryStore.sha256(of: archive)
        try "target 'App' do\n  binary 'Kit', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]
        let runner = CountingProcessRunner()
        let configuredCache = directory.appendingPathComponent("cache")
        let contents = try BinaryStore(
            cache: configuredCache, runner: runner, offline: false
        ).contents(binary, podfileDirectory: directory)
        let framework = BinaryStore.versionedCacheRoot(for: configuredCache)
            .appendingPathComponent("\(digest)/content/Kit.xcframework", isDirectory: true)
        let tool = framework.appendingPathComponent("tool")
        let copy = framework.appendingPathComponent("tool-copy")
        let link = framework.appendingPathComponent("tool-link")
        var toolStatus = stat()
        var copyStatus = stat()
        XCTAssertEqual(tool.path.withCString { lstat($0, &toolStatus) }, 0)
        XCTAssertEqual(copy.path.withCString { lstat($0, &copyStatus) }, 0)
        XCTAssertEqual(toolStatus.st_dev, copyStatus.st_dev)
        XCTAssertEqual(toolStatus.st_ino, copyStatus.st_ino)
        XCTAssertEqual(toolStatus.st_mode & 0o111, 0o111)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "tool")
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "executable")
        XCTAssertEqual(try String(
            contentsOf: try XCTUnwrap(contents.xcframeworks.first).appendingPathComponent("tool-copy"),
            encoding: .utf8), "executable")
        XCTAssertEqual(runner.count("/usr/bin/tar"), 0)
    }

    func testZipExtractionPreservesXCFrameworkStyleSafeLinks() throws {
        let directory = try fixture()
        let source = directory.appendingPathComponent("zip-links", isDirectory: true)
        let framework = source.appendingPathComponent("Kit.xcframework", isDirectory: true)
        let versions = framework.appendingPathComponent(
            "ios-arm64/Kit.framework/Versions", isDirectory: true)
        let version = versions.appendingPathComponent("A", isDirectory: true)
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: framework.appendingPathComponent("Info.plist"))
        let executable = version.appendingPathComponent("Kit")
        try Data("executable".utf8).write(to: executable)
        XCTAssertEqual(chmod(executable.path, 0o755), 0)
        try FileManager.default.createSymbolicLink(
            atPath: versions.appendingPathComponent("Current").path, withDestinationPath: "A")
        try FileManager.default.createSymbolicLink(
            atPath: framework.appendingPathComponent("ios-arm64/Kit.framework/Kit").path,
            withDestinationPath: "Versions/Current/Kit")
        let archive = directory.appendingPathComponent("Links.zip")
        _ = try ProcessRunner().run("/usr/bin/zip", ["-qry", "-y", archive.path, "."], in: source)
        let digest = try BinaryStore.sha256(of: archive)
        try "target 'App' do\n  binary 'Kit', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]
        let runner = CountingProcessRunner()

        let contents = try BinaryStore(
            cache: directory.appendingPathComponent("zip-cache"), runner: runner, offline: false
        ).contents(binary, podfileDirectory: directory)
        let extracted = try XCTUnwrap(contents.xcframeworks.first)
        let extractedFramework = extracted.appendingPathComponent("ios-arm64/Kit.framework")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: extractedFramework.appendingPathComponent("Versions/Current").path), "A")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: extractedFramework.appendingPathComponent("Kit").path), "Versions/Current/Kit")
        XCTAssertEqual(try String(
            contentsOf: extractedFramework.appendingPathComponent("Kit"), encoding: .utf8), "executable")
        var executableStatus = stat()
        XCTAssertEqual(extractedFramework.appendingPathComponent("Versions/A/Kit").path.withCString {
            lstat($0, &executableStatus)
        }, 0)
        XCTAssertEqual(executableStatus.st_mode & 0o111, 0o111)
        XCTAssertEqual(runner.count("/usr/bin/tar"), 0)
    }

    func testArchiveExtractionSupportsAllowedFormatsAndCompressionWithoutExternalTar() throws {
        let directory = try fixture()
        let source = directory.appendingPathComponent("format-source", isDirectory: true)
        let framework = source.appendingPathComponent("Kit.xcframework", isDirectory: true)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: framework.appendingPathComponent("Info.plist"))
        var archives: [URL] = []
        for (flag, name) in [
            ("-cf", "Kit.tar"), ("-czf", "Kit.tar.gz"), ("-cjf", "Kit.tar.bz2"),
            ("-cJf", "Kit.tar.xz"),
        ] {
            let archive = directory.appendingPathComponent(name)
            _ = try ProcessRunner().run("/usr/bin/tar", [flag, archive.path, "-C", source.path, "."], in: nil)
            archives.append(archive)
        }
        let zip = directory.appendingPathComponent("Kit.zip")
        _ = try ProcessRunner().run("/usr/bin/ditto", ["-c", "-k", source.path, zip.path], in: nil)
        archives.append(zip)

        for (index, archive) in archives.enumerated() {
            let digest = try BinaryStore.sha256(of: archive)
            try "target 'App' do\n  binary 'Kit', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
                .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
            let binary = try Installer(directory: directory).manifest().binaries[0]
            let runner = CountingProcessRunner()
            let contents = try BinaryStore(
                cache: directory.appendingPathComponent("cache-\(index)"), runner: runner, offline: false
            ).contents(binary, podfileDirectory: directory)
            XCTAssertEqual(contents.xcframeworks.first?.lastPathComponent, "Kit.xcframework", archive.lastPathComponent)
            XCTAssertEqual(runner.count("/usr/bin/tar"), 0, archive.lastPathComponent)
        }
    }

    func testArchiveExtractionUsesAuthenticatedWorkerWithoutExternalTar() throws {
        let directory = try fixture()
        let trusted = try tar([.file("Kit.xcframework/Info.plist", "trusted")])
        let archive = directory.appendingPathComponent("Remote.tar")
        try trusted.write(to: archive)
        let digest = try BinaryStore.sha256(of: archive)
        try "target 'App' do\n  binary 'Kit', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        let runner = CountingProcessRunner()

        let contents = try BinaryStore(cache: cache, runner: runner, offline: false)
            .contents(binary, podfileDirectory: directory)
        XCTAssertEqual(
            try String(contentsOf: contents.xcframeworks[0].appendingPathComponent("Info.plist"), encoding: .utf8),
            "trusted")
        XCTAssertEqual(runner.count("/usr/bin/tar"), 0)
    }

    func testArchivePreflightBoundsPAXPathnameBeforeSwiftStringAllocation() throws {
        let directory = try fixture()
        let archive = directory.appendingPathComponent("oversized-pax.tar")
        try paxTar(path: String(repeating: "a", count: 17_000), contents: "value").write(to: archive)

        XCTAssertThrowsError(try BinaryStore.inspectArchive(
            at: archive, url: "https://example.com/oversized-pax.tar"
        )) { error in
            XCTAssertTrue("\(error)".contains("excessively long pathname"), "\(error)")
        }
    }

    func testUncompressedTarPreflightRejectsOversizedPAXRecordBeforeLibarchive() throws {
        let directory = try fixture()
        let archive = directory.appendingPathComponent("oversized-pax-record.tar")
        try paxTar(
            path: String(repeating: "a", count: 1 * 1_024 * 1_024 + 1), contents: "value"
        ).write(to: archive)

        XCTAssertThrowsError(try BinaryStore.inspectArchive(
            at: archive, url: "https://example.com/oversized-pax-record.tar"
        )) { error in
            XCTAssertTrue("\(error)".contains("metadata exceeds"), "\(error)")
        }
    }

    func testCompressedOversizedPAXIsRejectedByIsolatedWorker() throws {
        let directory = try fixture()
        let source = directory.appendingPathComponent("oversized-pax.tar")
        let archive = directory.appendingPathComponent("oversized-pax.tar.gz")
        try paxTar(
            path: String(repeating: "a", count: 2 * 1_024 * 1_024), contents: "value"
        ).write(to: source)
        try ProcessRunner().runData("/usr/bin/gzip", ["-c", source.path], in: nil).write(to: archive)
        let digest = try BinaryStore.sha256(of: archive)
        try "target 'App' do\n  binary 'Kit', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]
        let runner = CountingProcessRunner()

        XCTAssertThrowsError(try BinaryStore(
            cache: directory.appendingPathComponent("cache"), runner: runner, offline: false
        ).contents(binary, podfileDirectory: directory)) { error in
            XCTAssertTrue(
                "\(error)".contains("Special header too large")
                    || "\(error)".contains("metadata exceeds")
                    || "\(error)".contains("excessively long pathname"),
                "\(error)")
            guard let reason = (error as? SwiftPodsError)?.commandFailure?.reason,
                case .exitStatus = reason
            else { return XCTFail("Compressed PAX did not fail through the isolated worker: \(error)") }
        }
        XCTAssertEqual(runner.count("/usr/bin/tar"), 0)
    }

    func testZIPCentralDirectoryEntryFloodIsRejectedByIsolatedWorker() throws {
        let directory = try fixture()
        let archive = directory.appendingPathComponent("entry-flood.zip")
        try emptyZIP(entryCount: 50_001).write(to: archive)
        let digest = try BinaryStore.sha256(of: archive)
        try "target 'App' do\n  binary 'Kit', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]
        let runner = CountingProcessRunner()

        XCTAssertThrowsError(try BinaryStore(
            cache: directory.appendingPathComponent("cache"), runner: runner, offline: false
        ).contents(binary, podfileDirectory: directory)) { error in
            XCTAssertTrue(
                "\(error)".contains("too many entries") || "\(error)".contains("metadata exceeds"),
                "\(error)")
            guard let reason = (error as? SwiftPodsError)?.commandFailure?.reason,
                case .exitStatus = reason
            else { return XCTFail("ZIP entry flood did not fail through the isolated worker: \(error)") }
        }
        XCTAssertEqual(runner.count("/usr/bin/tar"), 0)
    }

    func testArchivePreflightRejectsDeclaredSizeBeforeReadingTruncatedPayload() throws {
        let directory = try fixture()
        var data = try tar([.file("Kit.xcframework/Huge", "x")])
        rewriteTarDeclaredSize(&data, size: 2_048)
        let archive = directory.appendingPathComponent("declared-size.tar")
        try data.write(to: archive)

        XCTAssertThrowsError(try BinaryStore.inspectArchive(
            at: archive, url: "https://example.com/declared-size.tar",
            limits: .init(entries: 8, bytes: 1_024, depth: 8, internalHardlinksOnly: true)
        )) { error in
            XCTAssertTrue("\(error)".contains("larger than 1024 bytes"), "\(error)")
        }
    }

    func testArchivePostExtractionRequiresExactAuthenticatedTreeCounts() throws {
        XCTAssertNoThrow(try BinaryStore.validateExtractedArchiveCounts(
            declaredEntries: 4, declaredBytes: 1_024, actualEntries: 4, actualBytes: 1_024))
        XCTAssertThrowsError(try BinaryStore.validateExtractedArchiveCounts(
            declaredEntries: 4, declaredBytes: 1_024, actualEntries: 3, actualBytes: 1_024)) { error in
            XCTAssertTrue("\(error)".contains("does not match"), "\(error)")
        }
        XCTAssertThrowsError(try BinaryStore.validateExtractedArchiveCounts(
            declaredEntries: 4, declaredBytes: 1_024, actualEntries: 4, actualBytes: 1_023)) { error in
            XCTAssertTrue("\(error)".contains("does not match"), "\(error)")
        }
    }

    func testAppleDoubleMetadataIsAuthenticatedAndBudgetedButNotMaterialized() throws {
        let directory = try fixture()
        let archive = directory.appendingPathComponent("AppleDouble.tar")
        let plist = "plist"
        let fork = "metadata"
        let rootFork = "root-metadata"
        try tar([
            .file("Kit.xcframework/Info.plist", plist),
            .file("__MACOSX/Kit.xcframework/._Info.plist", fork),
            .file("._README", rootFork),
        ]).write(to: archive)

        let inspection = try BinaryStore.inspectArchive(at: archive, url: archive.absoluteString)
        XCTAssertEqual(inspection.headers, 3)
        XCTAssertEqual(inspection.entries, 2)
        XCTAssertEqual(inspection.bytes, Int64(plist.utf8.count))
        XCTAssertEqual(inspection.processedEntries, 6)
        XCTAssertEqual(
            inspection.processedBytes, Int64(plist.utf8.count + fork.utf8.count + rootFork.utf8.count))
        XCTAssertThrowsError(try BinaryStore.inspectArchive(
            at: archive, url: archive.absoluteString,
            limits: .init(
                entries: inspection.processedEntries, bytes: inspection.processedBytes - 1, depth: 8,
                internalHardlinksOnly: true)
        )) { error in
            XCTAssertTrue("\(error)".contains("larger than"), "\(error)")
        }

        let digest = try BinaryStore.sha256(of: archive)
        try "target 'App' do\n  binary 'Kit', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        let contents = try BinaryStore(
            cache: cache, runner: ProcessRunner(), offline: false, minimumFreeSpaceReserveBytes: 0
        ).contents(binary, podfileDirectory: directory)

        XCTAssertEqual(contents.xcframeworks.map(\.lastPathComponent), ["Kit.xcframework"])
        let stored = BinaryStore.versionedCacheRoot(for: cache)
            .appendingPathComponent(digest).appendingPathComponent("content")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.appendingPathComponent("__MACOSX").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.appendingPathComponent("._README").path))
    }

    func testFileTreeWalkDoesNotDropVersionedFrameworkContentsAfterSymlinkAliases() throws {
        let directory = try fixture()
        let source = directory.appendingPathComponent("Source", isDirectory: true)
        let framework = source.appendingPathComponent("Kit.framework", isDirectory: true)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        // Create aliases before their physical targets, matching ordinary versioned framework archive ordering.
        try FileManager.default.createSymbolicLink(
            atPath: framework.appendingPathComponent("Kit").path,
            withDestinationPath: "Versions/Current/Kit")
        try FileManager.default.createSymbolicLink(
            atPath: framework.appendingPathComponent("Headers").path,
            withDestinationPath: "Versions/Current/Headers")
        let versions = framework.appendingPathComponent("Versions", isDirectory: true)
        try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            atPath: versions.appendingPathComponent("Current").path, withDestinationPath: "A")
        let physicalHeaders = versions.appendingPathComponent("A/Headers", isDirectory: true)
        try FileManager.default.createDirectory(at: physicalHeaders, withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: versions.appendingPathComponent("A/Kit"))
        try Data("header".utf8).write(to: physicalHeaders.appendingPathComponent("Kit.h"))

        let before = try SecureFileTree.validate(
            source, allowRootSymlink: false, limits: .archive, hashingContents: false)
        XCTAssertEqual(before.entries, 9)
        XCTAssertEqual(before.bytes, 12)

        try SecureFileTree.normalizePermissions(in: source)
        let normalized = try SecureFileTree.validate(
            source, allowRootSymlink: false, limits: .archive, hashingContents: false)
        XCTAssertEqual(normalized.entries, before.entries)
        XCTAssertEqual(normalized.bytes, before.bytes)

        let copied = directory.appendingPathComponent("Copied", isDirectory: true)
        try SecureFileTree.copySanitizedTree(from: source, to: copied, limits: .archive)
        let copiedInspection = try SecureFileTree.validate(
            copied, allowRootSymlink: false, limits: .archive, hashingContents: false)
        XCTAssertEqual(copiedInspection.entries, before.entries)
        XCTAssertEqual(copiedInspection.bytes, before.bytes)
        XCTAssertEqual(
            try String(contentsOf: copied.appendingPathComponent("Kit.framework/Versions/A/Kit"), encoding: .utf8),
            "binary")
    }

    func testArtifactSearchDoesNotDropPhysicalSiblingAfterSymlink() throws {
        let directory = try fixture()
        let root = directory.appendingPathComponent("Artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("Alias").path, withDestinationPath: "Kit.xcframework")
        let framework = root.appendingPathComponent("Kit.xcframework", isDirectory: true)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: false)

        XCTAssertEqual(try BinaryStore.find(root, extension: "xcframework"), [framework])
    }

    func testArchivePreflightCountsImplicitParentDirectoriesBeforeExtraction() throws {
        let directory = try fixture()
        let one = directory.appendingPathComponent("one.tar")
        try tar([.file("a/b/c/file", "x")]).write(to: one)
        let oneInspection = try BinaryStore.inspectArchive(
            at: one, url: "https://example.com/one.tar",
            limits: .init(entries: 4, bytes: 1_024, depth: 8, internalHardlinksOnly: true))
        XCTAssertEqual(oneInspection.headers, 1)
        XCTAssertEqual(oneInspection.entries, 4, "three implicit parents and the file must all be budgeted")

        let two = directory.appendingPathComponent("two.tar")
        try tar([
            .file("a/b/c/file", "x"),
            .file("d/e/f/file", "y"),
        ]).write(to: two)
        XCTAssertThrowsError(try BinaryStore.inspectArchive(
            at: two, url: "https://example.com/two.tar",
            limits: .init(entries: 7, bytes: 1_024, depth: 8, internalHardlinksOnly: true)
        )) { error in
            XCTAssertTrue("\(error)".contains("implicit directories"), "\(error)")
        }
    }

    func testArchivePreflightBudgetsImplicitPrefixAndDictionaryMetadata() throws {
        let directory = try fixture()
        let archive = directory.appendingPathComponent("metadata.tar")
        try tar([.file("a/b/c/d/e/f/g/Kit.xcframework/Info.plist", "x")]).write(to: archive)

        XCTAssertThrowsError(try BinaryStore.inspectArchive(
            at: archive, url: "https://example.com/metadata.tar",
            limits: .init(entries: 32, bytes: 1_024, depth: 16, internalHardlinksOnly: true),
            metadataLimit: 4 * 1_024
        )) { error in
            XCTAssertTrue("\(error)".contains("metadata exceeds"), "\(error)")
        }
    }

    func testCacheLockWaitIsBounded() throws {
        let directory = try fixture()
        let lock = directory.appendingPathComponent("lock")
        let first = lock.path.withCString { open($0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600) }
        XCTAssertGreaterThanOrEqual(first, 0)
        defer { if first >= 0 { close(first) } }
        let second = lock.path.withCString { open($0, O_RDWR | O_CLOEXEC) }
        XCTAssertGreaterThanOrEqual(second, 0)
        defer { if second >= 0 { close(second) } }
        XCTAssertEqual(flock(first, LOCK_EX | LOCK_NB), 0)
        defer { flock(first, LOCK_UN) }

        let started = Date()
        XCTAssertThrowsError(try BinaryStore.acquireCacheLock(second, timeout: 0.03)) {
            XCTAssertTrue("\($0)".contains("Timed out"), "\($0)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    func testCacheLockRejectsPathReplacementWhileWaitingForFlock() throws {
        let directory = try fixture()
        let archive = directory.appendingPathComponent("Remote.tar")
        try tar([.file("Kit.xcframework/Info.plist", "plist")]).write(to: archive)
        let digest = try BinaryStore.sha256(of: archive)
        try "target 'App' do\n  binary 'Kit', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        let storage = BinaryStore.versionedCacheRoot(for: cache)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(cache.path, 0o700), 0)
        XCTAssertEqual(chmod(storage.path, 0o700), 0)
        let lock = storage.appendingPathComponent(".lock-global")
        let holder = lock.path.withCString {
            open($0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        XCTAssertGreaterThanOrEqual(holder, 0)
        defer { if holder >= 0 { close(holder) } }
        XCTAssertEqual(flock(holder, LOCK_EX), 0)

        var identity = stat()
        XCTAssertEqual(fstat(holder, &identity), 0)
        let store = StoreBox(BinaryStore(cache: cache, runner: ProcessRunner(), offline: false))
        let result = ProcessRunResult()
        DispatchQueue.global(qos: .userInitiated).async {
            result.run { _ = try store.store.contents(binary, podfileDirectory: directory) }
        }

        func matchingDescriptors() -> Int {
            var count = 0
            for descriptor in 0..<getdtablesize() {
                var status = stat()
                if fstat(descriptor, &status) == 0,
                    status.st_dev == identity.st_dev, status.st_ino == identity.st_ino
                { count += 1 }
            }
            return count
        }
        let openDeadline = Date().addingTimeInterval(2)
        while matchingDescriptors() < 2, Date() < openDeadline { usleep(5_000) }
        XCTAssertGreaterThanOrEqual(matchingDescriptors(), 2, "Cache operation did not open the held lock")
        usleep(50_000)

        XCTAssertEqual(unlink(lock.path), 0)
        let replacement = lock.path.withCString {
            open($0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        XCTAssertGreaterThanOrEqual(replacement, 0)
        if replacement >= 0 { close(replacement) }
        XCTAssertEqual(flock(holder, LOCK_UN), 0)
        XCTAssertEqual(result.completion.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(result.failure?.contains("changed while it was being acquired") == true, result.failure ?? "no failure")
    }

    func testCacheLockRejectsPathReplacementBeforeUnlockingAfterOperation() throws {
        let directory = try fixture()
        let archive = directory.appendingPathComponent("Remote.tar")
        try tar([.file("Kit.xcframework/Info.plist", "plist")]).write(to: archive)
        let digest = try BinaryStore.sha256(of: archive)
        try "target 'App' do\n  binary 'Kit', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        let storage = BinaryStore.versionedCacheRoot(for: cache)
        let globalLock = storage.appendingPathComponent(".lock-global")
        let store = BinaryStore(
            cache: cache, runner: ProcessRunner(), offline: false,
            cacheLockOperationHook: { lockName in
                guard lockName == ".lock-global" else { return }
                _ = globalLock.path.withCString { unlink($0) }
                let replacement = globalLock.path.withCString {
                    open($0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
                }
                if replacement >= 0 { close(replacement) }
            })

        XCTAssertThrowsError(try store.contents(binary, podfileDirectory: directory)) { error in
            XCTAssertTrue("\(error)".contains("lock changed while it was held"), "\(error)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: globalLock.path))
    }

    func testArchivePreflightParsesSystemTarAndZipWithSpaces() throws {
        let directory = try fixture()
        let source = directory.appendingPathComponent("source", isDirectory: true)
        let resource = source.appendingPathComponent("My Bundle.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: resource, withIntermediateDirectories: true)
        try Data("value".utf8).write(to: resource.appendingPathComponent("value.txt"))
        let tarArchive = directory.appendingPathComponent("archive.tar")
        let zipArchive = directory.appendingPathComponent("archive.zip")
        _ = try ProcessRunner().run("/usr/bin/tar", ["-cf", tarArchive.path, "-C", source.path, "."], in: nil)
        _ = try ProcessRunner().run("/usr/bin/ditto", ["-c", "-k", source.path, zipArchive.path], in: nil)

        XCTAssertEqual(
            try BinaryStore.format(of: tarArchive, url: "https://example.com/archive.tar?token=signed"), .tar)
        XCTAssertEqual(
            try BinaryStore.format(of: zipArchive, url: "https://example.com/archive.zip?token=signed"), .zip)

        for (flag, name) in [("-czf", "archive.tar.gz"), ("-cjf", "archive.tar.bz2"), ("-cJf", "archive.tar.xz")] {
            let compressed = directory.appendingPathComponent(name)
            _ = try ProcessRunner().run(
                "/usr/bin/tar", [flag, compressed.path, "-C", source.path, "."], in: nil)
            XCTAssertEqual(
                try BinaryStore.format(of: compressed, url: "https://example.com/\(name)"), .tar, name)
        }
    }

    func testArchiveFormatRejectsRawAndGzipMtreeBeforeTarIsInvoked() throws {
        let directory = try fixture()
        let sentinel = directory.appendingPathComponent("sentinel")
        try Data("host-only".utf8).write(to: sentinel)
        let escapedSentinel = sentinel.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: " ", with: "\\040")
        let manifest = Data("""
            #mtree
            ./Kit.xcframework type=dir
            ./Kit.xcframework/Info.plist type=file mode=0644 contents=\(escapedSentinel)
            """.utf8)
        let raw = directory.appendingPathComponent("Remote.tar")
        try manifest.write(to: raw)
        let manifestFile = directory.appendingPathComponent("fixture.mtree")
        try manifest.write(to: manifestFile)
        let gzip = directory.appendingPathComponent("Remote.tar.gz")
        try ProcessRunner().runData("/usr/bin/gzip", ["-c", manifestFile.path], in: nil).write(to: gzip)

        for archive in [raw, gzip] {
            let digest = try BinaryStore.sha256(of: archive)
            try "target 'App' do\n  binary 'Kit', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
                .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
            let binary = try Installer(directory: directory).manifest().binaries[0]
            let runner = CountingProcessRunner()
            let cache = directory.appendingPathComponent("cache-" + archive.lastPathComponent, isDirectory: true)
            XCTAssertThrowsError(try BinaryStore(cache: cache, runner: runner, offline: false)
                .contents(binary, podfileDirectory: directory)) { error in
                    XCTAssertTrue("\(error)".contains("not a zip or tar archive"), "\(error)")
                }
            XCTAssertEqual(runner.count("/usr/bin/tar"), 0, "mtree must be rejected before archive extraction")
            XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent(digest).path))
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("host-only".utf8))
    }

    func testArchiveFormatAllowlistRejectsCPIOBeforeTarIsInvoked() throws {
        let directory = try fixture()
        let archive = directory.appendingPathComponent("Remote.tar")
        try newcCPIO(name: "Kit.xcframework/Info.plist", contents: Data("plist".utf8)).write(to: archive)
        let digest = try BinaryStore.sha256(of: archive)
        try "target 'App' do\n  binary 'Kit', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]
        let runner = CountingProcessRunner()

        XCTAssertThrowsError(try BinaryStore(
            cache: directory.appendingPathComponent("cache"), runner: runner, offline: false
        ).contents(binary, podfileDirectory: directory)) { error in
            XCTAssertTrue("\(error)".contains("not a zip or tar archive"), "\(error)")
        }
        XCTAssertEqual(runner.count("/usr/bin/tar"), 0, "cpio must be rejected by the libarchive allowlist")
    }

    func testArchiveControlCharacterParserDifferentialIsRejectedInProcess() throws {
        let directory = try fixture()
        let archive = directory.appendingPathComponent("control-character.tar")
        try tar([.file("Kit.xcframework/Info.plist\nforged-listing-entry", "plist")]).write(to: archive)
        let digest = try BinaryStore.sha256(of: archive)
        try "target 'App' do\n  binary 'Kit', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]
        let runner = CountingProcessRunner()

        XCTAssertThrowsError(try BinaryStore(
            cache: directory.appendingPathComponent("cache"), runner: runner, offline: false
        ).contents(binary, podfileDirectory: directory)) { error in
            XCTAssertTrue("\(error)".contains("unsafe pathname"), "\(error)")
        }
        XCTAssertEqual(runner.count("/usr/bin/tar"), 0)
    }

    func testArchiveInspectionDeadlineAppliesInsideLibarchiveReads() throws {
        let directory = try fixture()
        let archive = directory.appendingPathComponent("Remote.tar")
        try tar([.file("Kit.xcframework/Info.plist", "plist")]).write(to: archive)

        let started = Date()
        XCTAssertThrowsError(try BinaryStore.inspectArchive(
            at: archive, url: "https://example.com/Remote.tar", inspectionTimeout: 0
        )) { error in
            XCTAssertTrue("\(error)".contains("timed out"), "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    func testArchiveWorkerCompactsInheritedDescriptorsBeforeLoweringOpenFileLimit() throws {
        let directory = try fixture()
        let archive = directory.appendingPathComponent("Remote.tar")
        try tar([.file("Kit.xcframework/Info.plist", "plist")]).write(to: archive)
        let digest = try BinaryStore.sha256(of: archive)
        try "target 'App' do\n  binary 'Kit', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]

        // A long-running host may already have enough descriptors open that every capability passed to the isolated
        // worker is numbered above its fixed RLIMIT_NOFILE. Darwin still accepts fstat() on such an inherited descriptor,
        // but poll() reports POLLNVAL after the limit is lowered, so this reproduces the full-suite-only failure.
        var occupied: [Int32] = []
        defer { occupied.forEach { close($0) } }
        while occupied.last.map({ $0 < 48 }) ?? true {
            let descriptor = "/dev/null".withCString { open($0, O_RDONLY | O_CLOEXEC) }
            guard descriptor >= 0 else { return XCTFail("Cannot occupy low descriptors for archive-worker regression") }
            occupied.append(descriptor)
        }
        XCTAssertGreaterThanOrEqual(occupied.last ?? -1, 48)

        let contents = try BinaryStore(
            cache: directory.appendingPathComponent("cache"), runner: ProcessRunner(), offline: false
        ).contents(binary, podfileDirectory: directory)

        XCTAssertEqual(contents.xcframeworks.map(\.lastPathComponent), ["Kit.xcframework"])
    }

    func testArchivePreflightRejectsInvalidUTF8PathnameBeforeSwiftAllocation() throws {
        let directory = try fixture()
        var archiveData = try tar([.file("dummy", "value")])
        archiveData[0] = 0xFF
        rewriteTarChecksum(&archiveData)
        let archive = directory.appendingPathComponent("source.tar")
        try archiveData.write(to: archive)

        XCTAssertThrowsError(try BinaryStore.inspectArchive(
            at: archive, url: "https://example.com/source.tar"
        )) {
            XCTAssertTrue("\($0)".contains("not valid UTF-8"), "\($0)")
        }
    }

    func testCommandLineTerminationSignalCleansChildTreeBeforeReraisingSignal() throws {
        let directory = try fixture()
        let marker = directory.appendingPathComponent("child-received-term")
        let ready = directory.appendingPathComponent("child-ready")
        let process = Process()
        process.executableURL = try builtSwiftPodsExecutable()
        process.arguments = ["--swiftpods-internal-process-signal-probe-v1", marker.path, ready.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }

        let readyDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: ready.path), process.isRunning, Date() < readyDeadline {
            usleep(5_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "Signal probe child did not start")
        guard process.isRunning else { return XCTFail("Signal probe exited before receiving SIGTERM") }

        var children = [pid_t](repeating: 0, count: 16)
        let childCount = children.withUnsafeMutableBytes {
            proc_listchildpids(process.processIdentifier, $0.baseAddress, Int32($0.count))
        }
        XCTAssertGreaterThan(childCount, 0)
        guard childCount > 0 else { return }
        let child = children[0]

        XCTAssertEqual(kill(process.processIdentifier, SIGTERM), 0)
        let exitDeadline = Date().addingTimeInterval(9)
        while process.isRunning, Date() < exitDeadline { usleep(10_000) }
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            XCTFail("SwiftPods did not finish bounded signal cleanup")
        }
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGTERM)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "Child inherited SIG_IGN instead of receiving the graceful SIGTERM")

        let childExitDeadline = Date().addingTimeInterval(2)
        while kill(child, 0) == 0, Date() < childExitDeadline { usleep(10_000) }
        XCTAssertEqual(kill(child, 0), -1, "External command outlived terminated SwiftPods")
        XCTAssertEqual(errno, ESRCH)
    }

    func testProcessRunnerTerminatesTimedOutCommand() throws {
        XCTAssertThrowsError(try ProcessRunner(timeout: 0.05).run("/bin/sleep", ["5"], in: nil)) {
            XCTAssertTrue($0 is SwiftPodsError)
            XCTAssertTrue("\($0)".contains("timed out"), "\($0)")
        }
    }

    func testProcessRunnerParentEnforcesPhysicalMemoryCeiling() throws {
        let script = #"my @bytes; for (1..256) { push @bytes, "x" x 1048576; select(undef, undef, undef, 0.005); } sleep 5;"#
        XCTAssertThrowsError(try ProcessRunner().runData(
            "/usr/bin/perl", ["-e", script], in: nil, timeout: 5, maximumOutputBytes: 1_024,
            passingFileDescriptors: [], maximumPhysicalMemoryBytes: 32 * 1_024 * 1_024
        )) { error in
            XCTAssertTrue("\(error)".contains("physical footprint exceeded"), "\(error)")
        }
    }

    func testProcessRunnerAuthenticatesMappedExecutableBeforeResume() throws {
        let directory = try fixture()
        let marker = directory.appendingPathComponent("substituted-image-ran")
        let expectedDescriptor = "/bin/echo".withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard expectedDescriptor >= 0 else { return XCTFail("Cannot open expected executable") }
        defer { close(expectedDescriptor) }
        let expected = try ProcessExecutableIdentity(descriptor: expectedDescriptor)

        XCTAssertThrowsError(try ProcessRunner().runData(
            "/usr/bin/touch", [marker.path], in: nil, timeout: 5, maximumOutputBytes: 1_024,
            passingFileDescriptors: [expectedDescriptor], maximumPhysicalMemoryBytes: nil,
            expectedExecutable: expected
        )) { error in
            XCTAssertTrue("\(error)".contains("unauthenticated executable"), "\(error)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "The substituted image executed before its mapped vnode was authenticated")
    }

    func testArchiveWorkerDiesPromptlyWhenItsParentIsKilled() throws {
        let directory = try fixture()
        let archive = directory.appendingPathComponent("parent-death.tar")
        try tar([.file("Kit.xcframework/Info.plist", "value")]).write(to: archive)
        let executable = try builtSwiftPodsExecutable()
        let nonce = UUID().uuidString.lowercased()
        let script = #"""
        use strict;
        use warnings;
        use Fcntl qw(F_SETFD);
        use POSIX qw(WUNTRACED);
        $| = 1;
        my ($binary, $archive, $nonce) = @ARGV;
        open(my $archive_fh, '<', $archive) or die "archive";
        open(my $executable_fh, '<', $binary) or die "executable";
        pipe(my $live_reader, my $live_writer) or die "pipe";
        fcntl($archive_fh, F_SETFD, 0) or die "archive flags";
        fcntl($executable_fh, F_SETFD, 0) or die "executable flags";
        fcntl($live_reader, F_SETFD, 0) or die "liveness flags";
        my $worker = fork();
        defined($worker) or die "fork";
        if ($worker == 0) {
            close($live_writer);
            kill('STOP', $$);
            exec {$binary} $binary, '--swiftpods-internal-archive-worker-v1', '1', 'inspect',
                fileno($archive_fh), '-1', fileno($executable_fh), fileno($live_reader), $nonce;
            exit(127);
        }
        close($live_reader);
        waitpid($worker, WUNTRACED);
        print "$worker\n";
        sleep(60);
        """#
        let harness = Process()
        harness.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        harness.arguments = ["-e", script, executable.path, archive.path, nonce]
        let output = Pipe()
        harness.standardOutput = output
        harness.standardError = Pipe()
        try harness.run()
        var workerText = ""
        let lineDeadline = Date().addingTimeInterval(5)
        while !workerText.contains("\n"), Date() < lineDeadline {
            guard let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else { break }
            workerText += String(decoding: byte, as: UTF8.self)
        }
        guard let worker = pid_t(workerText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            _ = kill(harness.processIdentifier, SIGKILL)
            harness.waitUntilExit()
            return XCTFail("Parent harness did not report its stopped archive worker")
        }
        defer { if kill(worker, 0) == 0 { _ = kill(worker, SIGKILL) } }

        XCTAssertEqual(kill(harness.processIdentifier, SIGKILL), 0)
        harness.waitUntilExit()
        // A stopped process group may receive SIGHUP/SIGCONT automatically when its parent dies. Resume explicitly
        // only if it is still present; either route must reach the inherited-pipe EOF watchdog promptly.
        if kill(worker, 0) == 0 { XCTAssertEqual(kill(worker, SIGCONT), 0) }
        let exitDeadline = Date().addingTimeInterval(2)
        while kill(worker, 0) == 0, Date() < exitDeadline { usleep(10_000) }
        XCTAssertEqual(kill(worker, 0), -1, "Archive worker outlived its killed parent")
    }

    func testProcessRunnerTrackingTokenCannotBeOpenedByAnUnrelatedSameUIDProcess() throws {
        let directory = try fixture()
        let ready = directory.appendingPathComponent("attacker-ready")
        let opened = directory.appendingPathComponent("named-token-opened")
        let attacker = Process()
        attacker.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        attacker.arguments = [
            "-e",
            #"""
            use Fcntl qw(O_RDONLY);
            my ($ready, $opened) = @ARGV;
            my %seen;
            opendir(my $initial, '/tmp') or die "tmp";
            $seen{$_} = 1 for grep { /^swiftpods-process\./ } readdir($initial);
            closedir($initial);
            open(my $ready_fh, '>', $ready) or die "ready";
            close($ready_fh);
            my @held;
            while (1) {
                opendir(my $directory, '/tmp') or die "tmp";
                for my $name (grep { /^swiftpods-process\./ } readdir($directory)) {
                    next if $seen{$name}++;
                    if (sysopen(my $token, "/tmp/$name", O_RDONLY)) {
                        push @held, $token;
                        open(my $marker, '>', $opened) or die "marker";
                        close($marker);
                    }
                }
                closedir($directory);
                select(undef, undef, undef, 0.001);
            }
            """#,
            ready.path, opened.path,
        ]
        attacker.standardOutput = FileHandle.nullDevice
        attacker.standardError = FileHandle.nullDevice
        try attacker.run()
        defer {
            if attacker.isRunning { attacker.terminate() }
            attacker.waitUntilExit()
        }
        let readyDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < readyDeadline { usleep(1_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))

        XCTAssertThrowsError(try ProcessRunner(timeout: 0.2).run("/bin/sleep", ["5"], in: nil)) {
            XCTAssertTrue("\($0)".contains("timed out"), "\($0)")
        }
        usleep(50_000)
        XCTAssertTrue(attacker.isRunning, "An unrelated process was injected into command cleanup")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: opened.path),
            "The process-tracking capability must not have an openable pathname")
    }

    func testProcessRunnerDoesNotClassifyARawForkedSiblingAsADescendant() throws {
        let directory = try fixture()
        let commandStarted = directory.appendingPathComponent("supervised-command-started")
        let result = ProcessRunResult()
        let program = #"""
            open(my $marker, '>', $ARGV[0]) or die "marker";
            close($marker);
            select(undef, undef, undef, 0.75);
            """#
        DispatchQueue.global(qos: .userInitiated).async {
            result.run {
                _ = try ProcessRunner(timeout: 3).run(
                    "/usr/bin/perl", ["-e", program, commandStarted.path], in: nil)
            }
        }

        let startDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: commandStarted.path), Date() < startDeadline {
            usleep(1_000)
        }
        guard FileManager.default.fileExists(atPath: commandStarted.path) else {
            XCTAssertEqual(result.completion.wait(timeout: .now() + 4), .success)
            XCTFail("The supervised command did not start: \(result.failure ?? "no command result")")
            return
        }

        // Foundation deliberately marks `fork` unavailable. Resolve the libc entry point only for this regression,
        // which must exercise a no-exec raw fork rather than the safer production spawn path.
        typealias RawFork = @convention(c) () -> pid_t
        let processHandle = try XCTUnwrap(dlopen(nil, RTLD_LAZY))
        defer { dlclose(processHandle) }
        let forkSymbol = try XCTUnwrap(dlsym(processHandle, "fork"))
        let rawFork = unsafeBitCast(forkSymbol, to: RawFork.self)
        let sibling = rawFork()
        if sibling == 0 {
            // Deliberately do not exec: this reproduces inheritance of every parent descriptor which is not closed on
            // fork. Only async-signal-safe work is performed in this child of the multithreaded XCTest process.
            while true { _ = pause() }
        }
        guard sibling > 0 else {
            XCTAssertEqual(result.completion.wait(timeout: .now() + 4), .success)
            XCTFail("Cannot fork an unrelated sibling: \(String(cString: strerror(errno)))")
            return
        }
        var siblingWasReaped = false
        defer {
            if !siblingWasReaped {
                _ = kill(sibling, SIGKILL)
                var status = Int32()
                while waitpid(sibling, &status, 0) < 0, errno == EINTR {}
            }
        }

        XCTAssertEqual(result.completion.wait(timeout: .now() + 5), .success)
        XCTAssertNil(result.failure)
        var status = Int32()
        let observed = waitpid(sibling, &status, WNOHANG)
        if observed == sibling { siblingWasReaped = true }
        XCTAssertEqual(observed, 0, "An unrelated raw-fork sibling was terminated by command cleanup")
        if observed == 0 {
            XCTAssertEqual(kill(sibling, 0), 0, "The unrelated sibling must remain alive until test cleanup")
        }
    }

    func testProcessRunnerTerminatesTheTimedOutProcessGroup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftpods-process-group-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let childScript = directory.appendingPathComponent("child.sh")
        try """
            trap '/usr/bin/touch "$1"' TERM
            while :; do /bin/sleep 0.1; done
            """.write(to: childScript, atomically: true, encoding: .utf8)
        let signalMarker = directory.appendingPathComponent("descendant-received-term")
        let pidFile = directory.appendingPathComponent("descendant.pid")
        let parentScript = """
            trap 'exit 0' TERM
            /bin/sh "$1" "$2" &
            child=$!
            echo "$child" > "$3"
            wait "$child"
            """
        XCTAssertThrowsError(
            try ProcessRunner(timeout: 0.2).run(
                "/bin/sh", ["-c", parentScript, "swiftpods-test", childScript.path, signalMarker.path, pidFile.path], in: nil)
        ) { XCTAssertTrue("\($0)".contains("timed out"), "\($0)") }

        XCTAssertTrue(FileManager.default.fileExists(atPath: signalMarker.path))
        let child = try XCTUnwrap(
            pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let deadline = Date().addingTimeInterval(1)
        while kill(child, 0) == 0, Date() < deadline { usleep(20_000) }
        XCTAssertEqual(kill(child, 0), -1, "descendant \(child) survived the timeout")
        XCTAssertEqual(errno, ESRCH)
    }

    func testProcessRunnerTerminatesDescendantThatEscapesIntoNewSession() throws {
        let directory = try fixture()
        let pidFile = directory.appendingPathComponent("escaped.pid")
        let program = #"""
            use POSIX qw(setsid);
            my $pidfile = $ARGV[0];
            my $child = fork();
            die "fork failed" unless defined $child;
            if ($child == 0) {
                setsid() or die "setsid failed";
                open(STDOUT, '>', '/dev/null') or die "stdout";
                open(STDERR, '>', '/dev/null') or die "stderr";
                open(my $fh, '>', $pidfile) or die "pidfile";
                print $fh "$$\n";
                close($fh);
                $SIG{TERM} = 'IGNORE';
                while (1) { sleep 1; }
            }
            waitpid($child, 0);
            """#
        let started = Date()
        XCTAssertThrowsError(try ProcessRunner(timeout: 0.3).run(
            "/usr/bin/perl", ["-e", program, pidFile.path], in: nil
        )) { XCTAssertTrue("\($0)".contains("timed out"), "\($0)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3.5)

        let escaped = try XCTUnwrap(
            pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { if kill(escaped, 0) == 0 { _ = kill(escaped, SIGKILL) } }
        let deadline = Date().addingTimeInterval(2)
        while kill(escaped, 0) == 0, Date() < deadline { usleep(20_000) }
        XCTAssertEqual(kill(escaped, 0), -1, "setsid descendant \(escaped) survived the timeout")
        XCTAssertEqual(errno, ESRCH)
    }

    func testProcessRunnerTracksImmediateReparentedDoubleForkBeforeTimeout() throws {
        let directory = try fixture()
        let pidFile = directory.appendingPathComponent("double-fork.pid")
        let program = #"""
            use POSIX qw(setsid);
            my $pidfile = $ARGV[0];
            my $intermediate = fork();
            die "first fork failed" unless defined $intermediate;
            if ($intermediate == 0) {
                my $escaped = fork();
                die "second fork failed" unless defined $escaped;
                if ($escaped == 0) {
                    setsid() or die "setsid failed";
                    open(STDOUT, '>', '/dev/null') or die "stdout";
                    open(STDERR, '>', '/dev/null') or die "stderr";
                    open(my $fh, '>', $pidfile) or die "pidfile";
                    print $fh "$$\n";
                    close($fh);
                    $SIG{TERM} = 'IGNORE';
                    while (1) { sleep 1; }
                }
                exit 0;
            }
            waitpid($intermediate, 0);
            sleep 10;
            """#
        XCTAssertThrowsError(try ProcessRunner(timeout: 0.25).run(
            "/usr/bin/perl", ["-e", program, pidFile.path], in: nil
        )) { XCTAssertTrue("\($0)".contains("timed out"), "\($0)") }

        let escaped = try XCTUnwrap(
            pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { if kill(escaped, 0) == 0 { _ = kill(escaped, SIGKILL) } }
        let deadline = Date().addingTimeInterval(2)
        while kill(escaped, 0) == 0, Date() < deadline { usleep(20_000) }
        XCTAssertEqual(kill(escaped, 0), -1, "immediately reparented descendant \(escaped) survived")
        XCTAssertEqual(errno, ESRCH)
    }

    func testProcessRunnerCleansEscapedDescendantAfterNormalLeaderExit() throws {
        let directory = try fixture()
        let pidFile = directory.appendingPathComponent("normal-exit-descendant.pid")
        let program = #"""
            use POSIX qw(setsid);
            my $pidfile = $ARGV[0];
            my $intermediate = fork();
            die "first fork failed" unless defined $intermediate;
            if ($intermediate == 0) {
                my $escaped = fork();
                die "second fork failed" unless defined $escaped;
                if ($escaped == 0) {
                    setsid() or die "setsid failed";
                    open(STDOUT, '>', '/dev/null') or die "stdout";
                    open(STDERR, '>', '/dev/null') or die "stderr";
                    open(my $fh, '>', $pidfile) or die "pidfile";
                    print $fh "$$\n";
                    close($fh);
                    $SIG{TERM} = sub { exit 0; };
                    while (1) { sleep 1; }
                }
                while (!-e $pidfile) { select(undef, undef, undef, 0.001); }
                exit 0;
            }
            waitpid($intermediate, 0);
            exit 0;
            """#
        XCTAssertEqual(try ProcessRunner(timeout: 2).run(
            "/usr/bin/perl", ["-e", program, pidFile.path], in: nil
        ), "")

        let escaped = try XCTUnwrap(
            pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { if kill(escaped, 0) == 0 { _ = kill(escaped, SIGKILL) } }
        let deadline = Date().addingTimeInterval(2)
        while kill(escaped, 0) == 0, Date() < deadline { usleep(20_000) }
        XCTAssertEqual(kill(escaped, 0), -1, "normal-exit descendant \(escaped) survived")
        XCTAssertEqual(errno, ESRCH)
    }

    func testProcessRunnerDoesNotTurnObservedNearDeadlineExitIntoTimeout() throws {
        let directory = try fixture()
        let pidFile = directory.appendingPathComponent("near-deadline-descendant.pid")
        let program = #"""
            use POSIX qw(setsid);
            my $pidfile = $ARGV[0];
            my $child = fork();
            die "fork failed" unless defined $child;
            if ($child == 0) {
                setsid() or die "setsid failed";
                open(my $fh, '>', $pidfile) or die "pidfile";
                print $fh "$$\n";
                close($fh);
                $SIG{TERM} = 'IGNORE';
                while (1) { sleep 1; }
            }
            while (!-e $pidfile) { select(undef, undef, undef, 0.001); }
            select(undef, undef, undef, 0.18);
            exit 0;
            """#
        let started = Date()
        XCTAssertEqual(try ProcessRunner(timeout: 0.25).run(
            "/usr/bin/perl", ["-e", program, pidFile.path], in: nil
        ), "")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)

        let escaped = try XCTUnwrap(
            pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { if kill(escaped, 0) == 0 { _ = kill(escaped, SIGKILL) } }
        let deadline = Date().addingTimeInterval(2)
        while kill(escaped, 0) == 0, Date() < deadline { usleep(20_000) }
        XCTAssertEqual(kill(escaped, 0), -1, "near-deadline descendant \(escaped) survived")
        XCTAssertEqual(errno, ESRCH)
    }

    func testProcessRunnerSanitizesExternalCommandDiagnosticsButKeepsRawOutput() throws {
        let script = #"/usr/bin/printf '\033[31mred\033[0m\rrewritten\033]52;c;SECRET\007\n::error title=Injected::payload\n' >&2; exit 7"#
        XCTAssertThrowsError(try ProcessRunner().runData("/bin/sh", ["-c", script], in: nil)) { error in
            let description = "\(error)"
            XCTAssertTrue(description.contains("redrewritten"), description)
            XCTAssertTrue(description.contains("\n  | ::error title=Injected::payload"), description)
            XCTAssertFalse(description.contains("\n::"), description)
            XCTAssertFalse(description.contains("SECRET"), description)
            XCTAssertFalse(description.contains("\u{1b}"), description)
            XCTAssertFalse(description.contains("\r"), description)
            XCTAssertFalse(description.contains("\u{7}"), description)
            let failure = (error as? SwiftPodsError)?.commandFailure
            XCTAssertTrue(failure?.output.contains(0x1b) == true)
            XCTAssertEqual(failure?.reason, .exitStatus(7))
        }

        let poisonedArgument = "\u{1b}]52;c;ARGUMENT_SECRET\u{7}argument"
        XCTAssertThrowsError(try ProcessRunner().run("/usr/bin/false", [poisonedArgument], in: nil)) { error in
            XCTAssertFalse("\(error)".contains("ARGUMENT_SECRET"), "\(error)")
        }
        let poisonedExecutable = "/tmp/swiftpods-\u{1b}]52;c;EXECUTABLE_SECRET\u{7}missing"
        XCTAssertThrowsError(try ProcessRunner().run(poisonedExecutable, [], in: nil)) { error in
            XCTAssertFalse("\(error)".contains("EXECUTABLE_SECRET"), "\(error)")
        }

        let workflowArgument = "inspect\n::warning title=Argument injection::payload"
        XCTAssertThrowsError(try ProcessRunner().run("/usr/bin/false", [workflowArgument], in: nil)) { error in
            XCTAssertFalse("\(error)".contains("\n::"), "\(error)")
            XCTAssertTrue("\(error)".contains("inspect ::warning title=Argument injection::payload"), "\(error)")
        }
        let workflowExecutable = "/tmp/swiftpods-missing\n::notice title=Executable injection::payload"
        XCTAssertThrowsError(try ProcessRunner().run(workflowExecutable, [], in: nil)) { error in
            XCTAssertFalse("\(error)".contains("\n::"), "\(error)")
        }
    }

    func testProcessRunnerPreservesRawOutputAndBoundsIt() throws {
        XCTAssertEqual(try ProcessRunner().runData("/usr/bin/printf", ["\\377"], in: nil), Data([0xFF]))
        XCTAssertThrowsError(try ProcessRunner(maximumOutputBytes: 4).runData(
            "/usr/bin/printf", ["12345"], in: nil
        )) { XCTAssertTrue("\($0)".contains("larger than 4 bytes"), "\($0)") }
        XCTAssertThrowsError(try ProcessRunner().runData(
            "/usr/bin/printf", ["12345"], in: nil, timeout: 1, maximumOutputBytes: 4
        )) {
            XCTAssertTrue("\($0)".contains("larger than 4 bytes"), "\($0)")
            XCTAssertEqual(($0 as? SwiftPodsError)?.commandFailure?.reason, .outputLimit)
            XCTAssertEqual(($0 as? SwiftPodsError)?.commandFailure?.output, Data("1234".utf8))
        }
    }

    func testProcessRunnerDrainsBufferedOutputAfterLeaderExit() throws {
        let unit = Data("0123456789abcdef".utf8)
        var expected = Data()
        expected.reserveCapacity(unit.count * 131_072)
        for _ in 0..<131_072 { expected.append(unit) }

        for iteration in 0..<3 {
            let output = try ProcessRunner(maximumOutputBytes: expected.count + 1).runData(
                "/usr/bin/perl", ["-e", #"print "0123456789abcdef" x 131072"#], in: nil)
            XCTAssertEqual(output.count, expected.count, "iteration \(iteration)")
            XCTAssertEqual(output, expected, "iteration \(iteration)")
        }
    }

    func testLegacyCommandRunnerCannotSilentlyDiscardProductionBounds() {
        struct LegacyRunner: CommandRunner {
            func run(_ executable: String, _ arguments: [String], in directory: URL?) throws -> String { "legacy" }
        }
        let runner = LegacyRunner()
        XCTAssertThrowsError(try runner.run("/usr/bin/true", [], in: nil, timeout: 1)) {
            XCTAssertTrue("\($0)".contains("does not implement bounded execution"), "\($0)")
        }
        XCTAssertThrowsError(try runner.runData(
            "/usr/bin/true", [], in: nil, timeout: 1, maximumOutputBytes: 1,
            passingFileDescriptors: []
        )) { XCTAssertTrue("\($0)".contains("bounded streaming output"), "\($0)") }
    }

    func testProcessRunnerInheritsOnlyExplicitFileDescriptors() throws {
        let directory = try fixture()
        let first = directory.appendingPathComponent("selected")
        let second = directory.appendingPathComponent("unselected")
        try Data("selected".utf8).write(to: first)
        try Data("unselected".utf8).write(to: second)
        let firstBase = first.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        let secondBase = second.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        XCTAssertGreaterThanOrEqual(firstBase, 0)
        XCTAssertGreaterThanOrEqual(secondBase, 0)
        guard firstBase >= 0, secondBase >= 0 else { return }
        defer { close(firstBase); close(secondBase) }
        let selected = fcntl(firstBase, F_DUPFD_CLOEXEC, 200)
        let unselected = fcntl(secondBase, F_DUPFD_CLOEXEC, 220)
        XCTAssertGreaterThanOrEqual(selected, 200)
        XCTAssertGreaterThanOrEqual(unselected, 220)
        guard selected >= 0, unselected >= 0 else { return }
        defer { close(selected); close(unselected) }

        let script = "test -f \"/dev/fd/$1\" && printf selected; test ! -e \"/dev/fd/$2\" && printf ' closed'"
        let output = try ProcessRunner().runData(
            "/bin/sh", ["-c", script, "swiftpods-fd-test", String(selected), String(unselected)], in: nil,
            timeout: 5, maximumOutputBytes: 64, passingFileDescriptors: [selected])
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "selected closed")
    }

    func testCacheRootSymlinkNeverNormalizesAnExistingTargetTree() throws {
        let directory = try fixture()
        let archive = directory.appendingPathComponent("Remote.tar")
        try tar([.file("Kit.xcframework/Info.plist", "plist")]).write(to: archive)
        let digest = try BinaryStore.sha256(of: archive)
        try "target 'App' do\n  binary 'Kit', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]

        let target = directory.appendingPathComponent("real-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        XCTAssertEqual(target.path.withCString { chmod($0, 0o700) }, 0)
        let sentinel = target.appendingPathComponent("sentinel")
        try Data("do not chmod".utf8).write(to: sentinel)
        XCTAssertEqual(sentinel.path.withCString { chmod($0, 0o666) }, 0)
        let link = directory.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try BinaryStore(cache: link, runner: ProcessRunner(), offline: true)
            .contents(binary, podfileDirectory: directory)) {
            XCTAssertTrue("\($0)".contains("not cached"), "\($0)")
        }
        XCTAssertEqual(try SecureFileTree.statusNoFollow(sentinel).st_mode & 0o777, 0o666)
    }

    func testBinaryCacheRejectsARebindAfterDownloadWithoutTouchingTheReplacement() throws {
        let directory = try fixture()
        let archive = try tar([.file("Kit.xcframework/Info.plist", "plist")])
        let digest = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        let url = URL(string: "https://example.com/Kit.tar")!
        try "target 'App' do\n  binary 'Kit', url: '\(url.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        let movedCache = directory.appendingPathComponent("moved-cache", isDirectory: true)
        let replacement = directory.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
        let sentinel = replacement.appendingPathComponent("sentinel")
        try Data("unchanged".utf8).write(to: sentinel)
        let downloader = CacheRebindingDownloadClient(
            archive: archive, cache: cache, movedCache: movedCache, replacement: replacement)

        XCTAssertThrowsError(try BinaryStore(
            cache: cache, runner: ProcessRunner(), offline: false, downloader: downloader,
            minimumFreeSpaceReserveBytes: 0
        ).contents(binary, podfileDirectory: directory)) { error in
            XCTAssertTrue("\(error)".contains("cache root changed"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("unchanged".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: replacement.path), ["sentinel"])
    }

    func testBinaryCacheRejectsDownloadStagingRenameAndRecreateABA() throws {
        let directory = try fixture()
        let archive = try tar([.file("Kit.xcframework/Info.plist", "plist")])
        let digest = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        let url = URL(string: "https://example.com/Kit.tar")!
        try "target 'App' do\n  binary 'Kit', url: '\(url.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        let downloader = StagingRebindingDownloadClient(archive: archive)

        XCTAssertThrowsError(try BinaryStore(
            cache: cache, runner: ProcessRunner(), offline: false, downloader: downloader,
            minimumFreeSpaceReserveBytes: 0
        ).contents(binary, podfileDirectory: directory)) { error in
            XCTAssertTrue("\(error)".contains("staging directory changed"), "\(error)")
        }
        guard let replacement = downloader.replacement else {
            return XCTFail("Downloader did not create its replacement staging path")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.path))
        XCTAssertEqual(try Data(contentsOf: replacement.appendingPathComponent("archive")), archive)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: BinaryStore.versionedCacheRoot(for: cache).appendingPathComponent(digest).path))
    }

    func testBinaryCacheRejectsAWorldWritableNonStickyAncestor() throws {
        let directory = try fixture()
        let archive = directory.appendingPathComponent("Remote.tar")
        try tar([.file("Kit.xcframework/Info.plist", "plist")]).write(to: archive)
        let digest = try BinaryStore.sha256(of: archive)
        try "target 'App' do\n  binary 'Kit', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]
        let unsafeParent = directory.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: unsafeParent, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(unsafeParent.path, 0o777), 0)

        XCTAssertThrowsError(try BinaryStore(
            cache: unsafeParent.appendingPathComponent("cache"), runner: ProcessRunner(), offline: true
        ).contents(binary, podfileDirectory: directory)) { error in
            XCTAssertTrue("\(error)".contains("writable non-sticky"), "\(error)")
        }
    }

    func testBinaryCacheRejectsAnUnsafeLexicalAncestorBeforeFollowingItsSymlink() throws {
        let directory = try fixture()
        let archive = directory.appendingPathComponent("Remote.tar")
        try tar([.file("Kit.xcframework/Info.plist", "plist")]).write(to: archive)
        let digest = try BinaryStore.sha256(of: archive)
        try "target 'App' do\n  binary 'Kit', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]

        let trusted = directory.appendingPathComponent("trusted-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: trusted, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(trusted.path, 0o700), 0)
        let sentinel = trusted.appendingPathComponent("sentinel")
        try Data("unchanged".utf8).write(to: sentinel)
        let unsafeParent = directory.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: unsafeParent, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(unsafeParent.path, 0o777), 0)
        let configured = unsafeParent.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: configured, withDestinationURL: trusted)

        XCTAssertThrowsError(try BinaryStore(
            cache: configured, runner: ProcessRunner(), offline: true
        ).contents(binary, podfileDirectory: directory)) { error in
            XCTAssertTrue("\(error)".contains("writable non-sticky"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("unchanged".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trusted.path), ["sentinel"])
    }

    func testBinaryCacheValidatesEverySymlinkHopBeforeUsingItsCanonicalTarget() throws {
        let directory = try fixture()
        let archive = directory.appendingPathComponent("Remote.tar")
        try tar([.file("Kit.xcframework/Info.plist", "plist")]).write(to: archive)
        let digest = try BinaryStore.sha256(of: archive)
        try "target 'App' do\n  binary 'Kit', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]

        let trusted = directory.appendingPathComponent("trusted-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: trusted, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(trusted.path, 0o700), 0)
        let sentinel = trusted.appendingPathComponent("sentinel")
        try Data("unchanged".utf8).write(to: sentinel)
        let unsafeParent = directory.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: unsafeParent, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(unsafeParent.path, 0o777), 0)
        let secondLink = unsafeParent.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: secondLink, withDestinationURL: trusted)
        let firstLink = directory.appendingPathComponent("first", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: firstLink, withDestinationURL: secondLink)

        XCTAssertThrowsError(try BinaryStore(
            cache: firstLink, runner: ProcessRunner(), offline: true
        ).contents(binary, podfileDirectory: directory)) { error in
            XCTAssertTrue("\(error)".contains("writable non-sticky"), "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("unchanged".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trusted.path), ["sentinel"])
    }

    func testBinaryCacheKeepsPrivateVarAsALexicalCanonicalPath() throws {
        let directory = try fixture()
        guard directory.path.hasPrefix("/var/") else {
            throw XCTSkip("This Darwin alias regression requires a /var temporary directory")
        }
        let archive = directory.appendingPathComponent("Remote.tar")
        try tar([.file("Kit.xcframework/Info.plist", "plist")]).write(to: archive)
        let digest = try BinaryStore.sha256(of: archive)
        try "target 'App' do\n  binary 'Kit', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]
        let privateCache = URL(
            fileURLWithPath: "/private" + directory.path + "/cache", isDirectory: true)

        XCTAssertThrowsError(try BinaryStore(
            cache: privateCache, runner: ProcessRunner(), offline: true
        ).contents(binary, podfileDirectory: directory)) { error in
            XCTAssertTrue("\(error)".contains("not cached"), "\(error)")
        }
    }

    func testBinaryCacheAllowsAStandardDenyOnlyAncestorACL() throws {
        let directory = try fixture()
        let archive = directory.appendingPathComponent("Remote.tar")
        try tar([.file("Kit.xcframework/Info.plist", "plist")]).write(to: archive)
        let digest = try BinaryStore.sha256(of: archive)
        try "target 'App' do\n  binary 'Kit', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]
        let ancestor = directory.appendingPathComponent("protected", isDirectory: true)
        try FileManager.default.createDirectory(at: ancestor, withIntermediateDirectories: false)
        _ = try ProcessRunner().run(
            "/bin/chmod", ["+a", "everyone deny delete", ancestor.path], in: nil)
        defer { _ = try? ProcessRunner().run("/bin/chmod", ["-N", ancestor.path], in: nil) }

        XCTAssertThrowsError(try BinaryStore(
            cache: ancestor.appendingPathComponent("cache"), runner: ProcessRunner(), offline: true
        ).contents(binary, podfileDirectory: directory)) { error in
            XCTAssertTrue("\(error)".contains("not cached"), "\(error)")
        }
    }

    func testBinaryCacheQuotaEvictsOldCompleteEntriesAndIsInspectable() throws {
        let directory = try fixture()
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        let storage = BinaryStore.versionedCacheRoot(for: cache)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        XCTAssertEqual(cache.path.withCString { chmod($0, 0o700) }, 0)
        XCTAssertEqual(storage.path.withCString { chmod($0, 0o700) }, 0)
        let oldKey = String(repeating: "1", count: 64)
        let newKey = String(repeating: "2", count: 64)
        for (key, age) in [(oldKey, -200.0), (newKey, -100.0)] {
            let entry = storage.appendingPathComponent(key, isDirectory: true)
            try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: false)
            try Data(repeating: 0x41, count: 24 * 1024).write(to: entry.appendingPathComponent("payload"))
            try Data("complete".utf8).write(to: entry.appendingPathComponent(".complete"))
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(age)], ofItemAtPath: entry.path)
        }
        XCTAssertGreaterThan(try BinaryStore.cacheUsage(at: storage).bytes, 40 * 1024)

        let archive = directory.appendingPathComponent("Remote.tar")
        try tar([.file("Kit.xcframework/Info.plist", "plist")]).write(to: archive)
        let digest = try BinaryStore.sha256(of: archive)
        try "target 'App' do\n  binary 'Kit', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]
        _ = try BinaryStore(
            cache: cache, runner: ProcessRunner(), offline: false, maximumCacheBytes: 40 * 1024,
            minimumFreeSpaceReserveBytes: 0
        ).contents(binary, podfileDirectory: directory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.appendingPathComponent(oldKey).path))
        XCTAssertLessThanOrEqual(try BinaryStore.cacheUsage(at: storage).bytes, 40 * 1024)
    }

    func testBinaryCacheReapsOnlyValidatedCrashResidueAndLegacyLocks() throws {
        let directory = try fixture()
        let archive = directory.appendingPathComponent("Remote.tar")
        try tar([.file("Kit.xcframework/Info.plist", "plist")]).write(to: archive)
        let digest = try BinaryStore.sha256(of: archive)
        try "target 'App' do\n  binary 'Kit', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        let storage = BinaryStore.versionedCacheRoot(for: cache)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(cache.path, 0o700), 0)
        XCTAssertEqual(chmod(storage.path, 0o700), 0)

        let validResidue = storage.appendingPathComponent(".download-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: validResidue, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(validResidue.path, 0o700), 0)
        try Data("partial".utf8).write(to: validResidue.appendingPathComponent("archive"))
        let malformedResidue = storage.appendingPathComponent(".download-not-a-uuid", isDirectory: true)
        try FileManager.default.createDirectory(at: malformedResidue, withIntermediateDirectories: false)
        let victim = directory.appendingPathComponent("victim", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: victim.appendingPathComponent("sentinel"))
        let linkedResidue = storage.appendingPathComponent(".refresh-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedResidue, withDestinationURL: victim)
        let legacyLock = storage.appendingPathComponent(".lock-" + String(repeating: "a", count: 64))
        try Data().write(to: legacyLock)
        XCTAssertEqual(chmod(legacyLock.path, 0o600), 0)

        _ = try BinaryStore(
            cache: cache, runner: ProcessRunner(), offline: false, minimumFreeSpaceReserveBytes: 0
        ).contents(binary, podfileDirectory: directory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: validResidue.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformedResidue.path))
        XCTAssertTrue(SecureFileTree.isSymbolicLink(try SecureFileTree.statusNoFollow(linkedResidue)))
        XCTAssertEqual(try Data(contentsOf: victim.appendingPathComponent("sentinel")), Data("keep".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyLock.path))
        let locks = try FileManager.default.contentsOfDirectory(atPath: storage.path).filter { $0.hasPrefix(".lock-") }
        XCTAssertTrue(locks.contains(".lock-global"), "\(locks)")
        XCTAssertTrue(locks.contains(where: { $0.hasPrefix(".lock-bucket-") }), "\(locks)")
        XCTAssertFalse(locks.contains(where: { $0.utf8.count == ".lock-".utf8.count + 64 }), "\(locks)")
    }

    func testBinaryCacheUsesAVersionedNamespaceWithoutMutatingReleasedLayout() throws {
        let directory = try fixture()
        let archive = directory.appendingPathComponent("Remote.tar")
        try tar([.file("Kit.xcframework/Info.plist", "plist")]).write(to: archive)
        let digest = try BinaryStore.sha256(of: archive)
        try "target 'App' do\n  binary 'Kit', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(cache.path, 0o700), 0)

        let releasedStaging = cache.appendingPathComponent(
            ".download-00000000-0000-0000-0000-000000000000", isDirectory: true)
        try FileManager.default.createDirectory(at: releasedStaging, withIntermediateDirectories: false)
        let stagingSentinel = releasedStaging.appendingPathComponent("sentinel")
        try Data("old process".utf8).write(to: stagingSentinel)
        let releasedEntry = cache.appendingPathComponent(digest, isDirectory: true)
        try FileManager.default.createDirectory(at: releasedEntry, withIntermediateDirectories: false)
        let entrySentinel = releasedEntry.appendingPathComponent("sentinel")
        try Data("old cache".utf8).write(to: entrySentinel)

        _ = try BinaryStore(
            cache: cache, runner: ProcessRunner(), offline: false, minimumFreeSpaceReserveBytes: 0
        ).contents(binary, podfileDirectory: directory)

        XCTAssertEqual(try Data(contentsOf: stagingSentinel), Data("old process".utf8))
        XCTAssertEqual(try Data(contentsOf: entrySentinel), Data("old cache".utf8))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: BinaryStore.versionedCacheRoot(for: cache).appendingPathComponent(digest).path))
    }

    func testBinaryCacheDropsInvalidCurrentSHAEntryBeforeQuotaButPreservesAValidOne() throws {
        let directory = try fixture()
        let archive = directory.appendingPathComponent("Remote.tar")
        try tar([.file("Kit.xcframework/Info.plist", "plist")]).write(to: archive)
        let digest = try BinaryStore.sha256(of: archive)
        try "target 'App' do\n  binary 'Kit', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        let storage = BinaryStore.versionedCacheRoot(for: cache)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(cache.path, 0o700), 0)
        XCTAssertEqual(chmod(storage.path, 0o700), 0)

        let current = storage.appendingPathComponent(digest, isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
        try Data(repeating: 0x41, count: 128 * 1024).write(to: current.appendingPathComponent("poison"))
        try Data(repeating: 0x43, count: 2 * 1024 * 1024).write(to: current.appendingPathComponent("archive"))
        try Data("cache-v2\narchive \(digest)\ntree \(String(repeating: "0", count: 64))\n".utf8)
            .write(to: current.appendingPathComponent(".complete"))
        _ = try BinaryStore(
            cache: cache, runner: ProcessRunner(), offline: false, maximumCacheBytes: 1 * 1024 * 1024,
            minimumFreeSpaceReserveBytes: 0
        ).contents(binary, podfileDirectory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.appendingPathComponent("poison").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.appendingPathComponent(".complete").path))

        let oldKey = String(repeating: digest.first == "f" ? "e" : "f", count: 64)
        let old = storage.appendingPathComponent(oldKey, isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false)
        try Data(repeating: 0x42, count: 2 * 1024 * 1024).write(to: old.appendingPathComponent("payload"))
        try Data("complete".utf8).write(to: old.appendingPathComponent(".complete"))

        _ = try BinaryStore(
            cache: cache, runner: ProcessRunner(), offline: true, maximumCacheBytes: 1 * 1024 * 1024,
            minimumFreeSpaceReserveBytes: 0
        ).contents(binary, podfileDirectory: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path), "valid current SHA entry must be preserved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    func testBinaryCacheEntryQuotaEvictsOldCompleteEntryBelowByteQuota() throws {
        let directory = try fixture()
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        let storage = BinaryStore.versionedCacheRoot(for: cache)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        XCTAssertEqual(cache.path.withCString { chmod($0, 0o700) }, 0)
        XCTAssertEqual(storage.path.withCString { chmod($0, 0o700) }, 0)

        let oldKey = String(repeating: "1", count: 64)
        let oldEntry = storage.appendingPathComponent(oldKey, isDirectory: true)
        try FileManager.default.createDirectory(at: oldEntry, withIntermediateDirectories: false)
        for index in 0..<35 {
            try Data([UInt8(index)]).write(
                to: oldEntry.appendingPathComponent("object-\(index)"))
        }
        try Data("complete".utf8).write(to: oldEntry.appendingPathComponent(".complete"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-200)], ofItemAtPath: oldEntry.path)
        let initialUsage = try BinaryStore.cacheUsage(at: storage)
        XCTAssertEqual(initialUsage.entries, 37)
        XCTAssertLessThan(initialUsage.bytes, 1 * 1024 * 1024)

        let archive = directory.appendingPathComponent("Remote.tar")
        try tar([.file("Kit.xcframework/Info.plist", "plist")]).write(to: archive)
        let digest = try BinaryStore.sha256(of: archive)
        try "target 'App' do\n  binary 'Kit', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]

        _ = try BinaryStore(
            cache: cache, runner: ProcessRunner(), offline: false,
            maximumCacheBytes: 1 * 1024 * 1024 * 1024, maximumCacheEntries: 40,
            minimumFreeSpaceReserveBytes: 0
        ).contents(binary, podfileDirectory: directory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldEntry.path))
        let finalUsage = try BinaryStore.cacheUsage(at: storage)
        XCTAssertLessThanOrEqual(finalUsage.entries, 40)
        XCTAssertLessThan(finalUsage.bytes, 1 * 1024 * 1024)
    }

    func testBinaryCacheUsageRejectsAnExcessivelyDeepTree() throws {
        let directory = try fixture()
        let cache = directory.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
        var nested = cache
        for index in 0..<70 {
            nested.appendPathComponent("level-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        }

        XCTAssertThrowsError(try BinaryStore.cacheUsage(at: cache)) { error in
            XCTAssertTrue("\(error)".contains("directory-depth limit"), "\(error)")
        }
    }

    func testBinaryMaterializationFailsBeforeCopyWhenFreeSpaceReserveCannotBeMet() throws {
        let directory = try fixture()
        let archive = directory.appendingPathComponent("Remote.tar")
        try tar([.file("Kit.xcframework/Info.plist", "plist")]).write(to: archive)
        let digest = try BinaryStore.sha256(of: archive)
        try "target 'App' do\n  binary 'Kit', url: '\(archive.absoluteString)', sha256: '\(digest)'\nend\n"
            .write(to: directory.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let binary = try Installer(directory: directory).manifest().binaries[0]

        XCTAssertThrowsError(try BinaryStore(
            cache: directory.appendingPathComponent("cache"), runner: ProcessRunner(), offline: false,
            minimumFreeSpaceReserveBytes: Int64.max
        ).contents(binary, podfileDirectory: directory)) {
            XCTAssertTrue("\($0)".contains("free space"), "\($0)")
        }
    }

    func testProcessRunnerRemovesInheritedGitCommandInjection() {
        let environment = ProcessRunner.sanitizedEnvironment([
            "PATH": "/usr/bin", "GIT_SSH_COMMAND": "/tmp/command", "GIT_CONFIG_COUNT": "1",
            "GIT_ASKPASS": "/tmp/askpass", "SSH_ASKPASS": "/tmp/ssh-askpass", "SSH_AUTH_SOCK": "/tmp/agent",
            "DYLD_INSERT_LIBRARIES": "/tmp/injected.dylib", "DYLD_LIBRARY_PATH": "/tmp/dyld",
            "LD_PRELOAD": "/tmp/injected.so", "LD_LIBRARY_PATH": "/tmp/ld", "BASH_ENV": "/tmp/bash-env",
            "ENV": "/tmp/sh-env", "CDPATH": "/tmp/cdpath", "DEVELOPER_DIR": "/Applications/Xcode.app",
            "SHELLOPTS": "xtrace", "BASHOPTS": "extdebug", "BASH_XTRACEFD": "9",
            "BASH_FUNC_cd%%": "() { /tmp/injected; }",
            "PS4": "$(/tmp/injected)", "IFS": "/",
            "TAR_OPTIONS": "--absolute-names", "TAR_READER_OPTIONS": "dangerous",
            "GZIP": "--to-stdout", "XZ_OPT": "--threads=0",
            "CURL_CA_BUNDLE": "/tmp/attacker-ca.pem", "CURL_HOME": "/tmp/curl-home",
            "SSL_CERT_FILE": "/tmp/ssl-cert.pem", "SSL_CERT_DIR": "/tmp/ssl-certs",
            "SSLKEYLOGFILE": "/tmp/tls-secrets.log",
            "SDKROOT": "/tmp/SDK", "HTTPS_PROXY": "http://proxy.example:8080",
        ])
        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["SSH_AUTH_SOCK"], "/tmp/agent")
        XCTAssertEqual(environment["DEVELOPER_DIR"], "/Applications/Xcode.app")
        XCTAssertEqual(environment["SDKROOT"], "/tmp/SDK")
        XCTAssertEqual(environment["HTTPS_PROXY"], "http://proxy.example:8080")
        XCTAssertEqual(environment["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertNil(environment["GIT_SSH_COMMAND"])
        XCTAssertNil(environment["GIT_CONFIG_COUNT"])
        XCTAssertNil(environment["GIT_ASKPASS"])
        XCTAssertNil(environment["SSH_ASKPASS"])
        XCTAssertNil(environment["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(environment["DYLD_LIBRARY_PATH"])
        XCTAssertNil(environment["LD_PRELOAD"])
        XCTAssertNil(environment["LD_LIBRARY_PATH"])
        XCTAssertNil(environment["BASH_ENV"])
        XCTAssertNil(environment["ENV"])
        XCTAssertNil(environment["CDPATH"])
        XCTAssertNil(environment["SHELLOPTS"])
        XCTAssertNil(environment["BASHOPTS"])
        XCTAssertNil(environment["BASH_XTRACEFD"])
        XCTAssertNil(environment["BASH_FUNC_cd%%"])
        XCTAssertNil(environment["PS4"])
        XCTAssertNil(environment["IFS"])
        XCTAssertNil(environment["TAR_OPTIONS"])
        XCTAssertNil(environment["TAR_READER_OPTIONS"])
        XCTAssertNil(environment["GZIP"])
        XCTAssertNil(environment["XZ_OPT"])
        XCTAssertNil(environment["CURL_CA_BUNDLE"])
        XCTAssertNil(environment["CURL_HOME"])
        XCTAssertNil(environment["SSL_CERT_FILE"])
        XCTAssertNil(environment["SSL_CERT_DIR"])
        XCTAssertNil(environment["SSLKEYLOGFILE"])
        XCTAssertEqual(environment["SSH_ASKPASS_REQUIRE"], "never")
    }

    func testProcessRunnerUsesNativeWorkingDirectoryWithPoisonedShellFunctionRemoved() throws {
        let directory = try fixture()
        let key = "BASH_FUNC_cd%%"
        let previous = getenv(key).map { String(cString: $0) }
        XCTAssertEqual(setenv(key, "() { printf poisoned; }", 1), 0)
        defer {
            if let previous { _ = setenv(key, previous, 1) } else { _ = unsetenv(key) }
        }
        XCTAssertNil(ProcessRunner.sanitizedEnvironment([
            key: "() { printf poisoned; }",
        ])[key])
        let environment = try ProcessRunner().run("/usr/bin/env", [], in: directory)
        XCTAssertFalse(environment.contains(key + "="), environment)
        let output = try ProcessRunner().run("/bin/pwd", [], in: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(URL(fileURLWithPath: output).standardizedFileURL, directory.standardizedFileURL)
    }
}
