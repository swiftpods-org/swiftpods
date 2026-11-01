import CLibArchive
import CryptoKit
import Darwin
import Foundation
import SwiftPodsManifest

@_silgen_name("sandbox_init")
private func swiftpodsSandboxInit(
    _ profile: UnsafePointer<CChar>, _ flags: UInt64,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("sandbox_free_error")
private func swiftpodsSandboxFreeError(_ error: UnsafeMutablePointer<CChar>?)

struct BinaryDownloadFailure: Error {
    let transient: Bool
    let message: String

    init(_ message: String, transient: Bool = false) {
        self.message = message
        self.transient = transient
    }
}

/// Hidden single-binary worker surface. It is public only because the command-line executable is a separate SwiftPM
/// target; all request fields are revalidated by SwiftPodsKit and the operation has no ambient-path or network access.
public enum SwiftPodsArchiveWorker {
    public static let command = "--swiftpods-internal-archive-worker-v1"
    public static let parentProbeCommand = "--swiftpods-internal-archive-parent-probe-v1"

    public static func run(arguments: [String]) throws -> Data {
        try BinaryStore.archiveWorkerOutput(arguments: arguments)
    }

    public static func runParentProbe(arguments: [String]) throws -> Data {
        try BinaryStore.archiveParentProbeOutput(arguments: arguments)
    }
}

private struct BinaryResolvedAddress: Sendable {
    let family: Int32
    let bytes: [UInt8]
    let text: String
}

private struct BinaryNetworkEndpoint: Sendable {
    let url: URL
    let host: String
    let port: Int
    let addresses: [BinaryResolvedAddress]
}

private final class BinaryDNSResolution: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<[BinaryResolvedAddress], BinaryDownloadFailure>?

    func store(_ result: Result<[BinaryResolvedAddress], BinaryDownloadFailure>) {
        lock.withLock { value = result }
    }

    func load() -> Result<[BinaryResolvedAddress], BinaryDownloadFailure>? {
        lock.withLock { value }
    }
}

enum BinaryNetworkPolicy {
    /// `getaddrinfo(3)` has no cancellation API. A timed-out lookup therefore keeps its worker until libc returns;
    /// cap those workers process-wide so repeated hostile hostnames cannot create an unbounded thread backlog.
    private static let resolverSlots = DispatchSemaphore(value: 4)

    static func validate(_ url: URL, timeout: TimeInterval = 30) throws {
        _ = try endpoint(for: url, timeout: timeout)
    }

    /// Shared by binary downloads and catalog transports so all network resolution uses the same public-address policy,
    /// process-wide concurrency cap, and non-retryable timeout behavior.
    static func publicAddressStrings(
        host rawHost: String, port: Int, timeout: TimeInterval = 30
    ) throws -> [String] {
        let host = try validatedHost(rawHost, port: port)
        let addresses = try publicAddresses(host: host, port: port, timeout: timeout)
        var seen: Set<String> = []
        return addresses.compactMap { seen.insert($0.text).inserted ? $0.text : nil }
    }

    fileprivate static func endpoint(for url: URL, timeout: TimeInterval) throws -> BinaryNetworkEndpoint {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "https", let rawHost = components.host, !rawHost.isEmpty,
            components.user == nil, components.password == nil, components.fragment == nil
        else { throw BinaryDownloadFailure("Binary download URL is not a safe HTTPS URL") }

        let port = components.port ?? 443
        guard url.absoluteString.utf8.count <= 16 * 1024 else {
            throw BinaryDownloadFailure("Binary download URL has an unsafe host or port")
        }
        let host = try validatedHost(rawHost, port: port)
        let addresses = try publicAddresses(host: host, port: port, timeout: timeout)
        return BinaryNetworkEndpoint(
            url: url, host: host, port: port, addresses: addresses)
    }

    private static func validatedHost(_ rawHost: String, port: Int) throws -> String {
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
        guard host.utf8.count <= 253, !host.isEmpty, !host.hasPrefix("."), !host.hasSuffix("."),
            !host.contains(".."), host.unicodeScalars.allSatisfy(allowed.contains),
            (1...65_535).contains(port)
        else { throw BinaryDownloadFailure("Binary download URL has an unsafe host or port") }
        let lower = host.lowercased()
        guard lower != "localhost", !lower.hasSuffix(".localhost"), !lower.hasSuffix(".local") else {
            throw BinaryDownloadFailure("Binary download host is local")
        }
        return host
    }

    private static func publicAddresses(
        host: String, port: Int, timeout: TimeInterval
    ) throws -> [BinaryResolvedAddress] {
        guard timeout.isFinite, timeout > 0 else {
            throw BinaryDownloadFailure("Binary download DNS lookup timed out")
        }
        let addresses = try resolve(host, service: String(port), timeout: timeout)
        var found = false
        for address in addresses {
            switch address.family {
            case AF_INET:
                guard address.bytes.count == 4, isPublicIPv4(address.bytes) else {
                    throw BinaryDownloadFailure("Binary download host resolves to a non-public address")
                }
                found = true
            case AF_INET6:
                guard address.bytes.count == 16, isPublicIPv6(address.bytes) else {
                    throw BinaryDownloadFailure("Binary download host resolves to a non-public address")
                }
                found = true
            default:
                continue
            }
        }
        guard addresses.count <= 64 else {
            throw BinaryDownloadFailure("Binary download host returned too many addresses", transient: true)
        }
        guard found else { throw BinaryDownloadFailure("Binary download host has no public IP address", transient: true) }
        return addresses
    }

    private static func resolve(_ host: String, service: String, timeout: TimeInterval) throws -> [BinaryResolvedAddress] {
        let started = DispatchTime.now().uptimeNanoseconds
        let nanoseconds = timeout * 1_000_000_000
        guard nanoseconds < TimeInterval(UInt64.max) else {
            throw BinaryDownloadFailure("Binary download DNS timeout is too large")
        }
        let duration = UInt64(nanoseconds.rounded(.up))
        let deadlineResult = started.addingReportingOverflow(duration)
        guard !deadlineResult.overflow,
            resolverSlots.wait(timeout: .now() + timeout) == .success
        else {
            // A lookup that timed out may still be occupying every resolver slot. Do not classify this as retryable:
            // an immediate retry would only enqueue another non-cancellable lookup for the same operation.
            throw BinaryDownloadFailure("Binary download DNS lookup timed out")
        }
        let deadline = deadlineResult.partialValue
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else {
            resolverSlots.signal()
            throw BinaryDownloadFailure("Binary download DNS lookup timed out")
        }
        let box = BinaryDNSResolution()
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            defer { resolverSlots.signal() }
            var hints = addrinfo(
                ai_flags: AI_ADDRCONFIG,
                ai_family: AF_UNSPEC,
                ai_socktype: SOCK_STREAM,
                ai_protocol: IPPROTO_TCP,
                ai_addrlen: 0,
                ai_canonname: nil,
                ai_addr: nil,
                ai_next: nil)
            var result: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, service, &hints, &result)
            guard status == 0, let first = result else {
                box.store(.failure(BinaryDownloadFailure(
                    "Binary download host cannot be resolved", transient: true)))
                completed.signal()
                return
            }
            defer { freeaddrinfo(first) }
            var addresses: [BinaryResolvedAddress] = []
            var current: UnsafeMutablePointer<addrinfo>? = first
            while let address = current {
                defer { current = address.pointee.ai_next }
                guard let socket = address.pointee.ai_addr else { continue }
                switch Int32(address.pointee.ai_family) {
                case AF_INET:
                    let value = socket.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    guard getnameinfo(
                        socket, address.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST
                    ) == 0 else { continue }
                    addresses.append(BinaryResolvedAddress(
                        family: AF_INET, bytes: withUnsafeBytes(of: value) { Array($0) },
                        text: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)))
                case AF_INET6:
                    let value = socket.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    guard getnameinfo(
                        socket, address.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST
                    ) == 0 else { continue }
                    addresses.append(BinaryResolvedAddress(
                        family: AF_INET6, bytes: withUnsafeBytes(of: value) { Array($0) },
                        text: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)))
                default:
                    continue
                }
                guard addresses.count <= 64 else {
                    // `getaddrinfo` owns its complete libc result, but never mirror an attacker-inflated answer list into
                    // unbounded Swift allocations or retry it as though it were a transient transport failure.
                    box.store(.failure(BinaryDownloadFailure(
                        "Binary download host returned too many addresses")))
                    completed.signal()
                    return
                }
            }
            box.store(.success(addresses))
            completed.signal()
        }
        let remaining = TimeInterval(deadline - now) / 1_000_000_000
        guard completed.wait(timeout: .now() + remaining) == .success, let result = box.load() else {
            throw BinaryDownloadFailure("Binary download DNS lookup timed out")
        }
        return try result.get()
    }

    private static func isPublicIPv4(_ bytes: [UInt8]) -> Bool {
        let a = bytes[0]
        let b = bytes[1]
        if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
        if a == 100 && (64...127).contains(b) { return false }
        if a == 169 && b == 254 { return false }
        if a == 172 && (16...31).contains(b) { return false }
        if a == 192 && (b == 0 || b == 168) { return false }
        if a == 192 && b == 88 && bytes[2] == 99 { return false }
        if a == 198 && (b == 18 || b == 19) { return false }
        if a == 192 && b == 2 { return false }
        if a == 198 && b == 51 && bytes[2] == 100 { return false }
        if a == 203 && b == 0 && bytes[2] == 113 { return false }
        return true
    }

    private static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return isPublicIPv4(Array(bytes[12..<16]))
        }
        // Currently allocated global-unicast space. This deliberately excludes loopback, unspecified, ULA,
        // link-local, multicast, documentation and IPv4-translation prefixes.
        guard bytes[0] >= 0x20, bytes[0] <= 0x3F else { return false }
        if bytes[0] == 0x20, bytes[1] == 0x01 {
            if bytes[2] == 0x00, bytes[3] == 0x00 { return false } // Teredo
            if bytes[2] == 0x00, bytes[3] == 0x02 { return false } // benchmark
            if bytes[2] == 0x00, (bytes[3] & 0xF0 == 0x10 || bytes[3] & 0xF0 == 0x20) { return false } // ORCHID
            if bytes[2] == 0x0D, bytes[3] == 0xB8 { return false } // documentation
        }
        if bytes[0] == 0x20, bytes[1] == 0x02 { return false } // 6to4 can embed a private IPv4 destination
        if bytes[0] == 0x3F, bytes[1] & 0xF0 == 0xF0 { return false } // documentation
        return true
    }
}

struct BinaryDownloadResult: Sendable, Equatable {
    let storedBytes: Int64
    let transferredBytes: Int64
}

protocol BinaryDownloadClient: Sendable {
    func download(
        from url: URL, to destination: URL, maximumBytes: Int64, timeout: TimeInterval
    ) throws -> BinaryDownloadResult
}

/// Uses curl only as a TLS/HTTP engine. The URL and pinned resolution live in an unlinked descriptor-backed config,
/// while argv contains only constant options and /dev/fd numbers. Each hop is resolved, checked and pinned separately;
/// curl therefore cannot re-resolve a validated hostname to a private address at connection time.
private struct PinnedCurlBinaryDownloadClient: BinaryDownloadClient {
    private static let maximumHeaderBytes = 1 * 1024 * 1024
    let runner: CommandRunner

    func download(
        from url: URL, to destination: URL, maximumBytes: Int64, timeout: TimeInterval
    ) throws -> BinaryDownloadResult {
        guard timeout.isFinite, timeout > 0, maximumBytes > 0 else {
            throw BinaryDownloadFailure("Binary download has invalid limits")
        }
        let output = destination.path.withCString {
            open($0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard output >= 0, fchmod(output, 0o600) == 0 else {
            if output >= 0 { close(output) }
            throw BinaryDownloadFailure("Cannot create binary archive download")
        }
        defer { close(output) }

        let started = DispatchTime.now().uptimeNanoseconds
        let duration = UInt64(timeout * 1_000_000_000)
        let deadline = started.addingReportingOverflow(duration).partialValue
        var current = url
        var redirects = 0
        var transferred: Int64 = 0

        while true {
            guard let remainingTime = Self.remainingTime(before: deadline), maximumBytes > transferred else {
                throw BinaryDownloadFailure("Binary download timed out or exceeded its budget", transient: true)
            }
            let endpoint = try BinaryNetworkPolicy.endpoint(for: current, timeout: min(30, remainingTime))
            var lastTransportFailure: BinaryDownloadFailure?
            var response: (status: Int, location: String?, encoding: String?, storedBytes: Int64, transferredBytes: Int64)?

            // Bound address failover as well as redirects; the aggregate byte allowance covers every attempted address.
            for address in endpoint.addresses.prefix(4) {
                guard let hopTime = Self.remainingTime(before: deadline), maximumBytes > transferred else {
                    throw BinaryDownloadFailure("Binary download timed out or exceeded its budget", transient: true)
                }
                let allowance = maximumBytes - transferred
                var attemptedHeaderBytes: Int64 = 0
                do {
                    let parsed: (
                        status: Int, location: String?, encoding: String?, storedBytes: Int64, transferredBytes: Int64
                    ) = try {
                        let headerAllowance = min(Int64(Self.maximumHeaderBytes), allowance)
                        let bodyAllowance = allowance - headerAllowance
                        guard bodyAllowance > 0 else {
                            throw BinaryDownloadFailure("Binary download has exhausted its response-header budget")
                        }
                        guard ftruncate(output, 0) == 0, lseek(output, 0, SEEK_SET) == 0 else {
                            throw BinaryDownloadFailure("Cannot reset binary archive download")
                        }
                        let config = try configuration(
                            endpoint: endpoint, address: address, output: output,
                            maximumBytes: bodyAllowance, timeout: hopTime)
                        let configDescriptor = try anonymousDescriptor(
                            in: destination.deletingLastPathComponent(), prefix: ".curl-config-")
                        defer { close(configDescriptor) }
                        try write(config, to: configDescriptor)
                        guard lseek(configDescriptor, 0, SEEK_SET) == 0 else {
                            throw BinaryDownloadFailure("Cannot prepare binary download configuration")
                        }
                        // macOS 13 ships a curl predating 8.4, where --max-filesize did not bound unknown-length
                        // responses. RLIMIT_FSIZE is an independent kernel-enforced cap on the descriptor curl writes.
                        // Darwin's `/bin/sh` expresses `ulimit -f` in 1 KiB units. Round up so a valid final
                        // partial KiB is not rejected; the descriptor-size check below enforces the exact byte cap.
                        let fileSizeBlocks = bodyAllowance / 1_024 + (bodyAllowance % 1_024 == 0 ? 0 : 1)
                        let script = "ulimit -f \"$1\" || exit 125; "
                            + "exec /usr/bin/curl --disable --silent --proto '=https' --noproxy '*' --config \"$2\""
                        // curl writes response headers to stdout. ProcessRunner consumes that pipe incrementally and
                        // terminates curl at the limit, so a peer cannot fill a temporary header file before validation.
                        let headerData = try runner.runData(
                            "/bin/sh",
                            ["-c", script, "swiftpods-curl", String(fileSizeBlocks), "/dev/fd/\(configDescriptor)"],
                            in: nil, timeout: hopTime, maximumOutputBytes: Int(headerAllowance),
                            passingFileDescriptors: [output, configDescriptor])
                        attemptedHeaderBytes = Int64(headerData.count)
                        let bodyBytes = try descriptorSize(output)
                        guard bodyBytes <= bodyAllowance else {
                            throw BinaryDownloadFailure("Binary archive exceeds its download limit")
                        }
                        let headerBytes = Int64(headerData.count)
                        guard headerBytes <= headerAllowance, bodyBytes <= allowance - headerBytes else {
                            throw BinaryDownloadFailure("Binary response exceeds its transfer budget")
                        }
                        let headers = try parseHeaders(headerData)
                        return (
                            headers.status, headers.location, headers.encoding, bodyBytes,
                            bodyBytes + headerBytes)
                    }()
                    transferred += parsed.transferredBytes
                    response = parsed
                    break
                } catch {
                    let partial = try descriptorSize(output)
                    guard partial <= allowance else {
                        throw BinaryDownloadFailure("Binary archive exceeds its download limit")
                    }
                    let captured = Int64((error as? SwiftPodsError)?.commandFailure?.output.count ?? 0)
                    let headers = max(attemptedHeaderBytes, captured)
                    transferred += min(allowance - partial, headers) + partial
                    let failure = BinaryDownloadFailure(
                        "Binary download transport failed", transient: Self.isTransientCurlFailure(error))
                    lastTransportFailure = failure
                    if failure.transient, maximumBytes > transferred { continue }
                    throw failure
                }
            }

            guard let response else {
                throw lastTransportFailure ?? BinaryDownloadFailure("Binary download could not connect", transient: true)
            }
            if (300...399).contains(response.status) {
                guard redirects < 8, let location = response.location,
                    let redirected = URL(string: location, relativeTo: current)?.absoluteURL
                else { throw BinaryDownloadFailure("Binary download returned an invalid redirect") }
                redirects += 1
                current = redirected
                continue
            }
            guard (200...299).contains(response.status) else {
                throw BinaryDownloadFailure(
                    "Binary download returned an invalid HTTP response",
                    transient: [408, 429, 500, 502, 503, 504].contains(response.status))
            }
            if let encoding = response.encoding, !encoding.isEmpty, encoding.lowercased() != "identity" {
                throw BinaryDownloadFailure("Binary download used an unexpected content encoding")
            }
            return BinaryDownloadResult(storedBytes: response.storedBytes, transferredBytes: transferred)
        }
    }

    private func configuration(
        endpoint: BinaryNetworkEndpoint, address: BinaryResolvedAddress, output: Int32,
        maximumBytes: Int64, timeout: TimeInterval
    ) throws -> Data {
        let host = endpoint.host.contains(":") ? "[\(endpoint.host)]" : endpoint.host
        let numericAddress = address.family == AF_INET6 ? "[\(address.text)]" : address.text
        let values = [endpoint.url.absoluteString, "\(host):\(endpoint.port):\(numericAddress)"]
        guard values.allSatisfy({ value in
            !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }
        }) else {
            throw BinaryDownloadFailure("Binary download URL contains unsafe configuration characters")
        }
        func quoted(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let text = [
            "url = \(quoted(values[0]))",
            "resolve = \(quoted(values[1]))",
            // A wildcard connect target is defense in depth against any curl hostname canonicalization mismatch:
            // only the already-validated numeric address can receive this one non-redirecting request.
            "connect-to = \(quoted("::\(numericAddress):\(endpoint.port)"))",
            "output = \(quoted("/dev/fd/\(output)"))",
            "dump-header = \"/dev/fd/1\"",
            "request = \"GET\"",
            "header = \"Accept-Encoding: identity\"",
            "max-filesize = \(maximumBytes)",
            "connect-timeout = \(min(30, timeout))",
            "max-time = \(timeout)",
            "",
        ].joined(separator: "\n")
        return Data(text.utf8)
    }

    private func anonymousDescriptor(in directory: URL, prefix: String) throws -> Int32 {
        for _ in 0..<8 {
            let path = directory.appendingPathComponent(prefix + UUID().uuidString)
            let descriptor = path.path.withCString {
                open($0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            }
            if descriptor >= 0 {
                guard unlink(path.path) == 0 else {
                    close(descriptor)
                    throw BinaryDownloadFailure("Cannot unlink private binary download state")
                }
                return descriptor
            }
            if errno != EEXIST { break }
        }
        throw BinaryDownloadFailure("Cannot create private binary download state")
    }

    private func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0, errno == EINTR { continue }
                throw BinaryDownloadFailure("Cannot write private binary download state")
            }
        }
    }

    private func descriptorSize(_ descriptor: Int32) throws -> Int64 {
        var status = stat()
        guard fstat(descriptor, &status) == 0, SecureFileTree.isRegularFile(status), status.st_size >= 0 else {
            throw BinaryDownloadFailure("Binary downloader produced an invalid output file")
        }
        return status.st_size
    }

    private func parseHeaders(_ data: Data) throws -> (status: Int, location: String?, encoding: String?) {
        let text = String(decoding: data, as: UTF8.self)
        let blocks = text.components(separatedBy: "\r\n\r\n").filter { $0.hasPrefix("HTTP/") }
        guard let block = blocks.last else { throw BinaryDownloadFailure("Binary download returned malformed headers") }
        let lines = block.components(separatedBy: "\r\n")
        let statusFields = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        guard statusFields.count >= 2, let status = Int(statusFields[1]), (100...599).contains(status) else {
            throw BinaryDownloadFailure("Binary download returned a malformed status")
        }
        var location: String?
        var encoding: String?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.contains("\r"), !value.contains("\n"), !value.contains("\0") else {
                throw BinaryDownloadFailure("Binary download returned an unsafe header")
            }
            if name == "location" {
                guard location == nil else { throw BinaryDownloadFailure("Binary download returned duplicate redirects") }
                location = value
            } else if name == "content-encoding" {
                guard encoding == nil else { throw BinaryDownloadFailure("Binary download returned duplicate encodings") }
                encoding = value
            }
        }
        return (status, location, encoding)
    }

    private static func remainingTime(before deadline: UInt64) -> TimeInterval? {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { return nil }
        return TimeInterval(deadline - now) / 1_000_000_000
    }

    private static func isTransientCurlFailure(_ error: any Error) -> Bool {
        guard let failure = (error as? SwiftPodsError)?.commandFailure else { return false }
        switch failure.reason {
        case .timedOut:
            return true
        case .outputLimit:
            return false
        case .interrupted:
            return false
        case .exitStatus(let status):
            return [5, 6, 7, 18, 28, 35, 52, 55, 56, 92].contains(status)
        }
    }
}

/// Resolves and fingerprints dependency trees without following a link outside their declared root.
enum SecureFileTree {
    struct Limits {
        let entries: Int
        let bytes: Int64
        let depth: Int
        let internalHardlinksOnly: Bool

        // Binary SDK archives should remain far below this ceiling. Keeping the extracted tree at 50k objects makes
        // both preflight metadata and post-extraction Foundation traversal predictably bounded.
        static let archive = Limits(entries: 50_000, bytes: 16 * 1024 * 1024 * 1024, depth: 64, internalHardlinksOnly: true)
        static let local = Limits(entries: 200_000, bytes: 16 * 1024 * 1024 * 1024, depth: 64, internalHardlinksOnly: false)
    }

    private struct Node {
        let url: URL
        let relative: String
        let status: stat
    }

    static func existsNoFollow(_ url: URL) -> Bool {
        var value = stat()
        return url.path.withCString { lstat($0, &value) } == 0
    }

    static func statusNoFollow(_ url: URL) throws -> stat {
        var value = stat()
        guard url.path.withCString({ lstat($0, &value) }) == 0 else {
            throw SwiftPodsError("Cannot inspect \(url.path): \(String(cString: strerror(errno)))")
        }
        return value
    }

    static func isSymbolicLink(_ status: stat) -> Bool { status.st_mode & S_IFMT == S_IFLNK }
    static func isDirectory(_ status: stat) -> Bool { status.st_mode & S_IFMT == S_IFDIR }
    static func isRegularFile(_ status: stat) -> Bool { status.st_mode & S_IFMT == S_IFREG }

    static func hasExtendedACL(_ url: URL, followSymbolicLink: Bool = true) throws -> Bool {
        errno = 0
        let acl = url.path.withCString {
            followSymbolicLink ? acl_get_file($0, ACL_TYPE_EXTENDED) : acl_get_link_np($0, ACL_TYPE_EXTENDED)
        }
        guard let acl else {
            // Darwin reports ENOENT here when the object exists but has no extended ACL.
            if errno == ENOENT || errno == ENOTSUP || errno == EOPNOTSUPP { return false }
            throw SwiftPodsError("Cannot inspect access controls on \(url.path): \(String(cString: strerror(errno)))")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
        guard result == 0, entry != nil else {
            throw SwiftPodsError("Cannot inspect access controls on \(url.path): \(String(cString: strerror(errno)))")
        }
        return true
    }

    /// Removes inherited ACLs, extended attributes, file flags and group/other write bits from a tree SwiftPods has just
    /// created. In particular, a resource fork must never survive as unaccounted data outside the authenticated data fork.
    /// The tree is private while this runs, and every mutation is repeated through a no-follow descriptor.
    static func normalizePermissions(in directory: URL) throws {
        let root = try resolvedDirectory(directory, allowRootSymlink: false)
        var urls = [root]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [],
            errorHandler: { _, error in enumerationError = error; return false })
        else { throw SwiftPodsError("Cannot enumerate \(root.path)") }
        for case let url as URL in enumerator {
            guard contains(url, in: root) else { throw SwiftPodsError("Binary member escapes its root: \(url.path)") }
            let status = try statusNoFollow(url)
            urls.append(url)
            if isSymbolicLink(status) { enumerator.skipDescendants() }
        }
        if let enumerationError { throw enumerationError }

        guard let emptyACL = acl_init(0) else {
            throw SwiftPodsError("Cannot allocate an empty access-control list")
        }
        defer { acl_free(UnsafeMutableRawPointer(emptyACL)) }
        for url in urls {
            let initial = try statusNoFollow(url)
            if isSymbolicLink(initial) {
                try removeExtendedAttributes(fromSymbolicLink: url)
                let result = url.path.withCString { acl_set_link_np($0, ACL_TYPE_EXTENDED, emptyACL) }
                if result != 0, errno != ENOTSUP, errno != EOPNOTSUPP {
                    throw SwiftPodsError("Cannot remove inherited access controls from \(url.path)")
                }
                continue
            }
            guard isDirectory(initial) || isRegularFile(initial) else {
                throw SwiftPodsError("Binary tree contains a special file: \(url.path)")
            }
            // Remove an inherited ACL before opening; an inherited deny entry can otherwise prevent descriptor access.
            let aclResult = url.path.withCString { acl_set_link_np($0, ACL_TYPE_EXTENDED, emptyACL) }
            if aclResult != 0, errno != ENOTSUP, errno != EOPNOTSUPP, errno != EPERM, errno != EACCES {
                throw SwiftPodsError("Cannot remove inherited access controls from \(url.path)")
            }
            let safeMode = mode_t(initial.st_mode & 0o1777 & ~mode_t(0o022))
            let descriptor = url.path.withCString {
                open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (isDirectory(initial) ? O_DIRECTORY : 0))
            }
            guard descriptor >= 0 else {
                throw SwiftPodsError("Cannot securely open \(url.path) to normalize permissions")
            }
            defer { close(descriptor) }
            var opened = stat()
            let stable = fstat(descriptor, &opened) == 0 && opened.st_dev == initial.st_dev
                && opened.st_ino == initial.st_ino && opened.st_mode == initial.st_mode
            guard stable, fchflags(descriptor, 0) == 0 else {
                throw SwiftPodsError("Binary member changed while permissions were normalized: \(url.path)")
            }
            try removeExtendedAttributes(from: descriptor, description: url.path)
            let modeResult = fchmod(descriptor, safeMode)
            let descriptorACL = modeResult == 0 ? acl_set_fd_np(descriptor, emptyACL, ACL_TYPE_EXTENDED) : -1
            let aclError = errno
            guard modeResult == 0 else {
                throw SwiftPodsError("Binary member changed while permissions were normalized: \(url.path)")
            }
            if descriptorACL != 0, aclError != ENOTSUP, aclError != EOPNOTSUPP {
                throw SwiftPodsError("Cannot remove inherited access controls from \(url.path)")
            }
        }
    }

    private static let maximumExtendedAttributeNamesBytes = 64 * 1_024
    private static let maximumExtendedAttributeCount = 128

    private static func removeExtendedAttributes(from descriptor: Int32, description: String) throws {
        errno = 0
        let length = flistxattr(descriptor, nil, 0, 0)
        guard length >= 0 else {
            throw SwiftPodsError("Cannot inspect extended attributes on \(description): \(String(cString: strerror(errno)))")
        }
        guard length <= maximumExtendedAttributeNamesBytes else {
            throw SwiftPodsError("Binary member has too many extended-attribute name bytes: \(description)")
        }
        guard length > 0 else { return }
        var names = [CChar](repeating: 0, count: length)
        let actual = names.withUnsafeMutableBufferPointer {
            flistxattr(descriptor, $0.baseAddress, $0.count, 0)
        }
        guard actual == length else {
            throw SwiftPodsError("Extended attributes changed while they were removed from \(description)")
        }
        var offset = 0
        var count = 0
        while offset < names.count {
            guard count < maximumExtendedAttributeCount,
                let end = names[offset...].firstIndex(of: 0), end > offset
            else { throw SwiftPodsError("Binary member has malformed or excessive extended attributes: \(description)") }
            let name = names.withUnsafeBufferPointer { buffer -> String? in
                guard let base = buffer.baseAddress else { return nil }
                return String(validatingCString: base.advanced(by: offset))
            }
            guard let name, name.withCString({ fremovexattr(descriptor, $0, 0) }) == 0 else {
                throw SwiftPodsError("Cannot remove an extended attribute from \(description)")
            }
            count += 1
            offset = end + 1
        }
    }

    private static func removeExtendedAttributes(fromSymbolicLink url: URL) throws {
        errno = 0
        let length = url.path.withCString { listxattr($0, nil, 0, XATTR_NOFOLLOW) }
        guard length >= 0 else {
            if errno == ENOTSUP || errno == EOPNOTSUPP { return }
            throw SwiftPodsError("Cannot inspect symbolic-link extended attributes at \(url.path)")
        }
        guard length <= maximumExtendedAttributeNamesBytes else {
            throw SwiftPodsError("Binary symbolic link has too many extended-attribute name bytes: \(url.path)")
        }
        guard length > 0 else { return }
        var names = [CChar](repeating: 0, count: length)
        let actual = url.path.withCString { path in
            names.withUnsafeMutableBufferPointer { listxattr(path, $0.baseAddress, $0.count, XATTR_NOFOLLOW) }
        }
        guard actual == length else {
            throw SwiftPodsError("Symbolic-link extended attributes changed while they were removed: \(url.path)")
        }
        var offset = 0
        var count = 0
        while offset < names.count {
            guard count < maximumExtendedAttributeCount,
                let end = names[offset...].firstIndex(of: 0), end > offset
            else { throw SwiftPodsError("Binary symbolic link has malformed or excessive extended attributes") }
            let name = names.withUnsafeBufferPointer { buffer -> String? in
                guard let base = buffer.baseAddress else { return nil }
                return String(validatingCString: base.advanced(by: offset))
            }
            guard let name else { throw SwiftPodsError("Binary symbolic link has an invalid extended attribute") }
            let removed = url.path.withCString { path in
                name.withCString { removexattr(path, $0, XATTR_NOFOLLOW) }
            }
            guard removed == 0 else {
                throw SwiftPodsError("Cannot remove a symbolic-link extended attribute at \(url.path)")
            }
            count += 1
            offset = end + 1
        }
    }

    /// Copies only the ordinary data fork and safe POSIX mode of a validated directory tree. Files without extended
    /// attributes or flags may use APFS clone-on-write; files carrying resource forks, quarantine metadata, compression
    /// metadata or flags are streamed from an already-open descriptor so none of that unbudgeted state reaches output.
    static func copySanitizedTree(from sourceDirectory: URL, to destination: URL, limits: Limits) throws {
        let source = try resolvedDirectory(sourceDirectory, allowRootSymlink: false)
        let target = destination.standardizedFileURL
        guard !contains(target, in: source, allowRoot: true), !contains(source, in: target, allowRoot: true) else {
            throw SwiftPodsError("Sanitized binary copy overlaps its source")
        }
        guard !existsNoFollow(target) else {
            throw SwiftPodsError("Sanitized binary copy destination already exists: \(target.path)")
        }
        _ = try validate(source, allowRootSymlink: false, limits: limits, hashingContents: false)

        let fileManager = FileManager.default
        let sourceRootPath = source.standardizedFileURL.path
        let sourceRootStatus = try statusNoFollow(source)
        try fileManager.createDirectory(
            at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try normalizeCreatedNode(target, mode: 0o700, expectingDirectory: true)
            var directoryModes: [(URL, mode_t)] = []
            var enumerationError: Error?
            guard let enumerator = fileManager.enumerator(
                at: source, includingPropertiesForKeys: nil, options: [],
                errorHandler: { _, error in enumerationError = error; return false })
            else { throw SwiftPodsError("Cannot enumerate \(source.path)") }

            var entries = 0
            var bytes: Int64 = 0
            for case let sourceURL as URL in enumerator {
                guard contains(sourceURL, in: source) else {
                    throw SwiftPodsError("Binary member escapes its source while it is copied: \(sourceURL.path)")
                }
                let sourcePath = sourceURL.standardizedFileURL.path
                let relative = String(sourcePath.dropFirst(sourceRootPath.count + 1))
                let depth = relative.split(separator: "/", omittingEmptySubsequences: false).count
                guard !relative.isEmpty, depth <= limits.depth else {
                    throw SwiftPodsError("Binary path is nested too deeply while it is copied")
                }
                entries += 1
                guard entries <= limits.entries else { throw SwiftPodsError("Binary tree contains too many entries") }

                let status = try statusNoFollow(sourceURL)
                let destinationURL = target.appendingPathComponent(relative)
                if isDirectory(status) {
                    try fileManager.createDirectory(
                        at: destinationURL, withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700])
                    try normalizeCreatedNode(destinationURL, mode: 0o700, expectingDirectory: true)
                    directoryModes.append((destinationURL, safeCopiedMode(status.st_mode)))
                } else if isSymbolicLink(status) {
                    enumerator.skipDescendants()
                    let link = try fileManager.destinationOfSymbolicLink(atPath: sourceURL.path)
                    let lexical = link.hasPrefix("/")
                        ? URL(fileURLWithPath: link)
                        : sourceURL.deletingLastPathComponent().appendingPathComponent(link)
                    guard contains(lexical.standardizedFileURL, in: source, allowRoot: true),
                        contains(try realURL(sourceURL), in: source, allowRoot: true)
                    else { throw SwiftPodsError("Symbolic link escapes the binary root while it is copied") }
                    try fileManager.createSymbolicLink(atPath: destinationURL.path, withDestinationPath: link)
                    try removeExtendedAttributes(fromSymbolicLink: destinationURL)
                } else if isRegularFile(status) {
                    guard status.st_size >= 0, bytes <= limits.bytes - status.st_size else {
                        throw SwiftPodsError("Expanded archive is larger than \(limits.bytes) bytes")
                    }
                    bytes += status.st_size
                    try copySanitizedFile(from: sourceURL, expected: status, to: destinationURL)
                } else {
                    throw SwiftPodsError("Binary tree contains a special file: \(relative)")
                }
            }
            if let enumerationError { throw enumerationError }

            for (url, mode) in directoryModes.reversed() {
                try normalizeCreatedNode(url, mode: mode, expectingDirectory: true)
            }
            try normalizeCreatedNode(
                target, mode: safeCopiedMode(sourceRootStatus.st_mode), expectingDirectory: true)
            // Rewalk the private destination to catch ambient default ACLs or a metadata race before it is authenticated.
            try normalizePermissions(in: target)
        } catch {
            try? fileManager.removeItem(at: target)
            throw error
        }
    }

    private static func safeCopiedMode(_ mode: mode_t) -> mode_t {
        mode & 0o1777 & ~mode_t(0o022)
    }

    private static func normalizeCreatedNode(_ url: URL, mode: mode_t, expectingDirectory: Bool) throws {
        let descriptor = url.path.withCString {
            open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (expectingDirectory ? O_DIRECTORY : 0))
        }
        guard descriptor >= 0 else { throw SwiftPodsError("Cannot secure copied binary member: \(url.path)") }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            expectingDirectory ? isDirectory(status) : isRegularFile(status),
            fchflags(descriptor, 0) == 0
        else { throw SwiftPodsError("Copied binary member changed while it was secured: \(url.path)") }
        try removeExtendedAttributes(from: descriptor, description: url.path)
        guard fchmod(descriptor, mode) == 0, let emptyACL = acl_init(0) else {
            throw SwiftPodsError("Cannot normalize copied binary member: \(url.path)")
        }
        defer { acl_free(UnsafeMutableRawPointer(emptyACL)) }
        let aclResult = acl_set_fd_np(descriptor, emptyACL, ACL_TYPE_EXTENDED)
        guard aclResult == 0 || errno == ENOTSUP || errno == EOPNOTSUPP else {
            throw SwiftPodsError("Cannot remove copied binary access controls: \(url.path)")
        }
    }

    private static func copySanitizedFile(from source: URL, expected: stat, to destination: URL) throws {
        let input = source.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard input >= 0 else { throw SwiftPodsError("Cannot read binary file while it is copied: \(source.path)") }
        defer { close(input) }
        var opened = stat()
        guard fstat(input, &opened) == 0, sameCopySnapshot(opened, expected), isRegularFile(opened) else {
            throw SwiftPodsError("Binary file changed before it was copied: \(source.path)")
        }

        let parent = destination.deletingLastPathComponent()
        let name = destination.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw SwiftPodsError("Copied binary member has an unsafe name")
        }
        let parentDescriptor = parent.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard parentDescriptor >= 0 else { throw SwiftPodsError("Cannot open copied binary parent") }
        defer { close(parentDescriptor) }

        errno = 0
        let attributeNameBytes = flistxattr(input, nil, 0, 0)
        guard attributeNameBytes >= 0 else {
            throw SwiftPodsError("Cannot inspect binary file metadata before copying: \(source.path)")
        }
        let hasACL = try descriptorHasExtendedACL(input, description: source.path)
        var output = Int32(-1)
        if attributeNameBytes == 0, opened.st_flags == 0, !hasACL,
            name.withCString({ fclonefileat(input, parentDescriptor, $0, 0) }) == 0
        {
            output = name.withCString { openat(parentDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        } else {
            var existing = stat()
            errno = 0
            let lookup = name.withCString { fstatat(parentDescriptor, $0, &existing, AT_SYMLINK_NOFOLLOW) }
            guard lookup != 0, errno == ENOENT else {
                throw SwiftPodsError("Copied binary destination appeared concurrently: \(destination.path)")
            }
            output = name.withCString {
                openat(parentDescriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            }
            guard output >= 0 else { throw SwiftPodsError("Cannot create copied binary file: \(destination.path)") }
            do {
                try copyDataFork(input, size: opened.st_size, to: output, description: source.path)
            } catch {
                close(output)
                _ = name.withCString { unlinkat(parentDescriptor, $0, 0) }
                throw error
            }
        }
        guard output >= 0 else { throw SwiftPodsError("Cannot clone copied binary file: \(destination.path)") }
        defer { close(output) }
        guard fchflags(output, 0) == 0 else {
            throw SwiftPodsError("Cannot clear copied binary file flags: \(destination.path)")
        }

        var copied = stat()
        var finalSource = stat()
        guard fstat(output, &copied) == 0, isRegularFile(copied), copied.st_size == opened.st_size,
            fstat(input, &finalSource) == 0, sameCopySnapshot(finalSource, opened)
        else { throw SwiftPodsError("Binary file changed while it was copied: \(source.path)") }
        try removeExtendedAttributes(from: output, description: destination.path)
        guard fchmod(output, safeCopiedMode(opened.st_mode)) == 0, let emptyACL = acl_init(0) else {
            throw SwiftPodsError("Cannot normalize copied binary file: \(destination.path)")
        }
        defer { acl_free(UnsafeMutableRawPointer(emptyACL)) }
        let aclResult = acl_set_fd_np(output, emptyACL, ACL_TYPE_EXTENDED)
        guard aclResult == 0 || errno == ENOTSUP || errno == EOPNOTSUPP else {
            throw SwiftPodsError("Cannot remove copied binary file access controls: \(destination.path)")
        }
    }

    private static func descriptorHasExtendedACL(_ descriptor: Int32, description: String) throws -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT || errno == ENOTSUP || errno == EOPNOTSUPP { return false }
            throw SwiftPodsError("Cannot inspect binary file access controls: \(description)")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
        guard result == 0 else { throw SwiftPodsError("Cannot inspect binary file access controls: \(description)") }
        return entry != nil
    }

    private static func copyDataFork(_ input: Int32, size: Int64, to output: Int32, description: String) throws {
        var remaining = size
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while remaining > 0 {
            let requested = min(buffer.count, Int(remaining))
            let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, requested) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw SwiftPodsError("Binary file was truncated while it was copied: \(description)") }
            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes {
                    Darwin.write(output, $0.baseAddress!.advanced(by: written), count - written)
                }
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw SwiftPodsError("Cannot write copied binary file: \(description)") }
                written += result
            }
            remaining -= Int64(count)
        }
        var extra: UInt8 = 0
        var extraCount: Int
        repeat { extraCount = Darwin.read(input, &extra, 1) } while extraCount < 0 && errno == EINTR
        guard extraCount == 0 else { throw SwiftPodsError("Binary file grew while it was copied: \(description)") }
    }

    private static func sameCopySnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink && lhs.st_uid == rhs.st_uid && lhs.st_gid == rhs.st_gid
            && lhs.st_flags == rhs.st_flags && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    static func realURL(_ url: URL) throws -> URL {
        guard let pointer = url.path.withCString({ realpath($0, nil) }) else {
            throw SwiftPodsError("Unsafe or dangling path \(url.path): \(String(cString: strerror(errno)))")
        }
        defer { free(pointer) }
        return URL(fileURLWithPath: String(cString: pointer)).standardizedFileURL
    }

    static func resolvedDirectory(_ url: URL, allowRootSymlink: Bool) throws -> URL {
        let status = try statusNoFollow(url)
        if isSymbolicLink(status), !allowRootSymlink {
            throw SwiftPodsError("Unsafe symbolic-link directory: \(url.path)")
        }
        let resolved = try realURL(url)
        guard isDirectory(try statusNoFollow(resolved)) else {
            throw SwiftPodsError("Expected a directory at \(url.path)")
        }
        return resolved
    }

    static func contains(_ candidate: URL, in root: URL, allowRoot: Bool = false) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = candidate.standardizedFileURL.path
        return (allowRoot && path == rootPath) || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    @discardableResult
    static func validate(
        _ directory: URL, allowRootSymlink: Bool, limits: Limits, hashingContents: Bool,
        skippingTopLevelNames: Set<String> = [],
        beforeHashingContents: ((_ entries: Int, _ bytes: Int64) throws -> Void)? = nil,
        normalizingPermissionsForDigest: Bool = false
    ) throws -> (URL, String, entries: Int, bytes: Int64) {
        let root = try resolvedDirectory(directory, allowRootSymlink: allowRootSymlink)
        let rootPath = root.standardizedFileURL.path
        let fileManager = FileManager.default
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [],
            errorHandler: { _, error in enumerationError = error; return false })
        else { throw SwiftPodsError("Cannot enumerate \(root.path)") }

        var nodes: [Node] = []
        var totalBytes: Int64 = 0
        var namesByDirectory: [String: [String: String]] = [:]
        for case let url as URL in enumerator {
            guard contains(url, in: root) else { throw SwiftPodsError("Archive member escapes its root: \(url.path)") }
            let standardizedPath = url.standardizedFileURL.path
            let relative = String(standardizedPath.dropFirst(rootPath.count + 1))
            if let first = relative.split(separator: "/", omittingEmptySubsequences: false).first,
                skippingTopLevelNames.contains(String(first))
            {
                enumerator.skipDescendants()
                continue
            }
            let parent = (relative as NSString).deletingLastPathComponent
            let name = (relative as NSString).lastPathComponent
            let key = fileSystemKey(name)
            if let existing = namesByDirectory[parent]?[key], existing != name {
                throw SwiftPodsError("Binary tree contains names that collide on macOS: \(existing) and \(name)")
            }
            namesByDirectory[parent, default: [:]][key] = name
            let depth = relative.split(separator: "/", omittingEmptySubsequences: false).count
            guard depth <= limits.depth else { throw SwiftPodsError("Archive path is nested too deeply: \(relative)") }
            let status = try statusNoFollow(url)
            nodes.append(Node(url: url, relative: relative, status: status))
            guard nodes.count <= limits.entries else { throw SwiftPodsError("Archive contains too many entries") }

            if isSymbolicLink(status) {
                enumerator.skipDescendants()
                let destination = try fileManager.destinationOfSymbolicLink(atPath: url.path)
                let lexical = destination.hasPrefix("/")
                    ? URL(fileURLWithPath: destination)
                    : url.deletingLastPathComponent().appendingPathComponent(destination)
                guard contains(lexical.standardizedFileURL, in: root, allowRoot: true) else {
                    throw SwiftPodsError("Symbolic link escapes the binary root: \(relative) -> \(destination)")
                }
                let resolved = try realURL(url)
                guard contains(resolved, in: root, allowRoot: true) else {
                    throw SwiftPodsError("Symbolic link escapes the binary root: \(relative) -> \(destination)")
                }
                if isDirectory(try statusNoFollow(resolved)), contains(url.deletingLastPathComponent(), in: resolved, allowRoot: true) {
                    throw SwiftPodsError("Symbolic link creates a directory cycle: \(relative) -> \(destination)")
                }
            } else if isRegularFile(status) {
                guard status.st_size >= 0, totalBytes <= limits.bytes - status.st_size else {
                    throw SwiftPodsError("Expanded archive is larger than \(limits.bytes) bytes")
                }
                totalBytes += status.st_size
            } else if !isDirectory(status) {
                throw SwiftPodsError("Binary tree contains a special file: \(relative)")
            }
        }
        if let enumerationError { throw enumerationError }
        nodes.sort { $0.relative < $1.relative }

        if limits.internalHardlinksOnly {
            var links: [String: (count: Int, expected: UInt64)] = [:]
            for node in nodes where isRegularFile(node.status) && node.status.st_nlink > 1 {
                let key = "\(node.status.st_dev):\(node.status.st_ino)"
                let current = links[key] ?? (0, UInt64(node.status.st_nlink))
                links[key] = (current.count + 1, current.expected)
            }
            if links.values.contains(where: { UInt64($0.count) != $0.expected }) {
                throw SwiftPodsError("Archive contains a hard link whose peer is outside the extracted tree")
            }
        }
        if hashingContents { try beforeHashingContents?(nodes.count, totalBytes) }

        var hasher = SHA256()
        for node in nodes {
            update(node.relative, into: &hasher)
            let mode = normalizingPermissionsForDigest
                ? node.status.st_mode & 0o1777 & ~mode_t(0o022)
                : node.status.st_mode & 0o7777
            var permissions = UInt64(mode).bigEndian
            withUnsafeBytes(of: &permissions) { hasher.update(data: Data($0)) }
            if isDirectory(node.status) {
                update("directory", into: &hasher)
            } else if isSymbolicLink(node.status) {
                update("symlink", into: &hasher)
                update(try fileManager.destinationOfSymbolicLink(atPath: node.url.path), into: &hasher)
            } else {
                update("file", into: &hasher)
                var size = UInt64(node.status.st_size).bigEndian
                withUnsafeBytes(of: &size) { hasher.update(data: Data($0)) }
                if hashingContents { try hashFile(node, into: &hasher) }
            }
        }
        return (root, hasher.finalize().map { String(format: "%02x", $0) }.joined(), nodes.count, totalBytes)
    }

    static func digest(of directory: URL) throws -> String {
        try validate(directory, allowRootSymlink: false, limits: .local, hashingContents: true).1
    }

    /// Digest of files SwiftPods owns in its generated binary package. SwiftPM may create these two top-level cache
    /// directories; they neither define nor supply the package and should not make an otherwise idempotent install churn.
    static func generatedPackageDigest(of directory: URL) throws -> String {
        try validate(
            directory, allowRootSymlink: false, limits: .archive, hashingContents: true,
            skippingTopLevelNames: [".build", ".swiftpm"]
        ).1
    }

    private static func update(_ text: String, into hasher: inout SHA256) {
        let data = Data(text.utf8)
        var length = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
        hasher.update(data: data)
    }

    private static func fileSystemKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func hashFile(_ node: Node, into hasher: inout SHA256) throws {
        let descriptor = node.url.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else {
            throw SwiftPodsError("Cannot read \(node.url.path): \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, isRegularFile(opened), opened.st_dev == node.status.st_dev,
            opened.st_ino == node.status.st_ino, opened.st_mode == node.status.st_mode,
            opened.st_nlink == node.status.st_nlink, opened.st_size == node.status.st_size,
            opened.st_mtimespec.tv_sec == node.status.st_mtimespec.tv_sec,
            opened.st_mtimespec.tv_nsec == node.status.st_mtimespec.tv_nsec,
            opened.st_ctimespec.tv_sec == node.status.st_ctimespec.tv_sec,
            opened.st_ctimespec.tv_nsec == node.status.st_ctimespec.tv_nsec
        else { throw SwiftPodsError("Binary file changed while it was being inspected: \(node.relative)") }
        var remaining = opened.st_size
        while remaining > 0 {
            let finished = try autoreleasepool { () throws -> Bool in
                guard let data = try handle.read(upToCount: min(1 << 20, Int(remaining))), !data.isEmpty else {
                    return true
                }
                remaining -= Int64(data.count)
                hasher.update(data: data)
                return false
            }
            if finished { throw SwiftPodsError("Binary file was truncated while it was being read: \(node.relative)") }
        }
        let extra = try handle.read(upToCount: 1)
        var final = stat()
        guard fstat(descriptor, &final) == 0, final.st_dev == opened.st_dev, final.st_ino == opened.st_ino,
            final.st_mode == opened.st_mode, final.st_nlink == opened.st_nlink, final.st_size == opened.st_size,
            final.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
            final.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec,
            final.st_ctimespec.tv_sec == opened.st_ctimespec.tv_sec,
            final.st_ctimespec.tv_nsec == opened.st_ctimespec.tv_nsec,
            remaining == 0, extra?.isEmpty != false
        else { throw SwiftPodsError("Binary file changed while it was being read: \(node.relative)") }
    }
}

/// Downloads, verifies and unpacks binary SDK archives, cached by checksum.
struct BinaryStore {
    let cache: URL
    let runner: CommandRunner
    let offline: Bool
    let downloader: any BinaryDownloadClient
    let maximumCacheBytes: Int64
    let maximumCacheEntries: Int
    let minimumFreeSpaceReserveBytes: Int64
    let cacheLockOperationHook: (@Sendable (String) -> Void)?

    private enum RemoteSource {
        case https(URL)
        case local(URL, podfileRoot: URL)
        case anchoredLocal(AnchoredPath)
    }

    private final class AnchoredPath {
        private let root: AnchoredDirectory
        private let components: [String]

        init(root: AnchoredDirectory, components: [String]) {
            self.root = root
            self.components = components
        }

        func openRegularFile() throws -> AnchoredOpenedPath {
            try root.open(components, expectingDirectory: false)
        }
    }

    private final class AnchoredOpenedPath {
        let descriptor: Int32
        let url: URL
        private let identity: (device: dev_t, inode: ino_t)

        init(descriptor: Int32, url: URL) throws {
            self.descriptor = descriptor
            self.url = url
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                close(descriptor)
                throw SwiftPodsError("Cannot inspect an anchored binary source")
            }
            identity = (status.st_dev, status.st_ino)
            do {
                try verifyPathIdentity()
            } catch {
                close(descriptor)
                throw error
            }
        }

        deinit { close(descriptor) }

        func verifyPathIdentity() throws {
            var opened = stat()
            var linked = stat()
            guard fstat(descriptor, &opened) == 0, url.path.withCString({ lstat($0, &linked) }) == 0,
                !SecureFileTree.isSymbolicLink(linked), opened.st_dev == identity.device,
                opened.st_ino == identity.inode, linked.st_dev == identity.device, linked.st_ino == identity.inode
            else { throw SwiftPodsError("Anchored binary source changed while it was in use") }
        }
    }

    /// Owns a duplicate of the caller's workspace descriptor. All supplied paths are resolved component-by-component
    /// from this inode; a pathname ABA replacement of the workspace therefore cannot redirect local binary reads.
    private final class AnchoredDirectory {
        private let descriptor: Int32

        init(borrowing source: Int32) throws {
            descriptor = fcntl(source, F_DUPFD_CLOEXEC, 0)
            guard descriptor >= 0 else { throw SwiftPodsError("Cannot retain the anchored Podfile directory") }
            var status = stat()
            guard fstat(descriptor, &status) == 0, SecureFileTree.isDirectory(status) else {
                close(descriptor)
                throw SwiftPodsError("Anchored Podfile descriptor is not a directory")
            }
        }

        deinit { close(descriptor) }

        func open(_ initial: [String], expectingDirectory: Bool) throws -> AnchoredOpenedPath {
            var pending = initial
            var symbolicLinks = 0
            while true {
                var current = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
                guard current >= 0 else { throw SwiftPodsError("Cannot duplicate the anchored Podfile directory") }
                var traversed: [String] = []
                var redirected = false
                for (index, component) in pending.enumerated() {
                    var linked = stat()
                    guard component.withCString({ fstatat(current, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                        let problem = errno
                        close(current)
                        throw SwiftPodsError("Cannot open anchored binary source: \(String(cString: strerror(problem)))")
                    }
                    if SecureFileTree.isSymbolicLink(linked) {
                        symbolicLinks += 1
                        guard symbolicLinks <= SecureFileTree.Limits.local.depth else {
                            close(current)
                            throw SwiftPodsError("Anchored binary source contains too many symbolic links")
                        }
                        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                        let length = component.withCString { pointer in
                            buffer.withUnsafeMutableBufferPointer {
                                readlinkat(current, pointer, $0.baseAddress, $0.count)
                            }
                        }
                        var rechecked = stat()
                        guard length > 0, length < buffer.count,
                            component.withCString({ fstatat(current, $0, &rechecked, AT_SYMLINK_NOFOLLOW) }) == 0,
                            SecureFileTree.isSymbolicLink(rechecked), linked.st_dev == rechecked.st_dev,
                            linked.st_ino == rechecked.st_ino,
                            let target = String(
                                bytes: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, encoding: .utf8),
                            !target.hasPrefix("/")
                        else {
                            close(current)
                            throw SwiftPodsError("Anchored binary symbolic link is unsafe or changed while inspected")
                        }
                        let remainder = Array(pending.dropFirst(index + 1))
                        pending = try BinaryStore.normalizedAnchoredComponents(
                            traversed + target.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                                + remainder)
                        close(current)
                        redirected = true
                        break
                    }
                    let final = index == pending.index(before: pending.endIndex)
                    let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                        | ((!final || expectingDirectory) ? O_DIRECTORY : 0)
                    let next = component.withCString { openat(current, $0, flags) }
                    guard next >= 0 else {
                        let problem = errno
                        close(current)
                        throw SwiftPodsError("Cannot securely open anchored binary source: \(String(cString: strerror(problem)))")
                    }
                    var opened = stat()
                    guard fstat(next, &opened) == 0, opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino,
                        final ? (expectingDirectory ? SecureFileTree.isDirectory(opened) : SecureFileTree.isRegularFile(opened))
                            : SecureFileTree.isDirectory(opened)
                    else {
                        close(next)
                        close(current)
                        throw SwiftPodsError("Anchored binary source changed while it was opened")
                    }
                    close(current)
                    current = next
                    traversed.append(component)
                }
                if redirected { continue }
                guard !pending.isEmpty else {
                    if expectingDirectory {
                        return try AnchoredOpenedPath(descriptor: current, url: try descriptorURL(current))
                    }
                    close(current)
                    throw SwiftPodsError("Anchored binary file path is empty")
                }
                return try AnchoredOpenedPath(descriptor: current, url: try descriptorURL(current))
            }
        }

        private func descriptorURL(_ source: Int32) throws -> URL {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let result = buffer.withUnsafeMutableBufferPointer { pointer in
                swiftpods_fgetpath(source, pointer.baseAddress!)
            }
            guard result == 0, buffer[0] != 0 else {
                throw SwiftPodsError("Cannot recover the pathname of an anchored binary source")
            }
            let path = String(
                decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
    }

    private final class SelectionTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var sources: Set<String> = []
        private var outputs: Set<String> = []
        private var count = 0

        func reserve(frameworks: [URL], resources: [URL], binary: Binary) throws {
            let selections = frameworks.map { BinaryArtifactSelection($0, kind: .framework) }
                + resources.map { BinaryArtifactSelection($0, kind: .resource) }
            try lock.withLock {
                guard count <= BinaryStore.maximumSelectedArtifacts - selections.count else {
                    throw SwiftPodsError("Binaries select too many artifacts", file: binary.declaredAt.description)
                }
                var newSources: Set<String> = []
                var newOutputs: Set<String> = []
                var selected: [BinaryArtifactSelection] = []
                for selection in selections {
                    // Fold only the comparison identity. The caller keeps using the authenticated, exactly resolved URL
                    // for I/O, so a case/Unicode alias cannot redirect which tree is copied.
                    let source = selection.pathKey
                    let output = selection.outputKey
                    guard newSources.insert(source).inserted, !sources.contains(source) else {
                        throw SwiftPodsError(
                            "Binary artifact is selected more than once: \(selection.source.path)",
                            file: binary.declaredAt.description)
                    }
                    guard newOutputs.insert(output).inserted, !outputs.contains(output) else {
                        throw SwiftPodsError(
                            "Binary artifacts have colliding output names: \(selection.source.lastPathComponent)",
                            file: binary.declaredAt.description)
                    }
                    let overlapsPriorDeclaration = sources.contains {
                        source.hasPrefix($0 + "/") || $0.hasPrefix(source + "/")
                    }
                    guard !overlapsPriorDeclaration,
                        !selected.contains(where: { selection.overlaps($0) && !selection.permitsOverlap(with: $0) })
                    else {
                        throw SwiftPodsError(
                            "Binary artifacts select overlapping directory trees",
                            file: binary.declaredAt.description,
                            hint: "Only resource bundles inside a selected xcframework of the same binary may overlap")
                    }
                    selected.append(selection)
                }
                sources.formUnion(newSources)
                outputs.formUnion(newOutputs)
                count += selections.count
            }
        }
    }

    private struct WorkBudgetError: Error, CustomStringConvertible {
        let underlying: SwiftPodsError
        var description: String { underlying.description }
    }

    /// Bounds the aggregate disk, CPU and network-amplified work of one install, not just each individual tree.
    private final class WorkBudget: @unchecked Sendable {
        private let lock = NSLock()
        private var remoteArchives: Set<String> = []
        private var downloadBytes: Int64 = 0
        private var archiveBytes: Int64 = 0
        private var entries = 0
        private var bytes: Int64 = 0
        private var scannedEntries = 0

        var usage: (entries: Int, bytes: Int64) { lock.withLock { (entries, bytes) } }

        struct DownloadReservation {
            let bytes: Int64
        }

        func beginRemoteArchive(sha256: String, binary: Binary) throws {
            try lock.withLock {
                guard !remoteArchives.contains(sha256) else { return }
                guard remoteArchives.count < BinaryStore.maximumRemoteArchives else {
                    throw WorkBudgetError(underlying: SwiftPodsError(
                        "Binaries require more than \(BinaryStore.maximumRemoteArchives) remote archives in one install",
                        file: binary.declaredAt.description,
                        hint: "Reduce or consolidate binary declarations"))
                }
                remoteArchives.insert(sha256)
            }
        }

        func beginDownload(_ binary: Binary) throws -> DownloadReservation {
            try lock.withLock {
                let remaining = BinaryStore.maximumAggregateDownloadBytes - downloadBytes
                let amount = min(BinaryStore.maximumArchiveBytes, remaining)
                guard amount > 0 else {
                    throw WorkBudgetError(underlying: SwiftPodsError(
                        "Binary downloads exceed the aggregate installation network budget",
                        file: binary.declaredAt.description,
                        hint: "Download attempts in one install are limited to "
                            + "\(BinaryStore.maximumAggregateDownloadBytes) bytes"))
                }
                downloadBytes += amount
                return DownloadReservation(bytes: amount)
            }
        }

        func finishDownload(_ reservation: DownloadReservation, storedBytes: Int64, binary: Binary) throws {
            try lock.withLock {
                guard storedBytes >= 0, storedBytes <= reservation.bytes else {
                    throw WorkBudgetError(underlying: SwiftPodsError(
                        "A binary download exceeded its reserved size", file: binary.declaredAt.description))
                }
                downloadBytes -= reservation.bytes - storedBytes
            }
        }

        func reserveArchive(bytes newBytes: Int64, binary: Binary) throws {
            try lock.withLock {
                guard newBytes >= 0, newBytes <= BinaryStore.maximumAggregateArchiveBytes,
                    archiveBytes <= BinaryStore.maximumAggregateArchiveBytes - newBytes
                else {
                    throw WorkBudgetError(underlying: SwiftPodsError(
                        "Binary archives exceed the aggregate installation download/cache budget",
                        file: binary.declaredAt.description,
                        hint: "Archive reads in one install are limited to \(BinaryStore.maximumAggregateArchiveBytes) bytes"))
                }
                archiveBytes += newBytes
            }
        }

        func reserve(entries newEntries: Int, bytes newBytes: Int64, binary: Binary) throws {
            try lock.withLock {
                guard newEntries >= 0, newEntries <= SecureFileTree.Limits.archive.entries,
                    newBytes >= 0, newBytes <= SecureFileTree.Limits.archive.bytes,
                    entries <= SecureFileTree.Limits.archive.entries - newEntries,
                    bytes <= SecureFileTree.Limits.archive.bytes - newBytes
                else {
                    throw WorkBudgetError(underlying: SwiftPodsError(
                        "Binary artifacts exceed the aggregate installation work budget",
                        file: binary.declaredAt.description,
                        hint: "The combined selected trees are limited to \(SecureFileTree.Limits.archive.entries) entries "
                            + "and \(SecureFileTree.Limits.archive.bytes) expanded bytes"))
                }
                entries += newEntries
                bytes += newBytes
            }
        }

        func reserveScan(entries newEntries: Int, binary: Binary) throws {
            try lock.withLock {
                guard newEntries >= 0, newEntries <= SecureFileTree.Limits.local.entries,
                    scannedEntries <= SecureFileTree.Limits.local.entries - newEntries
                else {
                    throw WorkBudgetError(underlying: SwiftPodsError(
                        "Binary artifact discovery exceeds the aggregate installation scan budget",
                        file: binary.declaredAt.description,
                        hint: "The combined artifact indexes are limited to \(SecureFileTree.Limits.local.entries) entries"))
                }
                scannedEntries += newEntries
            }
        }
    }

    private struct RemoteSnapshot {
        let root: URL
        let lease: SnapshotLease?
    }

    /// One checksum is authenticated at most once per install. Waiters share the immutable private snapshot, and a
    /// failed checksum is memoized too so repeated declarations cannot amplify download or extraction work. This is
    /// deliberately fail-fast for another URL with the same SHA during this install; a later install may retry it.
    private final class RemoteSnapshotCache: @unchecked Sendable {
        private enum State {
            case loading
            case ready(RemoteSnapshot)
            case failed
        }

        private let condition = NSCondition()
        private var states: [String: State] = [:]

        func resolve(
            _ sha256: String, priorFailure: () -> any Error, loader: () throws -> RemoteSnapshot
        ) throws -> RemoteSnapshot {
            condition.lock()
            while true {
                switch states[sha256] {
                case .loading:
                    condition.wait()
                case .ready(let snapshot):
                    condition.unlock()
                    return snapshot
                case .failed:
                    condition.unlock()
                    throw priorFailure()
                case nil:
                    states[sha256] = .loading
                    condition.unlock()
                    do {
                        let snapshot = try loader()
                        condition.lock()
                        states[sha256] = .ready(snapshot)
                        condition.broadcast()
                        condition.unlock()
                        return snapshot
                    } catch {
                        condition.lock()
                        // Never retain command stderr or a large archive-listing error for the lifetime of the install.
                        states[sha256] = .failed
                        condition.broadcast()
                        condition.unlock()
                        throw error
                    }
                }
            }
        }
    }

    private struct ArtifactIndex {
        let root: URL
        let byExtension: [String: [URL]]
        let entries: Int
    }

    private final class ArtifactIndexCache: @unchecked Sendable {
        private enum State {
            case loading
            case ready(ArtifactIndex)
            case failed
        }

        private let condition = NSCondition()
        private var states: [String: State] = [:]
        private var builds = 0

        var buildCount: Int {
            condition.withLock { builds }
        }

        func resolve(root: URL, loader: () throws -> ArtifactIndex) throws -> ArtifactIndex {
            let key = root.standardizedFileURL.path
            condition.lock()
            while true {
                switch states[key] {
                case .loading:
                    condition.wait()
                case .ready(let index):
                    condition.unlock()
                    return index
                case .failed:
                    condition.unlock()
                    throw SwiftPodsError("Binary artifact index failed earlier in this install: \(root.path)")
                case nil:
                    states[key] = .loading
                    condition.unlock()
                    do {
                        let index = try loader()
                        condition.lock()
                        states[key] = .ready(index)
                        builds += 1
                        condition.broadcast()
                        condition.unlock()
                        return index
                    } catch {
                        condition.lock()
                        states[key] = .failed
                        condition.broadcast()
                        condition.unlock()
                        throw error
                    }
                }
            }
        }
    }

    private static let maximumArchiveBytes: Int64 = 4 * 1024 * 1024 * 1024
    private static let maximumAggregateDownloadBytes: Int64 = 16 * 1024 * 1024 * 1024
    private static let maximumAggregateArchiveBytes: Int64 = 16 * 1024 * 1024 * 1024
    static let defaultMaximumCacheBytes: Int64 = 64 * 1024 * 1024 * 1024
    static let defaultMaximumCacheEntries = 1_000_000
    static let defaultMinimumFreeSpaceReserveBytes: Int64 = 512 * 1024 * 1024
    private static let maximumArchiveMetadataBytes = 16 * 1024
    private static let maximumAggregateArchiveMetadataBytes = 64 * 1024 * 1024
    private static let maximumTarExtendedHeaderBytes: Int64 = 1 * 1024 * 1024
    private static let maximumArchiveEntries = 50_000
    private static let commandTimeout: TimeInterval = 10 * 60
    private static let cacheLockTimeout: TimeInterval = 10 * 60
    private static let maximumSelectedArtifacts = 1_024
    private static let maximumRemoteArchives = 64
    private static let maximumCacheLockBuckets = 64
    private static let maximumCacheRootEntries = 16_384
    private static let maximumCacheQuotaCandidates = 16_384
    private static let maximumCacheScanEntries = 1_000_000
    private static let maximumCacheScanDepth = 68
    private static let cacheScanTimeout: TimeInterval = 30
    private static let cacheNamespaceName = ".swiftpods-cache-v3"
    private let selectionTracker = SelectionTracker()
    private let workBudget = WorkBudget()
    private let remoteSnapshots = RemoteSnapshotCache()
    private let artifactIndexes = ArtifactIndexCache()

    /// Retains the authenticated cache-root inode for the whole cache transaction. URL-based APIs are still needed by
    /// Foundation and archive tools, so every destructive boundary also proves that the canonical pathname continues
    /// to denote this descriptor rather than a replacement inserted after initial validation.
    private final class PreparedCacheRoot {
        let url: URL
        let descriptor: Int32
        private let parentDescriptor: Int32
        private let name: String
        private let identity: (device: dev_t, inode: ino_t)

        init(url: URL, descriptor source: Int32) throws {
            self.url = url.standardized
            name = self.url.lastPathComponent
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
                throw SwiftPodsError("Binary cache has an unsafe final path component")
            }
            descriptor = fcntl(source, F_DUPFD_CLOEXEC, 0)
            guard descriptor >= 0 else { throw SwiftPodsError("Cannot retain binary cache descriptor") }
            parentDescriptor = self.url.deletingLastPathComponent().path.withCString {
                open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard parentDescriptor >= 0 else {
                close(descriptor)
                throw SwiftPodsError("Cannot retain binary cache parent descriptor")
            }
            var status = stat()
            guard fstat(descriptor, &status) == 0, SecureFileTree.isDirectory(status) else {
                close(parentDescriptor)
                close(descriptor)
                throw SwiftPodsError("Cannot inspect retained binary cache descriptor")
            }
            identity = (status.st_dev, status.st_ino)
            do {
                try verifyIdentity()
            } catch {
                close(parentDescriptor)
                close(descriptor)
                throw error
            }
        }

        deinit {
            close(parentDescriptor)
            close(descriptor)
        }

        func verifyIdentity() throws {
            var opened = stat()
            var linked = stat()
            var pathname = stat()
            guard fstat(descriptor, &opened) == 0,
                name.withCString({ fstatat(parentDescriptor, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
                url.path.withCString({ lstat($0, &pathname) }) == 0,
                SecureFileTree.isDirectory(opened), SecureFileTree.isDirectory(linked),
                SecureFileTree.isDirectory(pathname), !SecureFileTree.isSymbolicLink(linked),
                !SecureFileTree.isSymbolicLink(pathname),
                opened.st_dev == identity.device, opened.st_ino == identity.inode,
                linked.st_dev == identity.device, linked.st_ino == identity.inode,
                pathname.st_dev == identity.device, pathname.st_ino == identity.inode
            else { throw SwiftPodsError("Binary cache root changed while it was in use") }
            try BinaryStore.validateCacheDirectoryDescriptor(descriptor, path: url.path)
        }
    }

    /// Separates an authenticated cache-publication race from ordinary corrupt-cache errors. The caller must not
    /// recursively remove the checksum entry after this error: its pathname may now denote an object supplied by a
    /// concurrent same-UID process rather than the entry SwiftPods originally inspected.
    private struct CachePublicationRace: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) { self.description = description }
    }

    /// Pins the checksum directory and its current `content` child before refresh work begins. Keeping the descriptors
    /// open prevents inode reuse, while the pre/post pathname checks turn publication into an inode-token comparison
    /// rather than trusting that a familiar pathname still denotes the same directory.
    private final class PreparedCacheDestination {
        let parentDescriptor: Int32
        let parentName: String
        let childName: String
        private let cacheRoot: PreparedCacheRoot
        private let parentIdentity: (device: dev_t, inode: ino_t)
        private let childDescriptor: Int32?
        private let childIdentity: (device: dev_t, inode: ino_t)?

        init(parentName: String, childName: String, in cacheRoot: PreparedCacheRoot) throws {
            guard BinaryStore.isValidSHA256(parentName), !childName.isEmpty, childName != ".", childName != "..",
                !childName.contains("/"), !childName.contains("\0"), childName.utf8.count <= Int(NAME_MAX)
            else { throw SwiftPodsError("Binary cache publication destination is invalid") }
            self.parentName = parentName
            self.childName = childName
            self.cacheRoot = cacheRoot

            try cacheRoot.verifyIdentity()
            let openedParent = parentName.withCString {
                openat(cacheRoot.descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard openedParent >= 0 else {
                throw CachePublicationRace("Binary cache entry changed before refresh publication")
            }
            parentDescriptor = openedParent

            var parentOpened = stat()
            var parentLinked = stat()
            guard fstat(openedParent, &parentOpened) == 0,
                parentName.withCString({
                    fstatat(cacheRoot.descriptor, $0, &parentLinked, AT_SYMLINK_NOFOLLOW)
                }) == 0,
                parentOpened.st_dev == parentLinked.st_dev, parentOpened.st_ino == parentLinked.st_ino,
                SecureFileTree.isDirectory(parentOpened), SecureFileTree.isDirectory(parentLinked),
                !SecureFileTree.isSymbolicLink(parentLinked), parentOpened.st_uid == geteuid()
            else {
                close(openedParent)
                throw CachePublicationRace("Binary cache entry changed before refresh publication")
            }
            parentIdentity = (parentOpened.st_dev, parentOpened.st_ino)

            let openedChild = childName.withCString {
                openat(openedParent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            if openedChild >= 0 {
                var childOpened = stat()
                var childLinked = stat()
                guard fstat(openedChild, &childOpened) == 0,
                    childName.withCString({ fstatat(openedParent, $0, &childLinked, AT_SYMLINK_NOFOLLOW) }) == 0,
                    childOpened.st_dev == childLinked.st_dev, childOpened.st_ino == childLinked.st_ino,
                    SecureFileTree.isDirectory(childOpened), SecureFileTree.isDirectory(childLinked),
                    !SecureFileTree.isSymbolicLink(childLinked), childOpened.st_uid == geteuid()
                else {
                    close(openedChild)
                    close(openedParent)
                    throw CachePublicationRace("Binary cache content changed before refresh publication")
                }
                childDescriptor = openedChild
                childIdentity = (childOpened.st_dev, childOpened.st_ino)
            } else {
                let problem = errno
                guard problem == ENOENT else {
                    close(openedParent)
                    throw CachePublicationRace("Binary cache content changed before refresh publication")
                }
                childDescriptor = nil
                childIdentity = nil
            }

            do {
                try BinaryStore.validateCacheDirectoryDescriptor(
                    openedParent, path: cacheRoot.url.appendingPathComponent(parentName).path)
                try verifyExpectedState()
            } catch {
                if let childDescriptor { close(childDescriptor) }
                close(openedParent)
                throw error
            }
        }

        deinit {
            if let childDescriptor { close(childDescriptor) }
            close(parentDescriptor)
        }

        var existed: Bool { childIdentity != nil }

        func verifyParent() throws {
            try cacheRoot.verifyIdentity()
            var opened = stat()
            var linked = stat()
            guard fstat(parentDescriptor, &opened) == 0,
                parentName.withCString({
                    fstatat(cacheRoot.descriptor, $0, &linked, AT_SYMLINK_NOFOLLOW)
                }) == 0,
                opened.st_dev == parentIdentity.device, opened.st_ino == parentIdentity.inode,
                linked.st_dev == parentIdentity.device, linked.st_ino == parentIdentity.inode,
                SecureFileTree.isDirectory(opened), SecureFileTree.isDirectory(linked),
                !SecureFileTree.isSymbolicLink(linked)
            else { throw CachePublicationRace("Binary cache entry changed during refresh publication") }
        }

        func verifyExpectedState() throws {
            try verifyParent()
            var linked = stat()
            errno = 0
            let result = childName.withCString {
                fstatat(parentDescriptor, $0, &linked, AT_SYMLINK_NOFOLLOW)
            }
            if let childIdentity, let childDescriptor {
                var opened = stat()
                guard result == 0, fstat(childDescriptor, &opened) == 0,
                    opened.st_dev == childIdentity.device, opened.st_ino == childIdentity.inode,
                    linked.st_dev == childIdentity.device, linked.st_ino == childIdentity.inode,
                    SecureFileTree.isDirectory(opened), SecureFileTree.isDirectory(linked),
                    !SecureFileTree.isSymbolicLink(linked)
                else { throw CachePublicationRace("Binary cache content changed during refresh publication") }
            } else {
                guard result != 0, errno == ENOENT else {
                    throw CachePublicationRace("Binary cache content appeared during refresh publication")
                }
            }
        }

        func matchesExpectedChild(_ status: stat) -> Bool {
            guard let childIdentity else { return false }
            return status.st_dev == childIdentity.device && status.st_ino == childIdentity.inode
                && SecureFileTree.isDirectory(status) && !SecureFileTree.isSymbolicLink(status)
        }

        func duplicateExpectedChildDescriptor() -> Int32? {
            guard let childDescriptor else { return nil }
            let duplicate = fcntl(childDescriptor, F_DUPFD_CLOEXEC, 0)
            return duplicate >= 0 ? duplicate : nil
        }
    }

    /// Retains the inode of a private cache staging directory. The cache root is intentionally descriptor-relative:
    /// another process running as the same account can rename and recreate a pathname despite mode 0700, so a URL alone
    /// is not an identity. Every path-based operation is bracketed by this identity check and the final publication uses
    /// `renameatx_np` under the authenticated cache-root descriptor.
    private final class PreparedCacheStaging {
        let url: URL
        let descriptor: Int32
        private let cacheRoot: PreparedCacheRoot
        private let name: String
        private let identity: (device: dev_t, inode: ino_t)
        private var cleanupSafe = true
        private var cleanupExpectedChild: (name: String, descriptor: Int32)?

        init(prefix: String, in cacheRoot: PreparedCacheRoot) throws {
            guard prefix == ".download-" || prefix == ".refresh-" else {
                throw SwiftPodsError("Binary cache staging prefix is invalid")
            }
            self.cacheRoot = cacheRoot

            var createdName: String?
            for _ in 0..<8 {
                let candidate = prefix + UUID().uuidString
                if candidate.withCString({ mkdirat(cacheRoot.descriptor, $0, 0o700) }) == 0 {
                    createdName = candidate
                    break
                }
                guard errno == EEXIST else {
                    throw SwiftPodsError("Cannot create a private binary cache staging directory")
                }
            }
            guard let createdName else {
                throw SwiftPodsError("Cannot allocate a unique binary cache staging directory")
            }
            name = createdName
            url = cacheRoot.url.appendingPathComponent(createdName, isDirectory: true)

            let opened = createdName.withCString {
                openat(cacheRoot.descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard opened >= 0 else {
                _ = createdName.withCString { unlinkat(cacheRoot.descriptor, $0, AT_REMOVEDIR) }
                throw SwiftPodsError("Cannot retain binary cache staging directory")
            }
            do {
                try BinaryStore.secureNewCacheDirectoryDescriptor(opened, path: url.path)
                var status = stat()
                var linked = stat()
                guard fstat(opened, &status) == 0,
                    createdName.withCString({
                        fstatat(cacheRoot.descriptor, $0, &linked, AT_SYMLINK_NOFOLLOW)
                    }) == 0,
                    status.st_dev == linked.st_dev, status.st_ino == linked.st_ino,
                    SecureFileTree.isDirectory(status), SecureFileTree.isDirectory(linked),
                    !SecureFileTree.isSymbolicLink(linked), status.st_uid == geteuid()
                else { throw SwiftPodsError("Binary cache staging directory changed while it was opened") }
                descriptor = opened
                identity = (status.st_dev, status.st_ino)
                try verifyIdentity()
            } catch {
                close(opened)
                _ = createdName.withCString { unlinkat(cacheRoot.descriptor, $0, AT_REMOVEDIR) }
                throw error
            }
        }

        deinit {
            if let cleanupExpectedChild { close(cleanupExpectedChild.descriptor) }
            close(descriptor)
        }

        func child(_ component: String, isDirectory: Bool = false) throws -> URL {
            guard !component.isEmpty, component != ".", component != "..", !component.contains("/"),
                !component.contains("\0"), component.utf8.count <= Int(NAME_MAX)
            else { throw SwiftPodsError("Binary cache staging child name is invalid") }
            return url.appendingPathComponent(component, isDirectory: isDirectory)
        }

        func verifyIdentity() throws {
            try cacheRoot.verifyIdentity()
            var opened = stat()
            var linked = stat()
            guard fstat(descriptor, &opened) == 0,
                name.withCString({ fstatat(cacheRoot.descriptor, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
                opened.st_dev == identity.device, opened.st_ino == identity.inode,
                linked.st_dev == identity.device, linked.st_ino == identity.inode,
                SecureFileTree.isDirectory(opened), SecureFileTree.isDirectory(linked),
                !SecureFileTree.isSymbolicLink(linked), opened.st_uid == geteuid(),
                opened.st_mode & 0o077 == 0
            else { throw SwiftPodsError("Binary cache staging directory changed while it was in use") }
        }

        func publish(as destinationName: String) throws {
            guard BinaryStore.isValidSHA256(destinationName) else {
                throw SwiftPodsError("Binary cache publication name is invalid")
            }
            try verifyIdentity()
            var existing = stat()
            errno = 0
            let destinationResult = destinationName.withCString {
                fstatat(cacheRoot.descriptor, $0, &existing, AT_SYMLINK_NOFOLLOW)
            }
            guard destinationResult != 0, errno == ENOENT else {
                throw SwiftPodsError("Binary cache destination appeared before publication")
            }
            let renamed = name.withCString { sourcePointer in
                destinationName.withCString { destinationPointer in
                    renameatx_np(
                        cacheRoot.descriptor, sourcePointer, cacheRoot.descriptor, destinationPointer,
                        UInt32(RENAME_EXCL))
                }
            }
            guard renamed == 0 else {
                throw SwiftPodsError("Cannot atomically publish binary cache entry: \(String(cString: strerror(errno)))")
            }
            var opened = stat()
            var linked = stat()
            guard fstat(descriptor, &opened) == 0,
                destinationName.withCString({
                    fstatat(cacheRoot.descriptor, $0, &linked, AT_SYMLINK_NOFOLLOW)
                }) == 0,
                opened.st_dev == identity.device, opened.st_ino == identity.inode,
                linked.st_dev == identity.device, linked.st_ino == identity.inode,
                SecureFileTree.isDirectory(opened), SecureFileTree.isDirectory(linked)
            else { throw SwiftPodsError("Binary cache staging directory changed during publication") }
            try cacheRoot.verifyIdentity()
        }

        func publishDirectoryChild(_ sourceName: String, to destination: PreparedCacheDestination) throws {
            guard !sourceName.isEmpty, sourceName != ".", sourceName != "..", !sourceName.contains("/")
            else { throw SwiftPodsError("Binary cache child publication path is invalid") }
            try verifyIdentity()
            try destination.verifyExpectedState()

            let source = sourceName.withCString {
                openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard source >= 0 else { throw SwiftPodsError("Cannot retain refreshed binary content") }
            defer { close(source) }
            var sourceOpened = stat()
            var sourceLinked = stat()
            guard fstat(source, &sourceOpened) == 0,
                sourceName.withCString({ fstatat(descriptor, $0, &sourceLinked, AT_SYMLINK_NOFOLLOW) }) == 0,
                sourceOpened.st_dev == sourceLinked.st_dev, sourceOpened.st_ino == sourceLinked.st_ino,
                SecureFileTree.isDirectory(sourceOpened), SecureFileTree.isDirectory(sourceLinked),
                sourceOpened.st_uid == geteuid()
            else { throw SwiftPodsError("Refreshed binary content changed before publication") }

            let flags = destination.existed ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)
            let renamed = sourceName.withCString { sourcePointer in
                destination.childName.withCString { destinationPointer in
                    renameatx_np(descriptor, sourcePointer, destination.parentDescriptor, destinationPointer, flags)
                }
            }
            guard renamed == 0 else {
                if errno == EEXIST || errno == ENOENT || errno == ENOTDIR {
                    throw CachePublicationRace("Binary cache content changed during refresh publication")
                }
                throw SwiftPodsError("Cannot atomically refresh binary cache: \(String(cString: strerror(errno)))")
            }

            cleanupSafe = !destination.existed
            var published = stat()
            let publishedResult = destination.childName.withCString {
                fstatat(destination.parentDescriptor, $0, &published, AT_SYMLINK_NOFOLLOW)
            }
            let publishedMatchesSource = publishedResult == 0
                && published.st_dev == sourceOpened.st_dev && published.st_ino == sourceOpened.st_ino
                && SecureFileTree.isDirectory(published) && !SecureFileTree.isSymbolicLink(published)

            if destination.existed {
                var displaced = stat()
                let displacedResult = sourceName.withCString {
                    fstatat(descriptor, $0, &displaced, AT_SYMLINK_NOFOLLOW)
                }
                if publishedMatchesSource, displacedResult == 0, destination.matchesExpectedChild(displaced),
                    let expectedDescriptor = destination.duplicateExpectedChildDescriptor()
                {
                    cleanupExpectedChild = (sourceName, expectedDescriptor)
                    cleanupSafe = true
                } else {
                    // The destination changed after the last token check but before RENAME_SWAP. Restore whichever
                    // directory was actually displaced; if a second race prevents a proven rollback, preserve staging
                    // wholesale instead of recursively deleting an object that SwiftPods does not own.
                    cleanupSafe = false
                    if publishedMatchesSource {
                        let displacedDescriptor = sourceName.withCString {
                            openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                        }
                        if displacedDescriptor >= 0 {
                            defer { close(displacedDescriptor) }
                            var displacedOpened = stat()
                            var displacedLinked = stat()
                            if fstat(displacedDescriptor, &displacedOpened) == 0,
                                sourceName.withCString({
                                    fstatat(descriptor, $0, &displacedLinked, AT_SYMLINK_NOFOLLOW)
                                }) == 0,
                                displacedOpened.st_dev == displacedLinked.st_dev,
                                displacedOpened.st_ino == displacedLinked.st_ino,
                                SecureFileTree.isDirectory(displacedOpened), SecureFileTree.isDirectory(displacedLinked),
                                sourceName.withCString({ sourcePointer in
                                    destination.childName.withCString { destinationPointer in
                                        renameatx_np(
                                            descriptor, sourcePointer, destination.parentDescriptor,
                                            destinationPointer, UInt32(RENAME_SWAP))
                                    }
                                }) == 0
                            {
                                var restoredSource = stat()
                                var restoredDestination = stat()
                                if sourceName.withCString({
                                        fstatat(descriptor, $0, &restoredSource, AT_SYMLINK_NOFOLLOW)
                                    }) == 0,
                                    destination.childName.withCString({
                                        fstatat(
                                            destination.parentDescriptor, $0, &restoredDestination,
                                            AT_SYMLINK_NOFOLLOW)
                                    }) == 0,
                                    restoredSource.st_dev == sourceOpened.st_dev,
                                    restoredSource.st_ino == sourceOpened.st_ino,
                                    restoredDestination.st_dev == displacedOpened.st_dev,
                                    restoredDestination.st_ino == displacedOpened.st_ino
                                {
                                    cleanupSafe = true
                                }
                            }
                        }
                    }
                    throw CachePublicationRace("Binary cache content changed during refresh publication")
                }
            } else {
                guard publishedMatchesSource else {
                    cleanupSafe = false
                    throw CachePublicationRace("Binary cache content changed during refresh publication")
                }
            }
            try destination.verifyParent()
            try verifyIdentity()
        }

        func removeIfOwned() {
            guard cleanupSafe, (try? verifyIdentity()) != nil else { return }
            func expectedChildStillMatches() -> Bool {
                guard let cleanupExpectedChild else { return true }
                var opened = stat()
                var linked = stat()
                return fstat(cleanupExpectedChild.descriptor, &opened) == 0
                    && cleanupExpectedChild.name.withCString({
                        fstatat(descriptor, $0, &linked, AT_SYMLINK_NOFOLLOW)
                    }) == 0
                    && opened.st_dev == linked.st_dev && opened.st_ino == linked.st_ino
                    && SecureFileTree.isDirectory(opened) && SecureFileTree.isDirectory(linked)
                    && !SecureFileTree.isSymbolicLink(linked)
            }
            guard expectedChildStillMatches() else { return }

            // Move the exact retained staging inode to a fresh crash-residue name first. If a same-UID writer swaps the
            // old pathname in the check/rename window, the post-authentication fails and preserves what was moved; no
            // recursive delete begins until both the root and any displaced child match their retained descriptors.
            let prefix = name.hasPrefix(".refresh-") ? ".refresh-" : ".download-"
            let quarantineName = prefix + UUID().uuidString
            let renamed = name.withCString { sourcePointer in
                quarantineName.withCString { destinationPointer in
                    renameatx_np(
                        cacheRoot.descriptor, sourcePointer, cacheRoot.descriptor, destinationPointer,
                        UInt32(RENAME_EXCL))
                }
            }
            guard renamed == 0, (try? cacheRoot.verifyIdentity()) != nil else { return }
            var opened = stat()
            var linked = stat()
            guard fstat(descriptor, &opened) == 0,
                quarantineName.withCString({
                    fstatat(cacheRoot.descriptor, $0, &linked, AT_SYMLINK_NOFOLLOW)
                }) == 0,
                opened.st_dev == identity.device, opened.st_ino == identity.inode,
                linked.st_dev == identity.device, linked.st_ino == identity.inode,
                SecureFileTree.isDirectory(opened), SecureFileTree.isDirectory(linked),
                !SecureFileTree.isSymbolicLink(linked), expectedChildStillMatches()
            else { return }
            errno = 0
            var oldPath = stat()
            let oldResult = name.withCString {
                fstatat(cacheRoot.descriptor, $0, &oldPath, AT_SYMLINK_NOFOLLOW)
            }
            let oldProblem = errno
            guard oldResult != 0, oldProblem == ENOENT else { return }
            let quarantine = cacheRoot.url.appendingPathComponent(quarantineName, isDirectory: true)
            try? BinaryStore.removeCacheItem(quarantine, in: cacheRoot)
        }
    }

    var artifactIndexBuildCount: Int { artifactIndexes.buildCount }
    var chargedArtifactWorkForTesting: (entries: Int, bytes: Int64) { workBudget.usage }

    init(
        cache: URL, runner: CommandRunner, offline: Bool,
        downloader: (any BinaryDownloadClient)? = nil,
        maximumCacheBytes: Int64 = BinaryStore.defaultMaximumCacheBytes,
        maximumCacheEntries: Int = BinaryStore.defaultMaximumCacheEntries,
        minimumFreeSpaceReserveBytes: Int64 = BinaryStore.defaultMinimumFreeSpaceReserveBytes,
        cacheLockOperationHook: (@Sendable (String) -> Void)? = nil
    ) {
        // Released SwiftPods versions mutate checksum directories without the lock protocol used below. Keep the new
        // cache transaction in a private versioned namespace even for an explicitly configured cache root, so a rolling
        // upgrade cannot delete an active old staging directory or concurrently rebuild the same checksum entry.
        self.cache = Self.versionedCacheRoot(for: cache)
        self.runner = runner
        self.offline = offline
        self.downloader = downloader ?? PinnedCurlBinaryDownloadClient(runner: runner)
        self.maximumCacheBytes = maximumCacheBytes
        self.maximumCacheEntries = maximumCacheEntries
        self.minimumFreeSpaceReserveBytes = minimumFreeSpaceReserveBytes
        self.cacheLockOperationHook = cacheLockOperationHook
    }

    static var defaultCache: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SwiftPods/binaries", isDirectory: true)
    }

    static func versionedCacheRoot(for configured: URL) -> URL {
        configured.appendingPathComponent(cacheNamespaceName, isDirectory: true)
    }

    struct Contents {
        let xcframeworks: [URL]
        let resources: [URL]
        let xcframeworkPaths: [String]
        let resourcePaths: [String]
        /// Keeps the owned private snapshot alive through package rendering, including a memoized installer staging path.
        let snapshotLease: SnapshotLease?
    }

    final class SnapshotLease {
        let directory: URL
        init(_ directory: URL) { self.directory = directory }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    /// The `.xcframework` directories and resource bundles a binary provides.
    func contents(
        _ binary: Binary, podfileDirectory: URL, anchoredPodfileDirectory: Int32? = nil,
        snapshotDirectory: URL? = nil
    ) throws -> Contents {
        var root: URL
        let anchoredRoot = try anchoredPodfileDirectory.map(AnchoredDirectory.init(borrowing:))
        let podfileRoot = anchoredRoot == nil
            ? try SecureFileTree.resolvedDirectory(podfileDirectory, allowRootSymlink: true) : nil
        let automaticSnapshot = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftpods-binary-snapshot-" + UUID().uuidString, isDirectory: true)
        var snapshotLease: SnapshotLease?
        switch binary.source {
        case .local(let path):
            snapshotLease = snapshotDirectory == nil ? SnapshotLease(automaticSnapshot) : nil
            let declared = URL(fileURLWithPath: path, relativeTo: podfileDirectory).standardizedFileURL
            let anchoredDeclared: AnchoredOpenedPath?
            let resolvedDeclared: URL
            if let anchoredRoot {
                let components = try Self.anchoredComponents(
                    for: path, relativeTo: podfileDirectory, binary: binary)
                anchoredDeclared = try anchoredRoot.open(components, expectingDirectory: true)
                resolvedDeclared = anchoredDeclared!.url
            } else {
                anchoredDeclared = nil
                guard SecureFileTree.existsNoFollow(declared) else {
                    throw SwiftPodsError(
                        "Binary `\(binary.name)`: \(path) does not exist", file: binary.declaredAt.description)
                }
                // Resolve and contain the declared root before walking it. An escaping root link must not make SwiftPods
                // enumerate attacker-controlled files merely to discover that the root was outside the Podfile tree.
                resolvedDeclared = try SecureFileTree.resolvedDirectory(declared, allowRootSymlink: true)
                guard let podfileRoot,
                    SecureFileTree.contains(resolvedDeclared, in: podfileRoot, allowRoot: true)
                else {
                    throw SwiftPodsError(
                        "Binary `\(binary.name)`: \(path) resolves outside the Podfile directory",
                        file: binary.declaredAt.description)
                }
            }
            let validated = try SecureFileTree.validate(
                resolvedDeclared, allowRootSymlink: false, limits: .local, hashingContents: false)
            try anchoredDeclared?.verifyPathIdentity()
            // Count metadata traversal as work too. A repeated declaration cannot force an unbounded number of full scans.
            try workBudget.reserve(entries: validated.entries, bytes: 0, binary: binary)

            let sourceFrameworks: [URL]
            let sourceResources: [URL]
            let frameworkPaths: [String]
            let resourcePaths: [String]
            if declared.pathExtension == "xcframework" {
                guard binary.xcframeworks == nil, binary.resources.isEmpty else {
                    throw SwiftPodsError(
                        "Binary `\(binary.name)`: `xcframeworks` and `resources` need `path` to be a directory", file: binary.declaredAt.description)
                }
                sourceFrameworks = [validated.0]
                sourceResources = []
                frameworkPaths = [declared.lastPathComponent]
                resourcePaths = []
            } else {
                sourceResources = try locateIndexed(
                    binary.resources, in: validated.0, extension: "bundle", binary: binary)
                sourceFrameworks = try select(binary, in: validated.0)
                func stablePath(_ url: URL) -> String {
                    let relative = Paths.relative(from: validated.0, to: url)
                    return relative == "." ? url.lastPathComponent : relative
                }
                frameworkPaths = sourceFrameworks.map(stablePath)
                resourcePaths = sourceResources.map(stablePath)
            }

            // Local declarations can name the generated SwiftPods directory itself. Keep the authenticated copy
            // outside the source and copy only selected artifacts, never the potentially broad declared root.
            try selectionTracker.reserve(
                frameworks: sourceFrameworks, resources: sourceResources,
                binary: binary)
            let container = snapshotDirectory ?? automaticSnapshot
            let snapshotRoot = try prepareSnapshotContainer(container, outside: validated.0)
            do {
                let frameworks = try sourceFrameworks.enumerated().map { index, source in
                    try materializeSelectedArtifact(
                        source, named: (frameworkPaths[index] as NSString).lastPathComponent,
                        in: snapshotRoot.appendingPathComponent("frameworks/\(index)", isDirectory: true), binary: binary)
                }
                let resources = try sourceResources.enumerated().map { index, source in
                    try materializeSelectedArtifact(
                        source, named: (resourcePaths[index] as NSString).lastPathComponent,
                        in: snapshotRoot.appendingPathComponent("resources/\(index)", isDirectory: true), binary: binary)
                }
                try anchoredDeclared?.verifyPathIdentity()
                return Contents(
                    xcframeworks: frameworks, resources: resources,
                    xcframeworkPaths: frameworkPaths, resourcePaths: resourcePaths,
                    snapshotLease: snapshotLease)
            } catch {
                try? FileManager.default.removeItem(at: container)
                throw error
            }
        case .remote(let url, let sha256):
            guard Self.isValidSHA256(sha256) else {
                throw SwiftPodsError(
                    "Binary `\(binary.name)` has an invalid SHA-256 cache key", file: binary.declaredAt.description)
            }
            let source = try Self.remoteSource(
                url, podfileDirectory: podfileDirectory, podfileRoot: podfileRoot,
                anchoredRoot: anchoredRoot, binary: binary)
            // Reserve the identity before allocating memo state, keeping the memo table bounded to the same 64 SHAs.
            try workBudget.beginRemoteArchive(sha256: sha256, binary: binary)
            let snapshot = snapshotDirectory ?? automaticSnapshot.appendingPathComponent("content", isDirectory: true)
            // The memo owns even an installer-provided private path, rather than relying on incidental staging lifetime.
            let snapshotContainer = snapshotDirectory ?? automaticSnapshot
            let materialized = try remoteSnapshots.resolve(
                sha256,
                priorFailure: {
                    SwiftPodsError(
                        "Binary `\(binary.name)` could not be authenticated earlier in this install",
                        file: binary.declaredAt.description)
                }
            ) {
                // Only the elected loader owns this path. A cache-hit caller must never delete the leader's snapshot.
                let proposedLease = SnapshotLease(snapshotContainer)
                do {
                    return RemoteSnapshot(
                        root: try unpacked(
                            source: source, configuredURL: url, sha256: sha256, binary: binary, snapshot: snapshot),
                        lease: proposedLease)
                } catch {
                    try? FileManager.default.removeItem(at: snapshotContainer)
                    throw error
                }
            }
            root = materialized.root
            snapshotLease = materialized.lease
        }
        let resources = try locateIndexed(binary.resources, in: root, extension: "bundle", binary: binary)
        let frameworks = try select(binary, in: root)
        func stablePath(_ url: URL) -> String {
            let relative = Paths.relative(from: root, to: url)
            return relative == "." ? url.lastPathComponent : relative
        }
        let frameworkPaths = frameworks.map(stablePath)
        let resourcePaths = resources.map(stablePath)
        try selectionTracker.reserve(
            frameworks: frameworks, resources: resources,
            binary: binary)
        let frameworkSelections = frameworks.map { BinaryArtifactSelection($0, kind: .framework) }
        for resource in resources {
            let selection = BinaryArtifactSelection(resource, kind: .resource)
            guard frameworkSelections.contains(where: { selection.isNestedResource(of: $0) }) else { continue }
            // The archive inspection already charged the framework tree once. Its separately embedded resource is
            // copied and authenticated again, so charge that additional work too before package hashing/rendering.
            let extra = try SecureFileTree.validate(
                resource, allowRootSymlink: false, limits: .local, hashingContents: false)
            try workBudget.reserve(entries: extra.entries, bytes: extra.bytes, binary: binary)
        }
        return Contents(
            xcframeworks: frameworks, resources: resources,
            xcframeworkPaths: frameworkPaths, resourcePaths: resourcePaths,
            snapshotLease: snapshotLease)
    }

    /// Creates an owned container for selected local artifacts and proves it cannot recurse into their source root.
    private func prepareSnapshotContainer(_ container: URL, outside source: URL) throws -> URL {
        let candidate = container.standardizedFileURL.resolvingSymlinksInPath()
        guard !SecureFileTree.contains(candidate, in: source, allowRoot: true),
            !SecureFileTree.contains(source, in: candidate, allowRoot: true)
        else { throw SwiftPodsError("Private binary snapshot overlaps its local source: \(source.path)") }
        try FileManager.default.createDirectory(
            at: container.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard container.path.withCString({ mkdir($0, 0o700) }) == 0 else {
            throw SwiftPodsError(
                errno == EEXIST
                    ? "Private binary snapshot already exists: \(container.path)"
                    : "Cannot create a private binary snapshot: \(String(cString: strerror(errno)))")
        }
        do {
            let resolved = try SecureFileTree.resolvedDirectory(container, allowRootSymlink: false)
            let status = try SecureFileTree.statusNoFollow(resolved)
            guard status.st_uid == geteuid(), status.st_mode & 0o077 == 0,
                !SecureFileTree.contains(resolved, in: source, allowRoot: true),
                !SecureFileTree.contains(source, in: resolved, allowRoot: true)
            else { throw SwiftPodsError("Private binary snapshot is not an owned disjoint directory") }
            return resolved
        } catch {
            try? FileManager.default.removeItem(at: container)
            throw error
        }
    }

    /// Authenticates one selected artifact before and after copying it, preserving its declared basename for SwiftPM.
    private func materializeSelectedArtifact(
        _ source: URL, named name: String, in directory: URL, binary: Binary
    ) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
            name.utf8.count <= Int(NAME_MAX)
        else { throw SwiftPodsError("Local binary artifact has an unsafe output name: \(name)") }
        let inspection = try SecureFileTree.validate(
            source, allowRootSymlink: false, limits: .local, hashingContents: true,
            beforeHashingContents: { entries, bytes in
                try workBudget.reserve(entries: entries, bytes: bytes, binary: binary)
            }, normalizingPermissionsForDigest: true)
        let destination = directory.appendingPathComponent(name, isDirectory: true)
        return try materializeSnapshot(from: source, to: destination, expectedTree: inspection.1, limits: .local)
    }

    private func select(_ binary: Binary, in root: URL) throws -> [URL] {
        if let paths = binary.xcframeworks {
            return try locateIndexed(paths, in: root, extension: "xcframework", binary: binary)
        }
        let found = try indexedFind(root, extension: "xcframework", binary: binary)
        guard found.count <= Self.maximumSelectedArtifacts else {
            throw SwiftPodsError(
                "Binary `\(binary.name)` automatically selects more than \(Self.maximumSelectedArtifacts) .xcframework artifacts",
                file: binary.declaredAt.description,
                hint: "List only the required artifacts with `xcframeworks:`")
        }
        guard !found.isEmpty else {
            let legacy = try indexedFind(root, extension: "framework", binary: binary)
            throw SwiftPodsError(
                "Binary `\(binary.name)` contains no .xcframework", file: binary.declaredAt.description,
                hint: legacy.isEmpty ? nil : "It contains \(legacy.map(\.lastPathComponent).joined(separator: ", ")); "
                    + "wrap each with `xcodebuild -create-xcframework -framework …` and use `path:`")
        }
        return found
    }

    private func artifactIndex(in root: URL, binary: Binary) throws -> ArtifactIndex {
        let resolvedRoot = try SecureFileTree.resolvedDirectory(root, allowRootSymlink: false)
        return try artifactIndexes.resolve(root: resolvedRoot) {
            var enumerationError: Error?
            guard let enumerator = FileManager.default.enumerator(
                at: resolvedRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles],
                errorHandler: { _, error in enumerationError = error; return false })
            else { throw SwiftPodsError("Cannot enumerate binary tree \(resolvedRoot.path)") }
            let supported: Set<String> = ["xcframework", "framework", "bundle"]
            var found: [String: [URL]] = [:]
            var acceptedAncestors: [String: [URL]] = [:]
            var entries = 0
            for case let url as URL in enumerator {
                entries += 1
                guard entries <= SecureFileTree.Limits.local.entries else {
                    throw SwiftPodsError("Binary tree contains too many entries")
                }
                let relative = Paths.relative(from: resolvedRoot, to: url)
                guard relative.split(separator: "/", omittingEmptySubsequences: false).count
                    <= SecureFileTree.Limits.local.depth
                else { throw SwiftPodsError("Binary path is nested too deeply: \(relative)") }
                if url.lastPathComponent == "__MACOSX" {
                    enumerator.skipDescendants()
                    continue
                }
                let status = try SecureFileTree.statusNoFollow(url)
                if SecureFileTree.isSymbolicLink(status) {
                    enumerator.skipDescendants()
                    continue
                }
                for pathExtension in supported {
                    acceptedAncestors[pathExtension, default: []].removeAll {
                        !SecureFileTree.contains(url, in: $0)
                    }
                }
                let pathExtension = url.pathExtension.lowercased()
                if supported.contains(pathExtension), SecureFileTree.isDirectory(status),
                    acceptedAncestors[pathExtension, default: []].isEmpty
                {
                    let resolved = try SecureFileTree.realURL(url)
                    guard SecureFileTree.contains(resolved, in: resolvedRoot) else {
                        throw SwiftPodsError("Binary artifact escapes its root: \(relative)")
                    }
                    found[pathExtension, default: []].append(resolved)
                    acceptedAncestors[pathExtension, default: []].append(resolved)
                }
            }
            if let enumerationError { throw enumerationError }
            try workBudget.reserveScan(entries: entries, binary: binary)
            return ArtifactIndex(
                root: resolvedRoot,
                byExtension: found.mapValues { $0.sorted { $0.path < $1.path } }, entries: entries)
        }
    }

    private func indexedFind(_ root: URL, extension pathExtension: String, binary: Binary) throws -> [URL] {
        try artifactIndex(in: root, binary: binary).byExtension[pathExtension.lowercased()] ?? []
    }

    private func locateIndexed(
        _ paths: [String], in root: URL, extension pathExtension: String, binary: Binary
    ) throws -> [URL] {
        guard paths.count <= Self.maximumSelectedArtifacts else {
            throw SwiftPodsError(
                "Binary `\(binary.name)` selects more than \(Self.maximumSelectedArtifacts) .\(pathExtension) artifacts",
                file: binary.declaredAt.description)
        }
        guard Set(paths).count == paths.count else {
            throw SwiftPodsError(
                "Binary `\(binary.name)` selects the same .\(pathExtension) path more than once",
                file: binary.declaredAt.description)
        }
        let resolvedRoot = try SecureFileTree.resolvedDirectory(root, allowRootSymlink: false)
        let candidates = paths.contains(where: { !$0.contains("/") })
            ? try indexedFind(resolvedRoot, extension: pathExtension, binary: binary) : []
        let candidatesByName = Dictionary(grouping: candidates, by: \.lastPathComponent)
        func foundHint() -> String {
            let values = candidates.prefix(50).map { Paths.relative(from: resolvedRoot, to: $0) }
            return "Found: " + values.joined(separator: ", ") + (candidates.count > values.count ? ", …" : "")
        }
        var selected: [URL] = []
        var identities: Set<String> = []
        for path in paths {
            let resolved: URL
            if !path.contains("/") {
                let matches = candidatesByName[path] ?? []
                guard matches.count == 1 else {
                    throw SwiftPodsError(
                        matches.isEmpty ? "Binary `\(binary.name)` has no \(path)" : "Binary `\(binary.name)` has several \(path)",
                        file: binary.declaredAt.description, hint: foundHint())
                }
                resolved = matches[0]
            } else {
                let components = path.split(separator: "/", omittingEmptySubsequences: false)
                guard !path.hasPrefix("/"), !components.isEmpty,
                    components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
                else { throw SwiftPodsError("Binary `\(binary.name)`: unsafe path \(path)", file: binary.declaredAt.description) }
                let url = resolvedRoot.appendingPathComponent(path).standardizedFileURL
                guard url.pathExtension == pathExtension, SecureFileTree.contains(url, in: resolvedRoot),
                    SecureFileTree.existsNoFollow(url)
                else { throw SwiftPodsError("Binary `\(binary.name)` has no \(path)", file: binary.declaredAt.description) }
                let status = try SecureFileTree.statusNoFollow(url)
                guard !SecureFileTree.isSymbolicLink(status), SecureFileTree.isDirectory(status) else {
                    throw SwiftPodsError("Binary `\(binary.name)`: \(path) must be a real directory", file: binary.declaredAt.description)
                }
                resolved = try SecureFileTree.realURL(url)
                guard SecureFileTree.contains(resolved, in: resolvedRoot) else {
                    throw SwiftPodsError("Binary `\(binary.name)`: \(path) escapes the binary root", file: binary.declaredAt.description)
                }
            }
            guard identities.insert(resolved.standardizedFileURL.path).inserted else {
                throw SwiftPodsError(
                    "Binary `\(binary.name)` selects one .\(pathExtension) artifact more than once",
                    file: binary.declaredAt.description)
            }
            selected.append(resolved)
        }
        return selected
    }

    /// A path inside the archive, or a bare name found at any depth (archives often nest a versioned folder).
    static func locate(_ path: String, in root: URL, extension pathExtension: String, binary: Binary) throws -> URL {
        try locate([path], in: root, extension: pathExtension, binary: binary)[0]
    }

    /// Resolves an explicit selection with at most one tree scan, rejecting duplicate or impractically large lists.
    private static func locate(
        _ paths: [String], in root: URL, extension pathExtension: String, binary: Binary
    ) throws -> [URL] {
        guard paths.count <= maximumSelectedArtifacts else {
            throw SwiftPodsError(
                "Binary `\(binary.name)` selects more than \(maximumSelectedArtifacts) .\(pathExtension) artifacts",
                file: binary.declaredAt.description)
        }
        guard Set(paths).count == paths.count else {
            throw SwiftPodsError(
                "Binary `\(binary.name)` selects the same .\(pathExtension) path more than once",
                file: binary.declaredAt.description)
        }
        let resolvedRoot = try SecureFileTree.resolvedDirectory(root, allowRootSymlink: true)
        let candidates = paths.contains(where: { !$0.contains("/") })
            ? try find(resolvedRoot, extension: pathExtension) : []
        let candidatesByName = Dictionary(grouping: candidates, by: \.lastPathComponent)
        func foundHint() -> String {
            let values = candidates.prefix(50).map { Paths.relative(from: resolvedRoot, to: $0) }
            return "Found: " + values.joined(separator: ", ") + (candidates.count > values.count ? ", …" : "")
        }
        var selected: [URL] = []
        var identities: Set<String> = []
        for path in paths {
            let resolved: URL
            if !path.contains("/") {
                let matches = candidatesByName[path] ?? []
                guard matches.count == 1 else {
                    throw SwiftPodsError(
                        matches.isEmpty ? "Binary `\(binary.name)` has no \(path)" : "Binary `\(binary.name)` has several \(path)",
                        file: binary.declaredAt.description, hint: foundHint())
                }
                resolved = matches[0]
            } else {
                let components = path.split(separator: "/", omittingEmptySubsequences: false)
                guard !path.hasPrefix("/"), !components.isEmpty,
                    components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
                else { throw SwiftPodsError("Binary `\(binary.name)`: unsafe path \(path)", file: binary.declaredAt.description) }
                let url = resolvedRoot.appendingPathComponent(path).standardizedFileURL
                guard url.pathExtension == pathExtension, SecureFileTree.contains(url, in: resolvedRoot),
                    SecureFileTree.existsNoFollow(url)
                else { throw SwiftPodsError("Binary `\(binary.name)` has no \(path)", file: binary.declaredAt.description) }
                let status = try SecureFileTree.statusNoFollow(url)
                guard !SecureFileTree.isSymbolicLink(status), SecureFileTree.isDirectory(status) else {
                    throw SwiftPodsError("Binary `\(binary.name)`: \(path) must be a real directory", file: binary.declaredAt.description)
                }
                resolved = try SecureFileTree.realURL(url)
                guard SecureFileTree.contains(resolved, in: resolvedRoot) else {
                    throw SwiftPodsError("Binary `\(binary.name)`: \(path) escapes the binary root", file: binary.declaredAt.description)
                }
            }
            guard identities.insert(resolved.standardizedFileURL.path).inserted else {
                throw SwiftPodsError(
                    "Binary `\(binary.name)` selects one .\(pathExtension) artifact more than once",
                    file: binary.declaredAt.description)
            }
            selected.append(resolved)
        }
        return selected
    }

    /// Directories with the extension, not descending into matches.
    static func find(_ root: URL, extension pathExtension: String) throws -> [URL] {
        let resolvedRoot = try SecureFileTree.resolvedDirectory(root, allowRootSymlink: true)
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: resolvedRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles],
            errorHandler: { _, error in enumerationError = error; return false })
        else { throw SwiftPodsError("Cannot enumerate binary tree \(resolvedRoot.path)") }
        var result: [URL] = []
        var entries = 0
        for case let url as URL in enumerator {
            entries += 1
            guard entries <= SecureFileTree.Limits.local.entries else {
                throw SwiftPodsError("Binary tree contains too many entries")
            }
            let relative = Paths.relative(from: resolvedRoot, to: url)
            guard relative.split(separator: "/", omittingEmptySubsequences: false).count
                <= SecureFileTree.Limits.local.depth
            else { throw SwiftPodsError("Binary path is nested too deeply: \(relative)") }
            if url.lastPathComponent == "__MACOSX" {
                enumerator.skipDescendants()
            } else if let status = try? SecureFileTree.statusNoFollow(url), SecureFileTree.isSymbolicLink(status) {
                enumerator.skipDescendants()
            } else if url.pathExtension == pathExtension,
                let status = try? SecureFileTree.statusNoFollow(url), SecureFileTree.isDirectory(status),
                let resolved = try? SecureFileTree.realURL(url), SecureFileTree.contains(resolved, in: resolvedRoot)
            {
                result.append(resolved)
                enumerator.skipDescendants()
            }
        }
        if let enumerationError { throw enumerationError }
        return result.sorted { $0.path < $1.path }
    }

    private static func remoteSource(
        _ value: String, podfileDirectory: URL, podfileRoot: URL?, anchoredRoot: AnchoredDirectory?, binary: Binary
    ) throws -> RemoteSource {
        guard let components = URLComponents(string: value), let scheme = components.scheme?.lowercased(),
            let url = components.url
        else {
            throw SwiftPodsError(
                "Binary `\(binary.name)` has an invalid download URL", file: binary.declaredAt.description)
        }
        switch scheme {
        case "https":
            guard components.host?.isEmpty == false, components.user == nil, components.password == nil,
                components.fragment == nil
            else {
                throw SwiftPodsError(
                    "Binary `\(binary.name)` has an unsafe HTTPS download URL", file: binary.declaredAt.description)
            }
            return .https(url)
        case "file":
            // A file URL is an explicit local-source opt-in, but it is never authority to read arbitrary host files.
            // Resolve the final object before opening it and confine it to the Podfile root.
            guard url.isFileURL, components.user == nil, components.password == nil, components.query == nil,
                components.fragment == nil, components.port == nil,
                components.host == nil || components.host == "" || components.host?.lowercased() == "localhost"
            else {
                throw SwiftPodsError(
                    "Binary `\(binary.name)` has an unsafe local archive URL", file: binary.declaredAt.description)
            }
            let local = url.standardizedFileURL
            if let anchoredRoot {
                let components = try anchoredComponents(
                    for: local.path, relativeTo: podfileDirectory, binary: binary)
                guard !components.isEmpty else {
                    throw SwiftPodsError(
                        "Binary `\(binary.name)` local archive must be a regular file inside the Podfile directory",
                        file: binary.declaredAt.description)
                }
                // Opening remains deferred until a cache miss, preserving offline use of an authenticated cache.
                return .anchoredLocal(AnchoredPath(root: anchoredRoot, components: components))
            }
            guard let podfileRoot, SecureFileTree.contains(local, in: podfileRoot, allowRoot: false) else {
                throw SwiftPodsError(
                    "Binary `\(binary.name)` local archive must be a regular file inside the Podfile directory",
                    file: binary.declaredAt.description)
            }
            // Existence and final symlink resolution are intentionally deferred until a cache miss. --offline must be
            // able to consume an authenticated cache even when the original project-local archive is no longer present.
            return .local(local, podfileRoot: podfileRoot)
        default:
            throw SwiftPodsError(
                "Binary `\(binary.name)` download URL must use HTTPS, or an explicit file URL inside the Podfile directory",
                file: binary.declaredAt.description)
        }
    }

    private static func anchoredComponents(
        for path: String, relativeTo podfileDirectory: URL, binary: Binary
    ) throws -> [String] {
        let relative: String
        if path.hasPrefix("/") {
            let base = podfileDirectory.standardizedFileURL.path
            let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
            guard candidate != base, candidate.hasPrefix(base.hasSuffix("/") ? base : base + "/") else {
                throw SwiftPodsError(
                    "Binary `\(binary.name)` source is not lexically relative to the anchored Podfile directory",
                    file: binary.declaredAt.description)
            }
            relative = String(candidate.dropFirst(base.count + (base.hasSuffix("/") ? 0 : 1)))
        } else {
            relative = path
        }
        do {
            let components = try normalizedAnchoredComponents(
                relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init))
            guard !components.isEmpty else { throw SwiftPodsError("Anchored binary source path is empty") }
            return components
        } catch {
            throw SwiftPodsError(
                "Binary `\(binary.name)` has an unsafe anchored source path", file: binary.declaredAt.description)
        }
    }

    private static func normalizedAnchoredComponents(_ components: [String]) throws -> [String] {
        var result: [String] = []
        for component in components {
            if component.isEmpty || component == "." { continue }
            if component == ".." {
                guard !result.isEmpty else { throw SwiftPodsError("Anchored path escapes its root") }
                result.removeLast()
            } else {
                guard !component.contains("/"), !component.contains("\0"),
                    component.utf8.count <= Int(NAME_MAX)
                else { throw SwiftPodsError("Anchored path contains an unsafe component") }
                result.append(component)
                guard result.count <= SecureFileTree.Limits.local.depth else {
                    throw SwiftPodsError("Anchored path is nested too deeply")
                }
            }
        }
        return result
    }

    private func unpacked(
        source: RemoteSource, configuredURL: String, sha256: String, binary: Binary, snapshot: URL
    ) throws -> URL {
        guard Self.isValidSHA256(sha256) else {
            throw SwiftPodsError("Binary `\(binary.name)` has an invalid SHA-256 cache key", file: binary.declaredAt.description)
        }
        let cacheRoot = try Self.prepareCacheRoot(cache)
        let cacheURL = cacheRoot.url
        guard maximumCacheBytes > 0, maximumCacheEntries > 0, minimumFreeSpaceReserveBytes >= 0 else {
            throw SwiftPodsError("Binary cache and free-space limits must be positive")
        }
        return try withLock("global", in: cacheRoot) {
            try Self.reapCacheMaintenanceItems(in: cacheRoot)
            try Self.enforceCacheQuota(
                in: cacheRoot, maximumBytes: maximumCacheBytes,
                maximumEntries: maximumCacheEntries, preserving: sha256)
            return try withLock(sha256, in: cacheRoot) {
            let entry = cacheURL.appendingPathComponent(sha256, isDirectory: true)
            let content = entry.appendingPathComponent("content", isDirectory: true)
            let cachedArchive = entry.appendingPathComponent("archive")

            if SecureFileTree.existsNoFollow(entry) {
                let status = try SecureFileTree.statusNoFollow(entry)
                if !SecureFileTree.isDirectory(status) || SecureFileTree.isSymbolicLink(status) {
                    if offline {
                        throw SwiftPodsError(
                            "Binary `\(binary.name)` has an unsafe cache entry and --offline forbids replacing it",
                            file: binary.declaredAt.description)
                    }
                    try Self.removeCacheItem(entry, in: cacheRoot)
                }
            }

            if SecureFileTree.existsNoFollow(cachedArchive) {
                do {
                    let tree = try refresh(
                        content: content, from: cachedArchive, expectedSHA256: sha256, url: configuredURL,
                        cache: cacheRoot,
                        binary: binary)
                    try cacheRoot.verifyIdentity()
                    let result = try materializeSnapshot(
                        from: content, to: snapshot, expectedTree: tree, limits: .archive)
                    try cacheRoot.verifyIdentity()
                    Self.touchCacheEntry(sha256, in: cacheRoot)
                    return result
                } catch let error as CachePublicationRace {
                    throw SwiftPodsError(
                        "Binary `\(binary.name)` cache changed concurrently; refusing to remove or replace it: \(error)",
                        file: binary.declaredAt.description)
                } catch let error as WorkBudgetError {
                    throw error
                } catch {
                    guard !offline else {
                        throw SwiftPodsError(
                            "Binary `\(binary.name)` has an invalid cached archive and --offline forbids replacing it: \(error)",
                            file: binary.declaredAt.description)
                    }
                    try? Self.removeCacheItem(entry, in: cacheRoot)
                }
            } else if SecureFileTree.existsNoFollow(entry) {
                guard !offline else {
                    throw SwiftPodsError(
                        "Binary `\(binary.name)` uses a legacy cache entry without its verified archive; run once without --offline to migrate it",
                        file: binary.declaredAt.description)
                }
                try? Self.removeCacheItem(entry, in: cacheRoot)
            }

            guard !offline else {
                throw SwiftPodsError(
                    "Binary `\(binary.name)` is not cached and --offline forbids downloading it", file: binary.declaredAt.description)
            }
            let staging = try PreparedCacheStaging(prefix: ".download-", in: cacheRoot)
            defer { staging.removeIfOwned() }
            let archive = try staging.child("archive")
            var downloadedSize: Int64?
            switch source {
            case .anchoredLocal(let anchored):
                try staging.verifyIdentity()
                let localArchive = try anchored.openRegularFile()
                downloadedSize = try copyLocalArchive(
                    from: localArchive.descriptor, to: archive,
                    maximumBytes: Self.maximumArchiveBytes, binary: binary)
                try localArchive.verifyPathIdentity()
                try staging.verifyIdentity()
                try cacheRoot.verifyIdentity()
            case .local(let declaredArchive, let podfileRoot):
                let localArchive = try SecureFileTree.realURL(declaredArchive)
                guard SecureFileTree.contains(localArchive, in: podfileRoot, allowRoot: false),
                    SecureFileTree.isRegularFile(try SecureFileTree.statusNoFollow(localArchive))
                else {
                    throw SwiftPodsError(
                        "Binary `\(binary.name)` local archive must be a regular file inside the Podfile directory",
                        file: binary.declaredAt.description)
                }
                try staging.verifyIdentity()
                downloadedSize = try copyLocalArchive(
                    from: localArchive, to: archive, maximumBytes: Self.maximumArchiveBytes, binary: binary)
                try staging.verifyIdentity()
                try cacheRoot.verifyIdentity()
            case .https(let downloadURL):
                let started = DispatchTime.now().uptimeNanoseconds
                let duration = UInt64(Self.commandTimeout * 1_000_000_000)
                let deadline = started.addingReportingOverflow(duration).partialValue
                // The signed URL stays in an unlinked descriptor-backed curl config and never enters child-process argv.
                // Failed attempts retain their reservation; a successful attempt refunds its unused byte allowance.
                for attempt in 0..<4 {
                    guard let remaining = Self.remainingTime(before: deadline) else {
                        throw Self.downloadError(binary: binary, url: configuredURL)
                    }
                    let reservation = try workBudget.beginDownload(binary)
                    // The peer may omit Content-Length. Dynamically reduce this attempt's hard sink cap to the bytes
                    // currently available above the emergency reserve, rather than rejecting a small archive merely
                    // because the global four-GiB ceiling would not fit.
                    let transferLimit = min(
                        reservation.bytes, try availableBytesKeepingReserve(at: staging.url))
                    guard transferLimit > 0 else {
                        throw SwiftPodsError("Not enough free space to download binary artifacts")
                    }
                    try staging.verifyIdentity()
                    try? Self.removeCacheItem(archive, in: cacheRoot)
                    try staging.verifyIdentity()
                    do {
                        let result = try downloader.download(
                            from: downloadURL, to: archive, maximumBytes: transferLimit, timeout: remaining)
                        try staging.verifyIdentity()
                        try cacheRoot.verifyIdentity()
                        let status = try SecureFileTree.statusNoFollow(archive)
                        guard SecureFileTree.isRegularFile(status), status.st_size == result.storedBytes,
                            result.storedBytes >= 0, result.storedBytes <= transferLimit,
                            result.transferredBytes >= result.storedBytes,
                            result.transferredBytes <= transferLimit
                        else { throw BinaryDownloadFailure("Binary downloader produced an invalid archive file") }
                        try workBudget.finishDownload(
                            reservation, storedBytes: result.transferredBytes, binary: binary)
                        downloadedSize = result.storedBytes
                        break
                    } catch {
                        // Do not turn a cache-root replacement into a retryable transport error or follow its new path
                        // during cleanup.
                        try cacheRoot.verifyIdentity()
                        do { try staging.verifyIdentity() } catch { throw error }
                        try? Self.removeCacheItem(archive, in: cacheRoot)
                        if attempt < 3, (error as? BinaryDownloadFailure)?.transient == true,
                            Self.remainingTime(before: deadline) != nil
                        {
                            continue
                        }
                        throw Self.downloadError(binary: binary, url: configuredURL)
                    }
                }
            }
            guard let downloadedSize else {
                throw SwiftPodsError("Binary `\(binary.name)`: download did not produce an archive")
            }
            try staging.verifyIdentity()
            try workBudget.reserveArchive(bytes: downloadedSize, binary: binary)
            try cacheRoot.verifyIdentity()
            let actual = try Self.sha256(of: archive)
            try staging.verifyIdentity()
            try cacheRoot.verifyIdentity()
            guard actual == sha256 else {
                throw SwiftPodsError(
                    "Binary `\(binary.name)`: the archive does not match the Podfile SHA-256",
                    file: binary.declaredAt.description,
                    hint: "Verify the archive source and update `sha256` only after authenticating the new release")
            }
            let unpacked = try staging.child("content", isDirectory: true)
            let declared = try extract(
                archive: archive, configuredURL: configuredURL, expectedSHA256: sha256,
                into: unpacked, binary: binary)
            try staging.verifyIdentity()
            try cacheRoot.verifyIdentity()
            let inspection = try SecureFileTree.validate(
                unpacked, allowRootSymlink: false, limits: .archive, hashingContents: true,
                beforeHashingContents: { entries, bytes in
                    try Self.validateExtractedArchiveCounts(
                        declaredEntries: declared.entries, declaredBytes: declared.bytes,
                        actualEntries: entries, actualBytes: bytes)
                }, normalizingPermissionsForDigest: true)
            let tree = inspection.1
            try staging.verifyIdentity()
            try cacheRoot.verifyIdentity()
            try Data("cache-v2\narchive \(sha256)\ntree \(tree)\n".utf8)
                .write(to: try staging.child(".complete"), options: .withoutOverwriting)
            try staging.verifyIdentity()
            try cacheRoot.verifyIdentity()
            try SecureFileTree.normalizePermissions(in: staging.url)
            try staging.verifyIdentity()
            try cacheRoot.verifyIdentity()
            try Self.enforceCacheQuota(
                in: cacheRoot, maximumBytes: maximumCacheBytes,
                maximumEntries: maximumCacheEntries, preserving: sha256)
            try staging.verifyIdentity()
            try staging.publish(as: sha256)
            let result = try materializeSnapshot(from: content, to: snapshot, expectedTree: tree, limits: .archive)
            try cacheRoot.verifyIdentity()
            Self.touchCacheEntry(sha256, in: cacheRoot)
            return result
            }
        }
    }

    private static func isValidSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// Creates only missing cache path components through already-open directory descriptors. Existing components are
    /// validated and never recursively chmod'ed: a concurrent final symlink therefore cannot redirect permission
    /// normalization into an unrelated tree. An explicitly configured cache-root symlink remains supported by resolving
    /// it once and continuing solely with the canonical target.
    private static func prepareCacheRoot(_ configured: URL) throws -> PreparedCacheRoot {
        let requested = configured.standardized
        guard requested.path.hasPrefix("/"), requested.path != "/" else {
            throw SwiftPodsError("Binary cache must use a non-root absolute path")
        }

        var existing = requested
        var components: [String] = []
        while true {
            var status = stat()
            if existing.path.withCString({ lstat($0, &status) }) == 0 { break }
            let problem = errno
            guard problem == ENOENT || problem == ENOTDIR else {
                throw SwiftPodsError("Cannot inspect binary cache path: \(String(cString: strerror(problem)))")
            }
            let component = existing.lastPathComponent
            guard !component.isEmpty, component != ".", component != "..", !component.contains("/") else {
                throw SwiftPodsError("Binary cache contains an unsafe path component")
            }
            components.insert(component, at: 0)
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else { throw SwiftPodsError("Cannot locate a binary cache parent") }
            existing = parent
        }

        // Authenticate the path exactly as configured before resolving any symlink. Otherwise an unsafe
        // world-writable lexical ancestor could be hidden by a link into an otherwise trusted canonical tree.
        try validateLexicalCacheAncestors(existing)
        let canonicalParent = try canonicalCacheDirectoryURL(existing)
        var currentURL = canonicalParent
        var descriptor = canonicalParent.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw SwiftPodsError("Cannot securely open binary cache parent: \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }

        if components.isEmpty {
            try validateCacheDirectoryDescriptor(descriptor, path: canonicalParent.path)
        }
        for component in components {
            let created: Bool
            if component.withCString({ mkdirat(descriptor, $0, 0o700) }) == 0 {
                created = true
            } else {
                let problem = errno
                guard problem == EEXIST else {
                    throw SwiftPodsError("Cannot create binary cache directory: \(String(cString: strerror(problem)))")
                }
                created = false
            }
            let child = component.withCString {
                openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard child >= 0 else {
                throw SwiftPodsError("Binary cache path contains a replaced or unsafe directory")
            }
            close(descriptor)
            descriptor = child
            currentURL.appendPathComponent(component, isDirectory: true)
            if created {
                try secureNewCacheDirectoryDescriptor(descriptor, path: currentURL.path)
            } else {
                try validateCacheDirectoryDescriptor(descriptor, path: currentURL.path)
            }
        }
        try validateCacheDirectoryDescriptor(descriptor, path: currentURL.path)
        try validateCacheAncestorPermissions(currentURL)
        return try PreparedCacheRoot(url: currentURL, descriptor: descriptor)
    }

    /// A writable non-sticky ancestor lets another local account rename the authenticated cache path. Sticky shared
    /// roots such as `/tmp` remain supported because they forbid removing another user's owned child.
    private static func validateCacheAncestorPermissions(_ cacheRoot: URL) throws {
        guard let pointer = cacheRoot.path.withCString({ realpath($0, nil) }) else {
            throw SwiftPodsError("Cannot canonicalize binary cache ancestors")
        }
        defer { free(pointer) }
        let canonicalPath = String(cString: pointer)
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw SwiftPodsError("Cannot inspect binary cache ancestors") }
        defer { close(descriptor) }

        try validateCacheAncestorDescriptor(descriptor, path: "/")
        var path = ""
        for component in (canonicalPath as NSString).pathComponents.dropFirst() {
            guard !component.isEmpty, component != ".", component != "..", !component.contains("/") else {
                throw SwiftPodsError("Binary cache contains an unsafe ancestor component")
            }
            let next = component.withCString {
                openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard next >= 0 else {
                throw SwiftPodsError(
                    "Cannot safely open binary cache ancestor \(path)/\(component): \(String(cString: strerror(errno)))")
            }
            close(descriptor)
            descriptor = next
            path += "/" + component
            try validateCacheAncestorDescriptor(descriptor, path: path)
        }
    }

    /// Validates the original lexical path before `realpath` is allowed to erase it. Every symlink target is folded
    /// back into the remaining lexical path and validated again, so a trusted first link cannot hide a later link
    /// below an unsafe directory. The bounded traversal also rejects link cycles.
    private static func validateLexicalCacheAncestors(_ existing: URL) throws {
        try validateLexicalCacheAncestors(existing, symlinkDepth: 0)
    }

    private static func validateLexicalCacheAncestors(_ existing: URL, symlinkDepth: Int) throws {
        guard symlinkDepth <= 64 else { throw SwiftPodsError("Binary cache path contains too many symbolic links") }
        let path = existing.standardized.path
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw SwiftPodsError("Cannot inspect binary cache ancestors") }
        defer { close(descriptor) }

        try validateCacheAncestorDescriptor(descriptor, path: "/")
        var traversed = ""
        let components = Array((path as NSString).pathComponents.dropFirst())
        for (index, component) in components.enumerated() {
            guard !component.isEmpty, component != ".", component != "..", !component.contains("/") else {
                throw SwiftPodsError("Binary cache contains an unsafe ancestor component")
            }
            var linked = stat()
            guard component.withCString({
                fstatat(descriptor, $0, &linked, AT_SYMLINK_NOFOLLOW)
            }) == 0 else {
                throw SwiftPodsError(
                    "Cannot safely inspect binary cache ancestor \(traversed)/\(component): "
                        + String(cString: strerror(errno)))
            }
            let linkedPath = traversed + "/" + component
            if SecureFileTree.isSymbolicLink(linked) {
                guard linked.st_uid == 0 || linked.st_uid == geteuid() else {
                    throw SwiftPodsError(
                        "Binary cache path contains a symbolic link owned by an untrusted account: \(linkedPath)")
                }
                var targetBuffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let length = component.withCString { componentPointer in
                    targetBuffer.withUnsafeMutableBufferPointer { buffer in
                        readlinkat(descriptor, componentPointer, buffer.baseAddress, buffer.count)
                    }
                }
                guard length > 0, length < targetBuffer.count,
                    let target = String(
                        bytes: targetBuffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, encoding: .utf8)
                else { throw SwiftPodsError("Cannot safely read binary cache symbolic link: \(linkedPath)") }
                var rechecked = stat()
                guard component.withCString({
                    fstatat(descriptor, $0, &rechecked, AT_SYMLINK_NOFOLLOW)
                }) == 0, SecureFileTree.isSymbolicLink(rechecked),
                    rechecked.st_dev == linked.st_dev, rechecked.st_ino == linked.st_ino
                else { throw SwiftPodsError("Binary cache symbolic link changed while it was inspected") }

                let parentPath = traversed.isEmpty ? "/" : traversed
                var redirected = target.hasPrefix("/")
                    ? target : (parentPath as NSString).appendingPathComponent(target)
                for remainder in components.dropFirst(index + 1) {
                    redirected = (redirected as NSString).appendingPathComponent(remainder)
                }
                redirected = URL(fileURLWithPath: redirected, isDirectory: true).standardized.path
                guard redirected.hasPrefix("/") else {
                    throw SwiftPodsError("Binary cache symbolic link has an unsafe target")
                }
                try validateLexicalCacheAncestors(
                    URL(fileURLWithPath: redirected, isDirectory: true), symlinkDepth: symlinkDepth + 1)
                return
            }
            guard SecureFileTree.isDirectory(linked) else {
                throw SwiftPodsError("Binary cache ancestor is not a directory: \(linkedPath)")
            }
            let next = component.withCString {
                openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard next >= 0 else {
                throw SwiftPodsError(
                    "Cannot safely open binary cache ancestor \(linkedPath): \(String(cString: strerror(errno)))")
            }
            var opened = stat()
            guard fstat(next, &opened) == 0, SecureFileTree.isDirectory(opened),
                opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino
            else {
                close(next)
                throw SwiftPodsError("Binary cache ancestor changed while it was opened: \(linkedPath)")
            }
            close(descriptor)
            descriptor = next
            traversed = linkedPath
            try validateCacheAncestorDescriptor(descriptor, path: traversed)
        }
    }

    private static func canonicalCacheDirectoryURL(_ directory: URL) throws -> URL {
        guard let pointer = directory.path.withCString({ realpath($0, nil) }) else {
            throw SwiftPodsError("Cannot canonicalize binary cache path")
        }
        defer { free(pointer) }
        return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
    }

    private static func validateCacheAncestorDescriptor(_ descriptor: Int32, path: String) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0, SecureFileTree.isDirectory(status) else {
            throw SwiftPodsError("Cannot inspect binary cache ancestor: \(path)")
        }
        guard status.st_uid == 0 || status.st_uid == geteuid() else {
            throw SwiftPodsError("Binary cache is below a directory owned by an untrusted account: \(path)")
        }
        guard try !descriptorHasAllowACL(descriptor) else {
            throw SwiftPodsError("Binary cache ancestor grants access through an extended ACL: \(path)")
        }
        let isWritableByOthers = status.st_mode & 0o022 != 0
        let isSticky = status.st_mode & mode_t(S_ISVTX) != 0
        let hasTrustedStickyOwner = isSticky && (status.st_uid == 0 || status.st_uid == geteuid())
        guard !isWritableByOthers || hasTrustedStickyOwner else {
            throw SwiftPodsError(
                "Binary cache is below a group- or world-writable non-sticky directory: \(path)")
        }
    }

    /// Standard macOS home directories commonly carry `everyone deny delete`; deny-only ACLs make ancestry stricter
    /// and remain compatible. Any allow entry is rejected because its qualifier may be another local account.
    private static func descriptorHasAllowACL(_ descriptor: Int32) throws -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT || errno == ENOTSUP || errno == EOPNOTSUPP { return false }
            throw SwiftPodsError("Cannot inspect binary cache ancestor access controls")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var selector = Int32(ACL_FIRST_ENTRY.rawValue)
        var readEntry = false
        while true {
            var entry: acl_entry_t?
            errno = 0
            let result = acl_get_entry(acl, selector, &entry)
            let failure = errno
            if result != 0, readEntry, selector == Int32(ACL_NEXT_ENTRY.rawValue), failure == EINVAL {
                return false
            }
            guard result == 0 else {
                throw SwiftPodsError("Cannot inspect binary cache ancestor access controls")
            }
            guard let entry else { return false }
            readEntry = true
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0 else {
                throw SwiftPodsError("Cannot inspect binary cache ancestor access controls")
            }
            if tag == ACL_EXTENDED_ALLOW { return true }
            selector = Int32(ACL_NEXT_ENTRY.rawValue)
        }
    }

    private static func secureNewCacheDirectoryDescriptor(_ descriptor: Int32, path: String) throws {
        guard fchmod(descriptor, 0o700) == 0, let emptyACL = acl_init(0) else {
            throw SwiftPodsError("Cannot secure new binary cache directory at \(path)")
        }
        let aclResult = acl_set_fd_np(descriptor, emptyACL, ACL_TYPE_EXTENDED)
        let aclError = errno
        acl_free(UnsafeMutableRawPointer(emptyACL))
        guard aclResult == 0 || aclError == ENOTSUP || aclError == EOPNOTSUPP else {
            throw SwiftPodsError("Cannot secure new binary cache directory at \(path)")
        }
        try validateCacheDirectoryDescriptor(descriptor, path: path)
    }

    private static func validateCacheDirectoryDescriptor(_ descriptor: Int32, path: String) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0, SecureFileTree.isDirectory(status), status.st_uid == geteuid(),
            status.st_mode & 0o022 == 0, try !descriptorHasExtendedACL(descriptor)
        else {
            throw SwiftPodsError(
                "Binary cache must be owned by the current user and not writable by group or others: \(path)")
        }
    }

    private static func descriptorHasExtendedACL(_ descriptor: Int32) throws -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT || errno == ENOTSUP || errno == EOPNOTSUPP { return false }
            throw SwiftPodsError("Cannot inspect binary cache access controls: \(String(cString: strerror(errno)))")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
        guard result == 0 else {
            throw SwiftPodsError("Cannot inspect binary cache access controls: \(String(cString: strerror(errno)))")
        }
        return entry != nil
    }

    /// Enumerates the retained cache-root descriptor instead of reopening its pathname. The explicit ceiling keeps a
    /// same-user or previously compromised cache from turning quota maintenance into an unbounded allocation or scan.
    private static func cacheRootEntryNames(in cacheRoot: PreparedCacheRoot) throws -> [String] {
        try cacheRoot.verifyIdentity()
        // dup(2) would share the retained descriptor's directory offset; a second scan could therefore start at EOF.
        // openat(".") creates an independently positioned stream while remaining anchored to the retained inode.
        let streamDescriptor = ".".withCString {
            openat(
                cacheRoot.descriptor, $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard streamDescriptor >= 0 else { throw SwiftPodsError("Cannot inspect binary cache entries") }
        guard let directory = fdopendir(streamDescriptor) else {
            let problem = errno
            close(streamDescriptor)
            throw SwiftPodsError("Cannot inspect binary cache entries: \(String(cString: strerror(problem)))")
        }
        defer { closedir(directory) }

        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                let problem = errno
                guard problem == 0 else {
                    throw SwiftPodsError(
                        "Cannot inspect binary cache entries: \(String(cString: strerror(problem)))")
                }
                break
            }
            let length = Int(entry.pointee.d_namlen)
            guard length > 0, length <= Int(NAME_MAX) else {
                throw SwiftPodsError("Binary cache contains an invalid entry name")
            }
            let bytes = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: UInt8.self, capacity: length) {
                    Array(UnsafeBufferPointer(start: $0, count: length))
                }
            }
            guard let name = String(bytes: bytes, encoding: .utf8), name != ".", name != "..",
                !name.contains("/"), !name.contains("\0")
            else {
                if length == 1, bytes == [UInt8(ascii: ".")] { continue }
                if length == 2, bytes == [UInt8(ascii: "."), UInt8(ascii: ".")] { continue }
                throw SwiftPodsError("Binary cache contains an invalid UTF-8 entry name")
            }
            names.append(name)
            guard names.count <= maximumCacheRootEntries else {
                throw SwiftPodsError(
                    "Binary cache root contains more than \(maximumCacheRootEntries) entries",
                    hint: "Remove unknown cache files before retrying")
            }
        }
        try cacheRoot.verifyIdentity()
        return names
    }

    private static func crashResidueKind(_ name: String) -> Bool {
        let prefixes = [".download-", ".refresh-"]
        guard let prefix = prefixes.first(where: { name.hasPrefix($0) }) else { return false }
        let suffix = String(name.dropFirst(prefix.count))
        guard suffix.utf8.count == 36, let identifier = UUID(uuidString: suffix) else { return false }
        return identifier.uuidString.caseInsensitiveCompare(suffix) == .orderedSame
    }

    /// A prior process can die after creating a private staging directory or an old per-SHA lock. Maintenance happens
    /// only while holding the global lock. Unknown names and objects that fail no-follow ownership/type validation are
    /// deliberately retained and remain visible to quota accounting.
    private static func reapCacheMaintenanceItems(in cacheRoot: PreparedCacheRoot) throws {
        for name in try cacheRootEntryNames(in: cacheRoot) {
            if crashResidueKind(name) {
                let descriptor = name.withCString {
                    openat(
                        cacheRoot.descriptor, $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                }
                guard descriptor >= 0 else { continue }
                defer { close(descriptor) }
                var opened = stat()
                var linked = stat()
                let valid = try fstat(descriptor, &opened) == 0
                    && name.withCString({
                        fstatat(cacheRoot.descriptor, $0, &linked, AT_SYMLINK_NOFOLLOW)
                    }) == 0
                    && opened.st_dev == linked.st_dev && opened.st_ino == linked.st_ino
                    && SecureFileTree.isDirectory(opened) && SecureFileTree.isDirectory(linked)
                    && opened.st_uid == geteuid() && opened.st_mode & 0o022 == 0
                    && (try !descriptorHasExtendedACL(descriptor))
                guard valid else { continue }
                let residue = cacheRoot.url.appendingPathComponent(name, isDirectory: true)
                let cleanupLimits = SecureFileTree.Limits(
                    entries: SecureFileTree.Limits.archive.entries,
                    bytes: SecureFileTree.Limits.archive.bytes + maximumArchiveBytes,
                    depth: SecureFileTree.Limits.archive.depth,
                    internalHardlinksOnly: true)
                guard (try? SecureFileTree.validate(
                    residue, allowRootSymlink: false, limits: cleanupLimits, hashingContents: false)) != nil
                else { continue }
                try removeCacheItem(residue, in: cacheRoot)
                continue
            }

            let legacyPrefix = ".lock-"
            let legacySHA = name.hasPrefix(legacyPrefix) ? String(name.dropFirst(legacyPrefix.count)) : ""
            guard isValidSHA256(legacySHA) else { continue }
            let descriptor = name.withCString {
                openat(cacheRoot.descriptor, $0, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            var opened = stat()
            var linked = stat()
            guard fstat(descriptor, &opened) == 0,
                name.withCString({ fstatat(cacheRoot.descriptor, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
                opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino,
                SecureFileTree.isRegularFile(opened), SecureFileTree.isRegularFile(linked),
                opened.st_uid == geteuid(), opened.st_nlink == 1, opened.st_mode & 0o022 == 0,
                try !descriptorHasExtendedACL(descriptor), flock(descriptor, LOCK_EX | LOCK_NB) == 0
            else { continue }
            defer { flock(descriptor, LOCK_UN) }
            try cacheRoot.verifyIdentity()
            guard name.withCString({ unlinkat(cacheRoot.descriptor, $0, 0) }) == 0 else {
                throw SwiftPodsError("Cannot remove a legacy binary cache lock")
            }
            try cacheRoot.verifyIdentity()
        }
    }

    /// The current checksum cannot be exempted from quota merely because an attacker or interrupted run chose its
    /// 64-hex name. Preserve only an owned completed directory whose pinned archive actually hashes to that name.
    private static func removeInvalidCurrentCacheEntry(_ name: String, in cacheRoot: PreparedCacheRoot) throws {
        guard isValidSHA256(name) else { throw SwiftPodsError("Invalid binary cache checksum") }
        var linked = stat()
        let lookup = name.withCString { fstatat(cacheRoot.descriptor, $0, &linked, AT_SYMLINK_NOFOLLOW) }
        if lookup != 0 {
            guard errno == ENOENT else { throw SwiftPodsError("Cannot inspect the current binary cache entry") }
            return
        }

        let descriptor = name.withCString {
            openat(
                cacheRoot.descriptor, $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        var valid = false
        if descriptor >= 0 {
            defer { close(descriptor) }
            var opened = stat()
            valid = try fstat(descriptor, &opened) == 0
                && opened.st_dev == linked.st_dev && opened.st_ino == linked.st_ino
                && SecureFileTree.isDirectory(opened) && SecureFileTree.isDirectory(linked)
                && opened.st_uid == geteuid() && opened.st_mode & 0o022 == 0
                && (try !descriptorHasExtendedACL(descriptor))
                && (try completedCacheMarkerMatches(name, in: descriptor))
                && (try cachedArchiveSHA256(in: descriptor) == name)
        }
        guard !valid else { return }
        try removeCacheItem(cacheRoot.url.appendingPathComponent(name), in: cacheRoot)
    }

    private static func completedCacheMarkerMatches(_ sha256: String, in entryDescriptor: Int32) throws -> Bool {
        let descriptor = ".complete".withCString {
            openat(entryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var initial = stat()
        var linked = stat()
        guard fstat(descriptor, &initial) == 0, SecureFileTree.isRegularFile(initial),
            initial.st_uid == geteuid(), initial.st_nlink == 1, initial.st_size > 0, initial.st_size <= 512,
            ".complete".withCString({
                fstatat(entryDescriptor, $0, &linked, AT_SYMLINK_NOFOLLOW)
            }) == 0,
            initial.st_dev == linked.st_dev, initial.st_ino == linked.st_ino
        else { return false }
        var data = Data(count: Int(initial.st_size))
        var offset = 0
        while offset < data.count {
            let requested = data.count - offset
            let count = data.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), requested)
            }
            if count > 0 { offset += count; continue }
            if count < 0, errno == EINTR { continue }
            return false
        }
        var extra: UInt8 = 0
        let extraCount = readOneByte(descriptor, into: &extra)
        var final = stat()
        var finalLinked = stat()
        guard extraCount == 0, fstat(descriptor, &final) == 0,
            ".complete".withCString({
                fstatat(entryDescriptor, $0, &finalLinked, AT_SYMLINK_NOFOLLOW)
            }) == 0,
            initial.st_dev == final.st_dev, initial.st_ino == final.st_ino,
            initial.st_dev == finalLinked.st_dev, initial.st_ino == finalLinked.st_ino,
            initial.st_mode == final.st_mode, initial.st_nlink == final.st_nlink,
            initial.st_size == final.st_size,
            initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec,
            initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec,
            initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec,
            initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec,
            let marker = String(data: data, encoding: .utf8)
        else { return false }
        let lines = marker.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count == 4, lines[0] == "cache-v2", lines[1] == "archive \(sha256)",
            lines[2].hasPrefix("tree "), lines[3].isEmpty
        else { return false }
        return isValidSHA256(String(lines[2].dropFirst("tree ".count)))
    }

    private static func cachedArchiveSHA256(in entryDescriptor: Int32) throws -> String? {
        let descriptor = "archive".withCString {
            openat(entryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var initial = stat()
        var linked = stat()
        guard fstat(descriptor, &initial) == 0, SecureFileTree.isRegularFile(initial),
            initial.st_uid == geteuid(), initial.st_nlink == 1,
            initial.st_size >= 0, initial.st_size <= maximumArchiveBytes,
            "archive".withCString({ fstatat(entryDescriptor, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
            initial.st_dev == linked.st_dev, initial.st_ino == linked.st_ino
        else { return nil }

        var hasher = SHA256()
        var remaining = initial.st_size
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while remaining > 0 {
            let requested = min(buffer.count, Int(remaining))
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress!, requested)
            }
            if count > 0 {
                hasher.update(data: Data(buffer[..<count]))
                remaining -= Int64(count)
                continue
            }
            if count < 0, errno == EINTR { continue }
            return nil
        }
        var extra: UInt8 = 0
        let extraCount = readOneByte(descriptor, into: &extra)
        var final = stat()
        var finalLinked = stat()
        guard extraCount == 0, fstat(descriptor, &final) == 0,
            "archive".withCString({
                fstatat(entryDescriptor, $0, &finalLinked, AT_SYMLINK_NOFOLLOW)
            }) == 0,
            initial.st_dev == final.st_dev, initial.st_ino == final.st_ino,
            initial.st_dev == finalLinked.st_dev, initial.st_ino == finalLinked.st_ino,
            initial.st_mode == final.st_mode, initial.st_nlink == final.st_nlink,
            initial.st_size == final.st_size,
            initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec,
            initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec,
            initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec,
            initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec
        else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func readOneByte(_ descriptor: Int32, into byte: inout UInt8) -> Int {
        while true {
            let count = Darwin.read(descriptor, &byte, 1)
            if count < 0, errno == EINTR { continue }
            return count
        }
    }

    struct CacheUsage: Equatable {
        let bytes: Int64
        let entries: Int
    }

    /// Returns a conservative cache size used for quota enforcement. Symlinks are accounted without being followed;
    /// special files fail closed rather than being silently omitted.
    static func cacheUsage(at cacheRoot: URL) throws -> CacheUsage {
        let root = try SecureFileTree.resolvedDirectory(cacheRoot, allowRootSymlink: false)
        let started = DispatchTime.now().uptimeNanoseconds
        let duration = UInt64(cacheScanTimeout * 1_000_000_000)
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [],
            errorHandler: { _, error in enumerationError = error; return false })
        else { throw SwiftPodsError("Cannot inspect binary cache usage") }
        var entries = 0
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            entries += 1
            guard entries <= maximumCacheScanEntries else {
                throw SwiftPodsError("Binary cache contains too many filesystem entries")
            }
            guard enumerator.level <= maximumCacheScanDepth else {
                enumerator.skipDescendants()
                throw SwiftPodsError("Binary cache exceeds its directory-depth limit")
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds.subtractingReportingOverflow(started)
            guard !elapsed.overflow, elapsed.partialValue <= duration else {
                throw SwiftPodsError("Binary cache inspection exceeded its time limit")
            }
            let status = try SecureFileTree.statusNoFollow(url)
            let objectBytes = try cacheObjectBytes(status)
            if SecureFileTree.isSymbolicLink(status) {
                enumerator.skipDescendants()
                guard bytes <= Int64.max - objectBytes else {
                    throw SwiftPodsError("Binary cache contains an oversized symbolic link")
                }
                bytes += objectBytes
                continue
            }
            guard SecureFileTree.isDirectory(status) || SecureFileTree.isRegularFile(status),
                bytes <= Int64.max - objectBytes
            else {
                throw SwiftPodsError("Binary cache contains a special or oversized file")
            }
            bytes += objectBytes
        }
        if let enumerationError { throw enumerationError }
        return CacheUsage(bytes: bytes, entries: entries)
    }

    private static func cacheObjectBytes(_ status: stat) throws -> Int64 {
        let allocated = status.st_blocks.multipliedReportingOverflow(by: 512)
        guard status.st_size >= 0, status.st_blocks >= 0, !allocated.overflow else {
            throw SwiftPodsError("Binary cache contains an oversized filesystem object")
        }
        return max(status.st_size, allocated.partialValue)
    }

    private struct CacheCandidate {
        let url: URL
        let bytes: Int64
        let entries: Int
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
    }

    /// Enforces a persistent cache-wide quota under the global cache lock. Only complete checksum-named entries are
    /// eviction candidates; unknown files remain accounted but are never destructively guessed at.
    private static func enforceCacheQuota(
        in cacheRoot: PreparedCacheRoot, maximumBytes: Int64, maximumEntries: Int, preserving: String
    ) throws {
        guard maximumBytes > 0, maximumEntries > 0 else {
            throw SwiftPodsError("Binary cache quotas must be positive")
        }
        try cacheRoot.verifyIdentity()
        var usage = try cacheUsage(at: cacheRoot.url)
        try cacheRoot.verifyIdentity()
        guard usage.bytes > maximumBytes || usage.entries > maximumEntries else { return }

        // Do not exempt an entry solely because its attacker-controlled name equals the requested checksum. Verify the
        // completed archive before treating it as current; an invalid entry is removed before candidate selection.
        try removeInvalidCurrentCacheEntry(preserving, in: cacheRoot)
        usage = try cacheUsage(at: cacheRoot.url)
        try cacheRoot.verifyIdentity()
        guard usage.bytes > maximumBytes || usage.entries > maximumEntries else { return }

        var candidates: [CacheCandidate] = []
        for name in try cacheRootEntryNames(in: cacheRoot) where name != preserving && isValidSHA256(name) {
            guard candidates.count < maximumCacheQuotaCandidates else {
                throw SwiftPodsError(
                    "Binary cache has more than \(maximumCacheQuotaCandidates) eviction candidates",
                    hint: "Remove obsolete cache entries before retrying")
            }
            let child = cacheRoot.url.appendingPathComponent(name, isDirectory: true)
            let status = try SecureFileTree.statusNoFollow(child)
            guard SecureFileTree.isDirectory(status), !SecureFileTree.isSymbolicLink(status) else { continue }
            let marker = child.appendingPathComponent(".complete")
            guard SecureFileTree.existsNoFollow(marker),
                SecureFileTree.isRegularFile(try SecureFileTree.statusNoFollow(marker))
            else { continue }
            let candidateUsage = try cacheUsage(at: child)
            try cacheRoot.verifyIdentity()
            let candidateBytes = candidateUsage.bytes.addingReportingOverflow(try cacheObjectBytes(status))
            let candidateEntries = candidateUsage.entries.addingReportingOverflow(1)
            guard !candidateBytes.overflow, !candidateEntries.overflow else {
                throw SwiftPodsError("Binary cache entry is too large")
            }
            candidates.append(CacheCandidate(
                url: child, bytes: candidateBytes.partialValue, entries: candidateEntries.partialValue,
                modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
                modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec)))
        }
        candidates.sort {
            ($0.modifiedSeconds, $0.modifiedNanoseconds, $0.url.lastPathComponent)
                < ($1.modifiedSeconds, $1.modifiedNanoseconds, $1.url.lastPathComponent)
        }
        for candidate in candidates where usage.bytes > maximumBytes || usage.entries > maximumEntries {
            try removeCacheItem(candidate.url, in: cacheRoot)
            usage = CacheUsage(
                bytes: max(0, usage.bytes - candidate.bytes),
                entries: max(0, usage.entries - candidate.entries))
        }
        usage = try cacheUsage(at: cacheRoot.url)
        try cacheRoot.verifyIdentity()
        guard usage.bytes <= maximumBytes, usage.entries <= maximumEntries else {
            throw SwiftPodsError(
                "Binary cache exceeds its \(maximumBytes)-byte or \(maximumEntries)-entry quota and has no safe evictable entries",
                hint: "Remove unknown cache files or configure a larger cache quota")
        }
    }

    private static func touchCacheEntry(_ name: String, in cacheRoot: PreparedCacheRoot) {
        guard isValidSHA256(name), (try? cacheRoot.verifyIdentity()) != nil else { return }
        let descriptor = name.withCString {
            openat(cacheRoot.descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var opened = stat()
        var linked = stat()
        guard fstat(descriptor, &opened) == 0,
            name.withCString({ fstatat(cacheRoot.descriptor, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
            opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino,
            SecureFileTree.isDirectory(opened), SecureFileTree.isDirectory(linked)
        else { return }
        _ = futimes(descriptor, nil)
    }

    private static func requireCacheDescendant(_ item: URL, in cacheRoot: PreparedCacheRoot) throws {
        let root = cacheRoot.url.standardized.path
        let candidate = item.standardized.path
        guard candidate.count > root.count, candidate.hasPrefix(root + "/") else {
            throw SwiftPodsError("Refusing a binary cache mutation outside its authenticated root")
        }
    }

    private static func createCacheDirectory(_ directory: URL, in cacheRoot: PreparedCacheRoot) throws {
        try requireCacheDescendant(directory, in: cacheRoot)
        try cacheRoot.verifyIdentity()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try cacheRoot.verifyIdentity()
        } catch {
            try cacheRoot.verifyIdentity()
            throw error
        }
    }

    private static func removeCacheItem(_ item: URL, in cacheRoot: PreparedCacheRoot) throws {
        try requireCacheDescendant(item, in: cacheRoot)
        try cacheRoot.verifyIdentity()
        do {
            try FileManager.default.removeItem(at: item)
            try cacheRoot.verifyIdentity()
        } catch {
            try cacheRoot.verifyIdentity()
            throw error
        }
    }

    private static func moveCacheItem(from source: URL, to destination: URL, in cacheRoot: PreparedCacheRoot) throws {
        try requireCacheDescendant(source, in: cacheRoot)
        try requireCacheDescendant(destination, in: cacheRoot)
        try cacheRoot.verifyIdentity()
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            try cacheRoot.verifyIdentity()
        } catch {
            try cacheRoot.verifyIdentity()
            throw error
        }
    }

    private func ensureFreeSpace(at location: URL, additionalBytes: Int64) throws {
        guard additionalBytes >= 0, minimumFreeSpaceReserveBytes >= 0 else {
            throw SwiftPodsError("Binary disk-space requirement is invalid")
        }
        guard additionalBytes <= (try availableBytesKeepingReserve(at: location)) else {
            throw SwiftPodsError(
                "Not enough free space to safely materialize binary artifacts",
                hint: "Free disk space or reduce the binary dependency size")
        }
    }

    private func availableBytesKeepingReserve(at location: URL) throws -> Int64 {
        guard minimumFreeSpaceReserveBytes >= 0 else {
            throw SwiftPodsError("Binary disk-space requirement is invalid")
        }
        let values = try location.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map({ Int64($0) })
        else {
            throw SwiftPodsError("Cannot inspect available space for binary artifacts")
        }
        guard available >= minimumFreeSpaceReserveBytes else {
            throw SwiftPodsError(
                "Not enough free space to safely materialize binary artifacts",
                hint: "Free disk space or reduce the binary dependency size")
        }
        return available - minimumFreeSpaceReserveBytes
    }

    private static func remainingTime(before deadline: UInt64) -> TimeInterval? {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { return nil }
        return TimeInterval(deadline - now) / 1_000_000_000
    }

    private static func downloadError(binary: Binary, url: String) -> SwiftPodsError {
        SwiftPodsError(
            "Binary `\(binary.name)`: download failed for \(redacted(url))",
            file: binary.declaredAt.description)
    }

    /// Cache entries are shared mutable state. Copy the authenticated tree under the cache lock, then authenticate the
    /// private copy before returning any URLs from it; later cache refreshes cannot change an in-flight installation.
    private func materializeSnapshot(
        from content: URL, to snapshot: URL, expectedTree: String, limits: SecureFileTree.Limits
    ) throws -> URL {
        let fileManager = FileManager.default
        let source = try SecureFileTree.resolvedDirectory(content, allowRootSymlink: false)
        let destination = snapshot.standardizedFileURL.resolvingSymlinksInPath()
        guard !SecureFileTree.contains(destination, in: source, allowRoot: true),
            !SecureFileTree.contains(source, in: destination, allowRoot: true)
        else { throw SwiftPodsError("Private binary snapshot overlaps its source: \(source.path)") }
        guard !SecureFileTree.existsNoFollow(snapshot) else {
            throw SwiftPodsError("Private binary snapshot already exists: \(snapshot.path)")
        }
        let sourceUsage = try SecureFileTree.validate(
            source, allowRootSymlink: false, limits: limits, hashingContents: false)
        try fileManager.createDirectory(
            at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try ensureFreeSpace(
            at: snapshot.deletingLastPathComponent(), additionalBytes: sourceUsage.bytes)
        do {
            try SecureFileTree.copySanitizedTree(from: source, to: snapshot, limits: limits)
            let copied = try SecureFileTree.validate(
                snapshot, allowRootSymlink: false, limits: limits, hashingContents: true,
                normalizingPermissionsForDigest: true
            ).1
            guard copied == expectedTree else {
                throw SwiftPodsError("Binary cache changed while a private installation snapshot was being created")
            }
            try SecureFileTree.normalizePermissions(in: snapshot)
            // Re-scan after mode/ACL normalization so no race can substitute a member during hardening.
            let hardened = try SecureFileTree.validate(
                snapshot, allowRootSymlink: false, limits: limits, hashingContents: true,
                normalizingPermissionsForDigest: true).1
            guard hardened == expectedTree else {
                throw SwiftPodsError("Binary snapshot changed while permissions were normalized")
            }
            return snapshot
        } catch {
            try? fileManager.removeItem(at: snapshot)
            throw error
        }
    }

    private func withLock<T>(
        _ sha256: String, in cache: PreparedCacheRoot, _ operation: () throws -> T
    ) throws -> T {
        try cache.verifyIdentity()
        let lockName: String
        if sha256 == "global" {
            lockName = ".lock-global"
        } else {
            guard Self.isValidSHA256(sha256), let prefix = Int(sha256.prefix(2), radix: 16) else {
                throw SwiftPodsError("Invalid binary cache lock identity")
            }
            lockName = String(format: ".lock-bucket-%02x", prefix % Self.maximumCacheLockBuckets)
        }
        let descriptor = lockName.withCString {
            openat(cache.descriptor, $0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else {
            throw SwiftPodsError("Cannot lock binary cache: \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        var status = stat()
        var linked = stat()
        guard fstat(descriptor, &status) == 0,
            lockName.withCString({ fstatat(cache.descriptor, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
            status.st_dev == linked.st_dev, status.st_ino == linked.st_ino,
            SecureFileTree.isRegularFile(status), SecureFileTree.isRegularFile(linked),
            status.st_uid == geteuid(),
            status.st_nlink == 1, fchmod(descriptor, 0o600) == 0
        else { throw SwiftPodsError("Binary cache lock is not an owned regular file") }
        guard let emptyACL = acl_init(0) else { throw SwiftPodsError("Cannot secure binary cache lock") }
        let aclResult = acl_set_fd_np(descriptor, emptyACL, ACL_TYPE_EXTENDED)
        acl_free(UnsafeMutableRawPointer(emptyACL))
        guard aclResult == 0 || errno == ENOTSUP || errno == EOPNOTSUPP else {
            throw SwiftPodsError("Cannot secure binary cache lock")
        }
        var secured = stat()
        guard fstat(descriptor, &secured) == 0 else {
            throw SwiftPodsError("Cannot authenticate binary cache lock")
        }
        try cache.verifyIdentity()
        try Self.acquireCacheLock(descriptor, timeout: Self.cacheLockTimeout)
        defer { flock(descriptor, LOCK_UN) }
        // The pathname can be unlinked and replaced while this process waits in flock(2). Locking the old inode would
        // then provide no exclusion against a peer that opened the replacement. Re-authenticate both the descriptor
        // snapshot and the directory entry after acquiring the lock; ctime detects unlink/relink ABA restoration.
        func verifyHeldLock(_ phase: String) throws {
            var locked = stat()
            var current = stat()
            guard fstat(descriptor, &locked) == 0,
                lockName.withCString({ fstatat(cache.descriptor, $0, &current, AT_SYMLINK_NOFOLLOW) }) == 0,
                Self.sameCacheLockSnapshot(locked, secured), Self.sameCacheLockSnapshot(current, secured)
            else { throw SwiftPodsError("Binary cache lock changed while it was \(phase)") }
        }
        try verifyHeldLock("being acquired")
        try cache.verifyIdentity()
        let result: Result<T, any Error>
        do {
            result = .success(try operation())
        } catch {
            result = .failure(error)
        }
        cacheLockOperationHook?(lockName)
        // Re-authenticate before unlocking on both success and failure. An unlink/recreate split-brain can otherwise let
        // a second SwiftPods process enter through a different lock inode while this operation is still publishing.
        try verifyHeldLock("held")
        try cache.verifyIdentity()
        return try result.get()
    }

    private static func sameCacheLockSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode
            && lhs.st_uid == rhs.st_uid && lhs.st_gid == rhs.st_gid && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    static func acquireCacheLock(_ descriptor: Int32, timeout: TimeInterval) throws {
        guard timeout.isFinite, timeout >= 0 else { throw SwiftPodsError("Binary cache lock timeout must be finite") }
        let start = DispatchTime.now().uptimeNanoseconds
        let duration = UInt64(timeout * 1_000_000_000)
        let deadline = start.addingReportingOverflow(duration).partialValue
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let problem = errno
            guard problem == EINTR || problem == EWOULDBLOCK || problem == EAGAIN else {
                throw SwiftPodsError("Cannot lock binary cache: \(String(cString: strerror(problem)))")
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw SwiftPodsError("Timed out waiting for the binary cache lock")
            }
            if problem == EINTR { continue }
            Thread.sleep(forTimeInterval: min(0.025, max(0.001, timeout / 100)))
        }
    }

    /// Re-materializes cached content from the checksum-authenticated archive, so mutable extracted files are never trusted.
    private func refresh(
        content: URL, from cachedArchive: URL, expectedSHA256: String, url: String,
        cache: PreparedCacheRoot, binary: Binary
    ) throws -> String {
        let entryName = content.deletingLastPathComponent().lastPathComponent
        let destination = try PreparedCacheDestination(
            parentName: entryName, childName: "content", in: cache)
        let staging = try PreparedCacheStaging(prefix: ".refresh-", in: cache)
        defer { staging.removeIfOwned() }
        let archive = try staging.child("archive")
        try staging.verifyIdentity()
        try copyAndVerifyArchive(
            from: cachedArchive, to: archive, expectedSHA256: expectedSHA256, binary: binary)
        try staging.verifyIdentity()
        try cache.verifyIdentity()
        let replacement = try staging.child("content", isDirectory: true)
        let declared = try extract(
            archive: archive, configuredURL: url, expectedSHA256: expectedSHA256,
            into: replacement, binary: binary)
        try staging.verifyIdentity()
        let inspection = try SecureFileTree.validate(
            replacement, allowRootSymlink: false, limits: .archive, hashingContents: true,
            beforeHashingContents: { entries, bytes in
                try Self.validateExtractedArchiveCounts(
                    declaredEntries: declared.entries, declaredBytes: declared.bytes,
                    actualEntries: entries, actualBytes: bytes)
            }, normalizingPermissionsForDigest: true)
        let tree = inspection.1
        try staging.verifyIdentity()
        try cache.verifyIdentity()
        try staging.publishDirectoryChild("content", to: destination)
        return tree
    }

    private func extract(
        archive: URL, configuredURL: String, expectedSHA256: String, into directory: URL, binary: Binary
    ) throws -> (entries: Int, bytes: Int64) {
        let inspected = try withAuthenticatedArchive(
            archive, expectedSHA256: expectedSHA256, binary: binary
        ) { descriptor in
            let inspected = try isolatedArchiveProcess(descriptor: descriptor, extractionRoot: nil)
            try workBudget.reserve(entries: inspected.entries, bytes: inspected.bytes, binary: binary)
            try ensureFreeSpace(
                at: directory.deletingLastPathComponent(), additionalBytes: inspected.requiredDiskBytes)
            let root = try Self.createArchiveExtractionRoot(at: directory)
            defer {
                close(root.descriptor)
                close(root.parentDescriptor)
            }
            let extracted = try isolatedArchiveProcess(
                descriptor: descriptor, extractionRoot: root.descriptor)
            guard extracted == inspected else {
                throw SwiftPodsError("Authenticated archive changed between inspection and extraction")
            }
            try Self.verifyArchiveExtractionRoot(root)
            try SecureFileTree.normalizePermissions(in: directory)
            try Self.verifyArchiveExtractionRoot(root)
            return (entries: inspected.entries, bytes: inspected.bytes)
        }
        // Extraction uses the authenticated unlinked descriptor. Re-check the pathname as well so a different archive
        // can never be committed beside that content if another process replaces the staging path concurrently.
        guard try Self.sha256(of: archive) == expectedSHA256 else {
            throw SwiftPodsError(
                "Binary `\(binary.name)`: the archive changed during extraction",
                file: binary.declaredAt.description)
        }
        return inspected
    }

    private func copyLocalArchive(
        from source: URL, to destination: URL, maximumBytes: Int64, binary: Binary
    ) throws -> Int64 {
        let inputDescriptor = source.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard inputDescriptor >= 0 else {
            throw SwiftPodsError("Binary `\(binary.name)`: local archive cannot be opened safely")
        }
        defer { close(inputDescriptor) }
        return try copyLocalArchive(
            from: inputDescriptor, to: destination, maximumBytes: maximumBytes, binary: binary)
    }

    /// The caller retains ownership of `inputDescriptor`; this function never closes it.
    private func copyLocalArchive(
        from inputDescriptor: Int32, to destination: URL, maximumBytes: Int64, binary: Binary
    ) throws -> Int64 {
        guard lseek(inputDescriptor, 0, SEEK_SET) == 0 else {
            throw SwiftPodsError("Binary `\(binary.name)`: local archive cannot be rewound safely")
        }
        let input = FileHandle(fileDescriptor: inputDescriptor, closeOnDealloc: false)
        var initial = stat()
        guard fstat(inputDescriptor, &initial) == 0, SecureFileTree.isRegularFile(initial), initial.st_size >= 0,
            initial.st_size <= maximumBytes
        else { throw SwiftPodsError("Binary `\(binary.name)`: local archive is not a bounded regular file") }
        try ensureFreeSpace(at: destination.deletingLastPathComponent(), additionalBytes: initial.st_size)

        let outputDescriptor = destination.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard outputDescriptor >= 0 else { throw SwiftPodsError("Cannot create a private local archive copy") }
        let output = FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: true)
        defer { try? output.close() }
        do {
            guard fchmod(outputDescriptor, 0o600) == 0 else {
                throw SwiftPodsError("Cannot secure a private local archive copy")
            }
            var remaining = initial.st_size
            while remaining > 0 {
                let finished = try autoreleasepool { () throws -> Bool in
                    guard let data = try input.read(upToCount: min(1 << 20, Int(remaining))), !data.isEmpty else {
                        return true
                    }
                    remaining -= Int64(data.count)
                    try output.write(contentsOf: data)
                    return false
                }
                if finished { throw SwiftPodsError("Local binary archive was truncated while it was copied") }
            }
            let extra = try input.read(upToCount: 1)
            var final = stat()
            guard fstat(inputDescriptor, &final) == 0, final.st_dev == initial.st_dev,
                final.st_ino == initial.st_ino, final.st_mode == initial.st_mode,
                final.st_nlink == initial.st_nlink, final.st_size == initial.st_size,
                final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
                final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
                final.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
                final.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec,
                remaining == 0, extra?.isEmpty != false
            else { throw SwiftPodsError("Local binary archive changed while it was copied") }
            try output.synchronize()
            return initial.st_size
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Copies the archive to an immediately unlinked descriptor while hashing the stable source. Inspection and
    /// extraction consume a read-only descriptor for this exact inode, either locally or in the isolated worker, so
    /// no pathname can be swapped after authentication and the worker cannot rewrite the authenticated bytes.
    private func withAuthenticatedArchive<Result>(
        _ source: URL, expectedSHA256: String, binary: Binary, _ body: (Int32) throws -> Result
    ) throws -> Result {
        let inputDescriptor = source.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard inputDescriptor >= 0 else { throw SwiftPodsError("Binary archive cannot be opened safely") }
        let input = FileHandle(fileDescriptor: inputDescriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var initial = stat()
        guard fstat(inputDescriptor, &initial) == 0, SecureFileTree.isRegularFile(initial), initial.st_size >= 0,
            initial.st_size <= Self.maximumArchiveBytes
        else { throw SwiftPodsError("Binary archive is not a bounded regular file") }
        try ensureFreeSpace(at: source.deletingLastPathComponent(), additionalBytes: initial.st_size)

        let temporary = source.deletingLastPathComponent()
            .appendingPathComponent(".authenticated-" + UUID().uuidString)
        let writerDescriptor = temporary.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o400)
        }
        guard writerDescriptor >= 0 else { throw SwiftPodsError("Cannot create an authenticated archive descriptor") }
        let descriptor = temporary.path.withCString {
            open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        var writerStatus = stat()
        var readerStatus = stat()
        guard descriptor >= 0, fstat(writerDescriptor, &writerStatus) == 0,
            fstat(descriptor, &readerStatus) == 0,
            writerStatus.st_dev == readerStatus.st_dev, writerStatus.st_ino == readerStatus.st_ino,
            SecureFileTree.isRegularFile(writerStatus), SecureFileTree.isRegularFile(readerStatus)
        else {
            if descriptor >= 0 { close(descriptor) }
            close(writerDescriptor)
            try? FileManager.default.removeItem(at: temporary)
            throw SwiftPodsError("Cannot retain a read-only authenticated archive descriptor")
        }
        guard unlink(temporary.path) == 0 else {
            close(writerDescriptor)
            close(descriptor)
            throw SwiftPodsError("Cannot unlink the authenticated archive descriptor")
        }
        defer { close(descriptor) }
        let output = FileHandle(fileDescriptor: writerDescriptor, closeOnDealloc: true)
        defer { try? output.close() }
        var hasher = SHA256()
        var remaining = initial.st_size
        while remaining > 0 {
            let finished = try autoreleasepool { () throws -> Bool in
                guard let data = try input.read(upToCount: min(1 << 20, Int(remaining))), !data.isEmpty else {
                    return true
                }
                remaining -= Int64(data.count)
                hasher.update(data: data)
                try output.write(contentsOf: data)
                return false
            }
            if finished { throw SwiftPodsError("Binary archive was truncated while it was authenticated") }
        }
        let extra = try input.read(upToCount: 1)
        var final = stat()
        guard fstat(inputDescriptor, &final) == 0, final.st_dev == initial.st_dev,
            final.st_ino == initial.st_ino, final.st_mode == initial.st_mode,
            final.st_nlink == initial.st_nlink, final.st_size == initial.st_size,
            final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
            final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
            final.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
            final.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec,
            remaining == 0, extra?.isEmpty != false
        else { throw SwiftPodsError("Binary archive changed while it was authenticated") }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expectedSHA256 else {
            throw SwiftPodsError(
                "Binary `\(binary.name)`: the archive does not match the Podfile SHA-256",
                file: binary.declaredAt.description)
        }
        guard fsync(writerDescriptor) == 0 else {
            throw SwiftPodsError("Cannot finalize the authenticated archive descriptor")
        }
        try output.close()
        guard lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw SwiftPodsError("Cannot rewind the authenticated archive descriptor")
        }
        return try body(descriptor)
    }

    private func copyAndVerifyArchive(
        from source: URL, to destination: URL, expectedSHA256: String, binary: Binary
    ) throws {
        let inputDescriptor = source.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard inputDescriptor >= 0 else { throw SwiftPodsError("Cached archive is not a regular file") }
        let input = FileHandle(fileDescriptor: inputDescriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var status = stat()
        guard fstat(inputDescriptor, &status) == 0, SecureFileTree.isRegularFile(status), status.st_size >= 0,
            status.st_size <= Self.maximumArchiveBytes
        else {
            throw SwiftPodsError("Cached archive is not a bounded regular file")
        }
        try workBudget.reserveArchive(bytes: status.st_size, binary: binary)
        try ensureFreeSpace(at: destination.deletingLastPathComponent(), additionalBytes: status.st_size)
        let outputDescriptor = destination.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard outputDescriptor >= 0 else { throw SwiftPodsError("Cannot create a private archive copy") }
        let output = FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: true)
        defer { try? output.close() }
        var hasher = SHA256()
        var remaining = status.st_size
        while remaining > 0 {
            let finished = try autoreleasepool { () throws -> Bool in
                guard let data = try input.read(upToCount: min(1 << 20, Int(remaining))), !data.isEmpty else {
                    return true
                }
                remaining -= Int64(data.count)
                hasher.update(data: data)
                try output.write(contentsOf: data)
                return false
            }
            if finished { throw SwiftPodsError("Cached archive was truncated while it was being read") }
        }
        let extra = try input.read(upToCount: 1)
        var final = stat()
        guard fstat(inputDescriptor, &final) == 0, final.st_dev == status.st_dev, final.st_ino == status.st_ino,
            final.st_mode == status.st_mode, final.st_nlink == status.st_nlink, final.st_size == status.st_size,
            final.st_mtimespec.tv_sec == status.st_mtimespec.tv_sec,
            final.st_mtimespec.tv_nsec == status.st_mtimespec.tv_nsec,
            final.st_ctimespec.tv_sec == status.st_ctimespec.tv_sec,
            final.st_ctimespec.tv_nsec == status.st_ctimespec.tv_nsec,
            remaining == 0, extra?.isEmpty != false
        else { throw SwiftPodsError("Cached archive changed while it was being read") }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expectedSHA256 else {
            throw SwiftPodsError("Cached binary archive does not match the Podfile SHA-256")
        }
    }

    enum Format: String, Codable, Equatable { case zip, tar }

    struct ArchiveInspection: Codable, Equatable {
        let format: Format
        let entries: Int
        let headers: Int
        let bytes: Int64
        let requiredDiskBytes: Int64
    }

    private enum ArchiveWorkerOperation: String {
        case inspect
        case extract
        case frameworkInfo = "framework-info"
    }

    private struct ArchiveWorkerResponse: Codable {
        let protocolVersion: Int
        let nonce: String
        let inspection: ArchiveInspection?
        let frameworkLibraries: [FrameworkLibraryMetadata]?
    }

    private final class ArchiveWorkerMemoryWatchdog: @unchecked Sendable {
        private let timer: DispatchSourceTimer

        init(maximumPhysicalFootprint: UInt64) throws {
            guard let footprint = Self.physicalFootprint(), footprint.current <= maximumPhysicalFootprint,
                footprint.peak <= maximumPhysicalFootprint
            else {
                throw SwiftPodsError("Archive worker already exceeds its physical-memory limit")
            }
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            self.timer = timer
            timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
            timer.setEventHandler {
                guard let footprint = Self.physicalFootprint(), footprint.current <= maximumPhysicalFootprint,
                    footprint.peak <= maximumPhysicalFootprint
                else {
                    // This is defense in depth behind the parent's independent current/peak monitor. Once this
                    // best-effort poll observes an excess, SIGKILL avoids relying on the parsing thread to unwind.
                    _ = kill(getpid(), SIGKILL)
                    return
                }
            }
            timer.resume()
        }

        deinit { timer.cancel() }

        private static func physicalFootprint() -> (current: UInt64, peak: UInt64)? {
            var information = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &information) { pointer in
                pointer.withMemoryRebound(to: Optional<UnsafeMutableRawPointer>.self, capacity: 1) {
                    proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
                }
            }
            return result == 0
                ? (information.ri_phys_footprint, information.ri_lifetime_max_phys_footprint) : nil
        }
    }

    private final class ArchiveWorkerParentPipe {
        let reader: Int32
        private let writer: Int32

        init() throws {
            let descriptors = try ProcessRunner.closeOnExecPipe()
            reader = descriptors[0]
            writer = descriptors[1]
            let flags = fcntl(reader, F_GETFL)
            guard flags >= 0, flags & O_ACCMODE == O_RDONLY,
                fcntl(reader, F_SETFL, flags | O_NONBLOCK) == 0
            else {
                close(writer)
                close(reader)
                throw SwiftPodsError("Cannot create the archive worker parent-liveness pipe")
            }
        }

        deinit {
            close(writer)
            close(reader)
        }
    }

    private final class ArchiveWorkerWorkingDirectory {
        let descriptor: Int32

        init() throws {
            var template = Array(
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("swiftpods-archive-worker.XXXXXX").path.utf8CString)
            guard template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress) }) != nil else {
                throw SwiftPodsError("Cannot create the archive worker private working directory")
            }
            let path = String(
                decoding: template.lazy.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            descriptor = path.withCString {
                open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            var opened = stat()
            var linked = stat()
            guard descriptor >= 0, fstat(descriptor, &opened) == 0,
                path.withCString({ lstat($0, &linked) }) == 0,
                opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino,
                SecureFileTree.isDirectory(opened), SecureFileTree.isDirectory(linked),
                opened.st_uid == geteuid(), opened.st_mode & 0o077 == 0,
                path.withCString({ rmdir($0) }) == 0
            else {
                if descriptor >= 0 { close(descriptor) }
                _ = path.withCString { rmdir($0) }
                throw SwiftPodsError("Archive worker private working directory is not secure")
            }
        }

        deinit { close(descriptor) }
    }

    private final class ArchiveWorkerParentWatchdog: @unchecked Sendable {
        private let source: DispatchSourceRead

        init(descriptor: Int32) throws {
            var status = stat()
            var pipeInformation = pipe_fdinfo()
            let pipeBytes = withUnsafeMutablePointer(to: &pipeInformation) {
                proc_pidfdinfo(
                    getpid(), descriptor, PROC_PIDFDPIPEINFO, $0,
                    Int32(MemoryLayout<pipe_fdinfo>.size))
            }
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, flags & O_ACCMODE == O_RDONLY,
                fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
                fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFIFO,
                pipeBytes == MemoryLayout<pipe_fdinfo>.size,
                pipeInformation.pipeinfo.pipe_handle != 0,
                pipeInformation.pipeinfo.pipe_peerhandle != 0,
                pipeInformation.pipeinfo.pipe_handle != pipeInformation.pipeinfo.pipe_peerhandle
            else { throw SwiftPodsError("Archive worker did not receive a unique read-only parent-liveness pipe") }

            let source = DispatchSource.makeReadSource(
                fileDescriptor: descriptor, queue: .global(qos: .userInteractive))
            self.source = source
            source.setEventHandler {
                var byte = UInt8()
                var result: Int
                repeat { result = Darwin.read(descriptor, &byte, 1) } while result < 0 && errno == EINTR
                if result == 0 || result > 0
                    || (result < 0 && errno != EAGAIN && errno != EWOULDBLOCK)
                {
                    // The parent never writes payload bytes. EOF, HUP, data or an invalid pipe state all mean that the
                    // worker has lost its only supervising parent and must not outlive it.
                    _ = kill(getpid(), SIGKILL)
                }
            }
            source.resume()

            // A parent can die after spawning the worker but before this watchdog is initialized. Arm the asynchronous
            // source first, then probe the nonblocking reader synchronously so there is no unobserved interval before
            // libarchive starts. The parent never writes payload bytes, therefore only EAGAIN/EWOULDBLOCK means the
            // writer is still open and the pipe is in the expected empty state.
            var byte = UInt8()
            while true {
                let result = Darwin.read(descriptor, &byte, 1)
                if result < 0, errno == EINTR { continue }
                guard result < 0, errno == EAGAIN || errno == EWOULDBLOCK else {
                    throw SwiftPodsError("Archive worker lost its supervising parent before initialization")
                }
                break
            }
        }

        deinit { source.cancel() }
    }

    /// Holds the exact executable vnode used to launch the hidden archive worker. `_NSGetExecutablePath` identifies the
    /// running image even when a release was renamed or copied; neither PATH nor argv[0] participates. SwiftPM's test
    /// host is the one exception: its `.xctest` image has no worker entry point, so debug tests use the validated sibling
    /// `swiftpods` product from the same products directory.
    private final class PinnedArchiveWorkerExecutable {
        let path: String
        let descriptor: Int32
        let processIdentity: ProcessExecutableIdentity
        private let status: stat

        init() throws {
            let running = try Self.currentExecutablePath()
            let selected: String
            #if DEBUG
            let authenticateAgainstCurrentImage: Bool
            let testBundles = Bundle.allBundles.map(\.bundleURL).filter { $0.pathExtension == "xctest" }
            let testBundle = Self.containingTestBundle(of: URL(fileURLWithPath: running))
                ?? (testBundles.count == 1 ? testBundles[0] : nil)
            if let testBundle {
                selected = try Self.canonicalPath(
                    testBundle.deletingLastPathComponent().appendingPathComponent("swiftpods").path)
                authenticateAgainstCurrentImage = false
            } else {
                selected = running
                authenticateAgainstCurrentImage = true
            }
            #else
            selected = running
            #endif
            path = selected
            descriptor = selected.withCString {
                open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard descriptor >= 0 else {
                throw SwiftPodsError("Cannot pin the SwiftPods archive worker executable")
            }
            var opened = stat()
            var linked = stat()
            guard fstat(descriptor, &opened) == 0,
                selected.withCString({ lstat($0, &linked) }) == 0,
                Self.sameFile(opened, linked), SecureFileTree.isRegularFile(opened),
                opened.st_size > 0, opened.st_uid == 0 || opened.st_uid == geteuid(),
                opened.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
                opened.st_mode & mode_t(S_IXUSR | S_IXGRP | S_IXOTH) != 0
            else {
                close(descriptor)
                throw SwiftPodsError("SwiftPods archive worker executable is not a pinned trusted regular file")
            }
            status = opened
            do {
                processIdentity = try ProcessExecutableIdentity(descriptor: descriptor)
                #if DEBUG
                if authenticateAgainstCurrentImage {
                    try Self.validateCurrentMappedExecutable(processIdentity)
                }
                #else
                try Self.validateCurrentMappedExecutable(processIdentity)
                #endif
            } catch {
                close(descriptor)
                throw error
            }
        }

        deinit { close(descriptor) }

        func verifyPathIdentity() throws {
            var opened = stat()
            var linked = stat()
            guard fstat(descriptor, &opened) == 0,
                path.withCString({ lstat($0, &linked) }) == 0,
                Self.sameSnapshot(opened, status), Self.sameSnapshot(linked, status)
            else { throw SwiftPodsError("SwiftPods archive worker executable changed while it was running") }
        }

        static func validateInheritedCurrentExecutable(_ inheritedDescriptor: Int32) throws {
            let current = try PinnedArchiveWorkerExecutable()
            var inherited = stat()
            var opened = stat()
            guard fstat(inheritedDescriptor, &inherited) == 0,
                fstat(current.descriptor, &opened) == 0,
                sameSnapshot(inherited, opened)
            else { throw SwiftPodsError("Archive worker executable identity is not authenticated") }
            try current.verifyPathIdentity()
        }

        private static func validateCurrentMappedExecutable(_ expected: ProcessExecutableIdentity) throws {
            var region = proc_regionwithpathinfo()
            let read = withUnsafeMutablePointer(to: &region) {
                proc_pidinfo(
                    getpid(), PROC_PIDREGIONPATHINFO, 0, $0,
                    Int32(MemoryLayout<proc_regionwithpathinfo>.size))
            }
            guard read == MemoryLayout<proc_regionwithpathinfo>.size,
                region.prp_prinfo.pri_address > 0, region.prp_prinfo.pri_size > 0,
                region.prp_prinfo.pri_protection & UInt32(bitPattern: VM_PROT_EXECUTE) != 0,
                expected.matchesMappedExecutable(region.prp_vip.vip_vi.vi_stat)
            else {
                throw SwiftPodsError("SwiftPods archive worker pathname does not match the running executable image")
            }
        }

        private static func currentExecutablePath() throws -> String {
            var capacity = max(Int(PATH_MAX), 4_096)
            while capacity <= 1 * 1_024 * 1_024 {
                var buffer = [CChar](repeating: 0, count: capacity)
                var size = UInt32(buffer.count)
                let result = buffer.withUnsafeMutableBufferPointer {
                    _NSGetExecutablePath($0.baseAddress, &size)
                }
                if result == 0 {
                    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                    return try canonicalPath(String(decoding: bytes, as: UTF8.self))
                }
                guard size > UInt32(capacity) else { break }
                capacity = Int(size)
            }
            throw SwiftPodsError("Cannot resolve the running SwiftPods executable")
        }

        private static func canonicalPath(_ path: String) throws -> String {
            guard let resolved = path.withCString({ realpath($0, nil) }) else {
                throw SwiftPodsError("Cannot resolve the SwiftPods archive worker executable")
            }
            defer { free(resolved) }
            return String(cString: resolved)
        }

        private static func containingTestBundle(of executable: URL) -> URL? {
            var current = executable.deletingLastPathComponent()
            while current.path != "/" {
                if current.pathExtension == "xctest" { return current }
                let parent = current.deletingLastPathComponent()
                guard parent.path != current.path else { return nil }
                current = parent
            }
            return nil
        }

        private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
            lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
        }

        private static func sameSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
            sameFile(lhs, rhs) && lhs.st_mode == rhs.st_mode && lhs.st_uid == rhs.st_uid
                && lhs.st_gid == rhs.st_gid && lhs.st_nlink == rhs.st_nlink && lhs.st_size == rhs.st_size
                && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
                && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
                && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
                && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
        }
    }

    private func isolatedArchiveProcess(
        descriptor: Int32, extractionRoot: Int32?
    ) throws -> ArchiveInspection {
        let response = try Self.isolatedWorkerProcess(
            operation: extractionRoot == nil ? .inspect : .extract,
            descriptor: descriptor, extractionRoot: extractionRoot)
        guard let inspection = response.inspection, response.frameworkLibraries == nil else {
            throw SwiftPodsError("SwiftPods archive worker returned an unexpected response")
        }
        return inspection
    }

    static func frameworkLibraries(fromInfoPlistDescriptor descriptor: Int32) throws -> [FrameworkLibraryMetadata] {
        let response = try isolatedWorkerProcess(
            operation: .frameworkInfo, descriptor: descriptor, extractionRoot: nil)
        guard response.inspection == nil, let libraries = response.frameworkLibraries else {
            throw SwiftPodsError("Framework metadata worker returned an unexpected response")
        }
        return libraries
    }

    private static func isolatedWorkerProcess(
        operation: ArchiveWorkerOperation, descriptor: Int32, extractionRoot: Int32?
    ) throws -> ArchiveWorkerResponse {
        let executable = try PinnedArchiveWorkerExecutable()
        let parentPipe = try ArchiveWorkerParentPipe()
        let workingDirectory = try ArchiveWorkerWorkingDirectory()
        let nonce = UUID().uuidString.lowercased()
        let arguments = [
            SwiftPodsArchiveWorker.command, "1", operation.rawValue, String(descriptor),
            extractionRoot.map(String.init) ?? "-1", String(executable.descriptor), String(parentPipe.reader), nonce,
        ]
        let inherited = [descriptor, executable.descriptor, parentPipe.reader] + (extractionRoot.map { [$0] } ?? [])
        let physicalMemoryLimit: UInt64 = operation == .frameworkInfo
            ? 256 * 1_024 * 1_024 : 512 * 1_024 * 1_024
        let timeout: TimeInterval = operation == .frameworkInfo ? 30 : Self.commandTimeout + 10
        let output: Data
        do {
            output = try withExtendedLifetime(parentPipe) {
                try withExtendedLifetime(workingDirectory) {
                    try ProcessRunner().runData(
                        executable.path, arguments, in: nil, timeout: timeout,
                        maximumOutputBytes: 128 * 1_024, passingFileDescriptors: inherited,
                        maximumPhysicalMemoryBytes: physicalMemoryLimit,
                        expectedExecutable: executable.processIdentity,
                        workingDirectoryDescriptor: workingDirectory.descriptor,
                        environment: ["LANG": "C", "LC_ALL": "C"])
                }
            }
        } catch {
            try executable.verifyPathIdentity()
            throw error
        }
        try executable.verifyPathIdentity()
        let response: ArchiveWorkerResponse
        do {
            response = try JSONDecoder().decode(ArchiveWorkerResponse.self, from: output)
        } catch {
            throw SwiftPodsError("SwiftPods archive worker returned a malformed bounded response")
        }
        guard response.protocolVersion == 1, response.nonce == nonce else {
            throw SwiftPodsError("SwiftPods archive worker returned an unauthenticated response")
        }
        return response
    }

    /// Conservative allocation budget for attacker-controlled archive metadata. `String` and collection storage is
    /// copy-on-write, but charging every logical dictionary key/value and temporary prefix as an independent copy makes
    /// the bound independent of Swift's current small-string and hash-table implementation details.
    private struct ArchiveMetadataBudget {
        private(set) var used = 0
        let limit: Int

        init(limit: Int) throws {
            guard limit > 0, limit <= maximumAggregateArchiveMetadataBytes else {
                throw SwiftPodsError("Archive metadata limit is invalid")
            }
            self.limit = limit
        }

        mutating func consume(bytes: Int, copies: Int = 1, objects: Int = 0) throws {
            guard bytes >= 0, copies >= 0, objects >= 0 else {
                throw SwiftPodsError("Archive metadata accounting overflowed")
            }
            let copied = bytes.multipliedReportingOverflow(by: copies)
            let overhead = objects.multipliedReportingOverflow(by: 128)
            guard !copied.overflow, !overhead.overflow else {
                throw SwiftPodsError("Archive metadata exceeds its memory budget")
            }
            let amount = copied.partialValue.addingReportingOverflow(overhead.partialValue)
            guard !amount.overflow, amount.partialValue <= limit - used else {
                throw SwiftPodsError("Archive metadata exceeds its \(limit)-byte memory budget")
            }
            used += amount.partialValue
        }

        mutating func consume(_ text: String, copies: Int = 1, objects: Int = 1) throws {
            try consume(bytes: text.utf8.count, copies: copies, objects: objects)
        }
    }

    static func validateExtractedArchiveCounts(
        declaredEntries: Int, declaredBytes: Int64, actualEntries: Int, actualBytes: Int64
    ) throws {
        guard actualEntries == declaredEntries, actualBytes == declaredBytes else {
            throw SwiftPodsError("Extracted archive tree does not match its authenticated entry and byte counts")
        }
    }

    private enum ArchiveNodeKind: Equatable {
        case implicitDirectory
        case directory
        case file
        case symbolicLink

        var isDirectory: Bool { self == .implicitDirectory || self == .directory }
    }

    /// Reads the actual inner format selected by system libarchive. Only the explicitly
    /// registered compression filters are accepted; suffixes and compression envelopes never imply an archive format.
    /// The structured pass also accounts for every parent directory extraction must create implicitly.
    static func inspectArchive(
        at archive: URL, url: String, limits: SecureFileTree.Limits = .archive,
        inspectionTimeout: TimeInterval = commandTimeout,
        metadataLimit: Int = maximumAggregateArchiveMetadataBytes
    ) throws -> ArchiveInspection {
        let descriptor = archive.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else {
            throw SwiftPodsError("Cannot safely open \(redacted(url))")
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, SecureFileTree.isRegularFile(status), status.st_size >= 0,
            status.st_size <= maximumArchiveBytes
        else { throw SwiftPodsError("\(redacted(url)) is not a bounded regular archive") }
        return try inspectArchive(
            descriptor: descriptor, url: url, limits: limits, inspectionTimeout: inspectionTimeout,
            metadataLimit: metadataLimit)
    }

    static func format(of archive: URL, url: String) throws -> Format {
        try inspectArchive(at: archive, url: url).format
    }

    private static func inspectArchive(
        descriptor: Int32, url: String, limits: SecureFileTree.Limits,
        inspectionTimeout: TimeInterval = commandTimeout,
        metadataLimit: Int = maximumAggregateArchiveMetadataBytes
    ) throws -> ArchiveInspection {
        try processArchive(
            descriptor: descriptor, url: url, limits: limits,
            inspectionTimeout: inspectionTimeout, extractionRoot: nil, metadataLimit: metadataLimit)
    }

    private struct ArchiveExtractionRoot {
        let parentDescriptor: Int32
        let descriptor: Int32
        let name: String
        let status: stat
    }

    private struct ArchiveHardLink {
        let path: [String]
        let target: [String]
    }

    private static func processArchive(
        descriptor: Int32, url: String, limits: SecureFileTree.Limits,
        inspectionTimeout: TimeInterval, extractionRoot: Int32?,
        metadataLimit: Int = maximumAggregateArchiveMetadataBytes
    ) throws -> ArchiveInspection {
        guard limits.entries > 0, limits.bytes >= 0, limits.depth > 0 else {
            throw SwiftPodsError("Archive processing limits are invalid")
        }
        let entryLimit = min(limits.entries, maximumArchiveEntries)
        return try withArchiveReader(
            descriptor: descriptor, url: url, inspectionTimeout: inspectionTimeout
        ) { reader, deadline in
            var detectedFormat: Format?
            var headers = 0
            var bytes: Int64 = 0
            var nodes: [String: ArchiveNodeKind] = [:]
            var fileSystemPaths: [String: String] = [:]
            var fileSizes: [String: Int64] = [:]
            var hardLinks: [ArchiveHardLink] = []
            var metadata = try ArchiveMetadataBudget(limit: metadataLimit)

            while true {
                guard DispatchTime.now().uptimeNanoseconds < deadline else {
                    throw SwiftPodsError("Archive inspection timed out")
                }
                var entry: OpaquePointer?
                let result = archive_read_next_header(reader, &entry)
                if result == ARCHIVE_EOF { break }
                guard result == ARCHIVE_OK, let entry else {
                    throw archiveInspectionError(reader, url: url, status: result)
                }

                // Check the bidder before pathname or data handling. In particular an mtree `contents=` directive is
                // rejected before libarchive can open the referenced host file.
                let selected = archive_format(reader) & ARCHIVE_FORMAT_BASE_MASK
                let format: Format
                switch selected {
                case ARCHIVE_FORMAT_TAR: format = .tar
                case ARCHIVE_FORMAT_ZIP: format = .zip
                default: throw SwiftPodsError("\(redacted(url)) is not a zip or tar archive")
                }
                if let detectedFormat {
                    guard detectedFormat == format else {
                        throw SwiftPodsError("Archive changes format while it is being processed")
                    }
                } else {
                    detectedFormat = format
                }

                headers += 1
                guard headers <= entryLimit else { throw SwiftPodsError("Archive contains too many entries") }
                guard archive_entry_is_encrypted(entry) == 0 else {
                    throw SwiftPodsError("Encrypted binary archives are not supported")
                }
                let pathname = try boundedArchiveString(
                    archive_entry_pathname_utf8(entry), maximumBytes: maximumArchiveMetadataBytes,
                    missing: "Archive contains a pathname that is not valid UTF-8",
                    oversized: "Archive contains an excessively long pathname")
                try metadata.consume(pathname)
                let pathComponents = try archivePathComponents(
                    pathname, depth: limits.depth, metadata: &metadata)
                let symlink = try optionalBoundedArchiveString(
                    archive_entry_symlink_utf8(entry), maximumBytes: maximumArchiveMetadataBytes,
                    invalid: "Archive contains an unsafe symbolic-link target")
                let hardlink = try optionalBoundedArchiveString(
                    archive_entry_hardlink_utf8(entry), maximumBytes: maximumArchiveMetadataBytes,
                    invalid: "Archive contains an unsafe hard-link target")
                if let symlink { try metadata.consume(symlink) }
                if let hardlink { try metadata.consume(hardlink) }
                guard symlink == nil || hardlink == nil else {
                    throw SwiftPodsError("Archive entry cannot be both a symbolic link and a hard link")
                }

                let fileType = archive_entry_mode(entry)
                let kind: ArchiveNodeKind
                let typeBits = fileType & mode_t(S_IFMT)
                if typeBits == 0, hardlink != nil {
                    // POSIX tar hard-link headers carry no independent file-type bits; the target is proven to be a
                    // regular file after every header has been parsed, before linkat is permitted.
                    kind = .file
                } else {
                    switch typeBits {
                    case mode_t(S_IFREG): kind = .file
                    case mode_t(S_IFDIR): kind = .directory
                    case mode_t(S_IFLNK): kind = .symbolicLink
                    default: throw SwiftPodsError("Archive contains a special or unsupported filesystem object")
                    }
                }
                guard (kind == .symbolicLink) == (symlink != nil), kind == .file || hardlink == nil else {
                    throw SwiftPodsError("Archive contains inconsistent link metadata")
                }

                if pathComponents.isEmpty {
                    guard kind == .directory else { throw SwiftPodsError("Archive contains an empty pathname") }
                } else {
                    try insertArchivePath(
                        pathComponents, kind: kind, nodes: &nodes, fileSystemPaths: &fileSystemPaths,
                        maximumEntries: entryLimit, metadata: &metadata)
                }

                let declaredSize: Int64?
                if archive_entry_size_is_set(entry) != 0 {
                    let size = archive_entry_size(entry)
                    guard size >= 0 else { throw SwiftPodsError("Archive contains a negative file size") }
                    guard size <= limits.bytes else {
                        throw SwiftPodsError("Expanded archive is larger than \(limits.bytes) bytes")
                    }
                    declaredSize = size
                } else {
                    // Streaming ZIP entries may carry the size in a trailing descriptor. Their actual data blocks are
                    // still processed under the same logical-byte and deadline limits.
                    declaredSize = nil
                }
                let permissions = archive_entry_perm(entry)

                switch kind {
                case .file:
                    if let hardlink {
                        guard pathComponents.isEmpty == false, declaredSize == nil || declaredSize == 0 else {
                            throw SwiftPodsError("Archive hard link contains unexpected file data")
                        }
                        let observed = try readArchiveData(
                            reader, url: url, deadline: deadline, declaredSize: declaredSize,
                            maximumLogicalBytes: 0, outputDescriptor: nil)
                        guard observed == 0 else {
                            throw SwiftPodsError("Archive hard link contains unexpected file data")
                        }
                        let target = try archivePathComponents(
                            hardlink, depth: limits.depth, metadata: &metadata)
                        guard !target.isEmpty else {
                            throw SwiftPodsError("Archive contains an empty hard-link target")
                        }
                        let pathBytes = normalizedArchivePathByteCount(pathComponents)
                        let targetBytes = normalizedArchivePathByteCount(target)
                        try metadata.consume(
                            bytes: pathBytes + targetBytes, copies: 2,
                            objects: pathComponents.count + target.count + 2)
                        hardLinks.append(ArchiveHardLink(path: pathComponents, target: target))
                    } else {
                        if let declaredSize {
                            guard declaredSize <= limits.bytes - bytes else {
                                throw SwiftPodsError("Expanded archive is larger than \(limits.bytes) bytes")
                            }
                        }
                        let output = try extractionRoot.map {
                            try createArchiveFile(root: $0, path: pathComponents)
                        }
                        defer { if let output { close(output) } }
                        let observed = try readArchiveData(
                            reader, url: url, deadline: deadline, declaredSize: declaredSize,
                            maximumLogicalBytes: limits.bytes - bytes, outputDescriptor: output)
                        let size = declaredSize ?? observed
                        guard size <= limits.bytes - bytes else {
                            throw SwiftPodsError("Expanded archive is larger than \(limits.bytes) bytes")
                        }
                        if let output {
                            guard ftruncate(output, off_t(size)) == 0,
                                fchmod(output, safeArchiveFileMode(permissions)) == 0,
                                fchflags(output, 0) == 0
                            else { throw SwiftPodsError("Cannot finalize an extracted archive file") }
                        }
                        bytes += size
                        let filePath = pathComponents.joined(separator: "/")
                        try metadata.consume(filePath, copies: 2, objects: 2)
                        fileSizes[filePath] = size
                    }
                case .directory:
                    guard symlink == nil, hardlink == nil, declaredSize == nil || declaredSize == 0 else {
                        throw SwiftPodsError("Archive directory contains inconsistent data")
                    }
                    let observed = try readArchiveData(
                        reader, url: url, deadline: deadline, declaredSize: declaredSize,
                        maximumLogicalBytes: 0, outputDescriptor: nil)
                    guard observed == 0 else { throw SwiftPodsError("Archive directory contains file data") }
                    if let extractionRoot, !pathComponents.isEmpty {
                        try createArchiveDirectory(
                            root: extractionRoot, path: pathComponents, permissions: permissions)
                    }
                case .symbolicLink:
                    guard let symlink, hardlink == nil, declaredSize == nil || declaredSize == 0 else {
                        throw SwiftPodsError("Archive symbolic link contains inconsistent data")
                    }
                    try validateArchiveSymbolicLink(
                        symlink, from: pathComponents, maximumDepth: limits.depth)
                    let observed = try readArchiveData(
                        reader, url: url, deadline: deadline, declaredSize: declaredSize,
                        maximumLogicalBytes: 0, outputDescriptor: nil)
                    guard observed == 0 else { throw SwiftPodsError("Archive symbolic link contains file data") }
                    if let extractionRoot {
                        try createArchiveSymbolicLink(root: extractionRoot, path: pathComponents, target: symlink)
                    }
                case .implicitDirectory:
                    preconditionFailure("Implicit directories are not archive headers")
                }
            }

            guard let detectedFormat, headers > 0 else {
                throw SwiftPodsError("\(redacted(url)) is not a non-empty zip or tar archive")
            }
            for link in hardLinks {
                try metadata.consume(
                    bytes: normalizedArchivePathByteCount(link.path), copies: 2, objects: 2)
            }
            let hardLinkPaths = Set(hardLinks.map { $0.path.joined(separator: "/") })
            for link in hardLinks {
                let path = link.path.joined(separator: "/")
                let target = link.target.joined(separator: "/")
                try metadata.consume(bytes: path.utf8.count + target.utf8.count, objects: 2)
                guard !hardLinkPaths.contains(target), nodes[target] == .file,
                    let size = fileSizes[target], size <= limits.bytes - bytes
                else {
                    throw SwiftPodsError("Archive hard link escapes its root or refers to a non-file: \(path)")
                }
                bytes += size
                fileSizes[path] = size
                if let extractionRoot {
                    try createArchiveHardLink(root: extractionRoot, path: link.path, target: link.target)
                }
            }
            let diskMetadata = Int64(nodes.count).multipliedReportingOverflow(by: 4 * 1_024)
            guard !diskMetadata.overflow else { throw SwiftPodsError("Archive contains too many filesystem objects") }
            let required = bytes.addingReportingOverflow(diskMetadata.partialValue)
            guard !required.overflow else { throw SwiftPodsError("Expanded archive is too large") }
            return ArchiveInspection(
                format: detectedFormat, entries: nodes.count, headers: headers, bytes: bytes,
                requiredDiskBytes: required.partialValue)
        }
    }

    private static func withArchiveReader<Result>(
        descriptor: Int32, url: String, inspectionTimeout: TimeInterval,
        _ body: (OpaquePointer, UInt64) throws -> Result
    ) throws -> Result {
        guard inspectionTimeout.isFinite, inspectionTimeout >= 0 else {
            throw SwiftPodsError("Archive inspection timeout must be finite")
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let seconds = inspectionTimeout * 1_000_000_000
        guard seconds < TimeInterval(UInt64.max) else {
            throw SwiftPodsError("Archive inspection timeout is too large")
        }
        let duration = UInt64(seconds.rounded(.up))
        let deadlineResult = started.addingReportingOverflow(duration)
        guard !deadlineResult.overflow else { throw SwiftPodsError("Archive inspection timeout is too large") }
        // A lightweight, fixed-buffer pass recognizes ordinary uncompressed tar headers and rejects oversized PAX
        // or GNU long-name records before libarchive parses them. Production compressed inputs reach this routine in
        // the isolated worker, whose parent enforces wall-time, output and observed physical-footprint ceilings.
        try preflightUncompressedTarMetadata(descriptor: descriptor, deadline: deadlineResult.partialValue)
        guard lseek(descriptor, 0, SEEK_SET) == 0,
            let reader = archive_read_new()
        else { throw SwiftPodsError("Cannot initialize archive inspection") }
        guard let context = swiftpods_archive_read_context_create(descriptor, deadlineResult.partialValue) else {
            _ = archive_read_free(reader)
            throw SwiftPodsError("Cannot initialize bounded archive inspection input")
        }
        defer {
            _ = archive_read_close(reader)
            _ = archive_read_free(reader)
            swiftpods_archive_read_context_destroy(context)
        }
        // Deliberately omit all other formats, plus program, uuencode, compress, lzma, lzip, lrzip, lzop, grzip, lz4
        // and zstd filters. Registering only tar and zip prevents a non-archive bidder such as mtree from parsing any
        // entry metadata before SwiftPods can reject it.
        for result in [
            archive_read_support_filter_none(reader), archive_read_support_filter_gzip(reader),
            archive_read_support_filter_bzip2(reader), archive_read_support_filter_xz(reader),
            archive_read_support_format_tar(reader), archive_read_support_format_zip(reader),
        ] {
            guard result == ARCHIVE_OK else { throw archiveInspectionError(reader, url: url) }
        }
        guard archive_read_set_options(reader, "tar:!mac-ext,zip:!mac-ext") == ARCHIVE_OK else {
            throw archiveInspectionError(reader, url: url)
        }
        // libarchive exposes no per-header allocation ceiling for compressed PAX records. Uncompressed tar is bounded
        // by the fixed-buffer preflight above; for compressed input the authenticated file/read callback and every
        // returned C string are bounded, while the isolated worker contains internal allocation before return.
        guard swiftpods_archive_read_open_with_deadline(reader, context) == ARCHIVE_OK else {
            let detail = boundedArchiveDiagnostic(archive_error_string(reader))
            if detail.localizedCaseInsensitiveContains("unrecognized archive format") {
                throw SwiftPodsError("\(redacted(url)) is not a zip or tar archive")
            }
            throw archiveInspectionError(reader, url: url)
        }
        return try body(reader, deadlineResult.partialValue)
    }

    private static func preflightUncompressedTarMetadata(descriptor: Int32, deadline: UInt64) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0, SecureFileTree.isRegularFile(status), status.st_size >= 512 else {
            return
        }
        var header = [UInt8](repeating: 0, count: 512)
        guard try readArchiveHeader(descriptor: descriptor, offset: 0, into: &header), isRecognizedTarHeader(header) else {
            return
        }

        var offset: Int64 = 0
        var extendedBytes: Int64 = 0
        var headers = 0
        while offset <= status.st_size - 512 {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw SwiftPodsError("Archive inspection timed out")
            }
            guard try readArchiveHeader(descriptor: descriptor, offset: offset, into: &header) else { return }
            if header.allSatisfy({ $0 == 0 }) { return }
            guard isRecognizedTarHeader(header), let size = tarOctal(header[124..<136]) else { return }
            headers += 1
            guard headers <= maximumArchiveEntries else { throw SwiftPodsError("Archive contains too many entries") }

            switch header[156] {
            case 0x78, 0x67, 0x4c, 0x4b: // POSIX PAX x/g and GNU long path/link L/K.
                guard size <= maximumTarExtendedHeaderBytes,
                    extendedBytes <= Int64(maximumAggregateArchiveMetadataBytes) - size
                else { throw SwiftPodsError("Archive metadata exceeds its memory budget") }
                extendedBytes += size
            default:
                break
            }

            let rounded = size.addingReportingOverflow(511)
            guard !rounded.overflow else { throw SwiftPodsError("Archive metadata size overflowed") }
            let blocks = rounded.partialValue / 512
            let payload = blocks.multipliedReportingOverflow(by: 512)
            let next = offset.addingReportingOverflow(512)
            guard !payload.overflow, !next.overflow else {
                throw SwiftPodsError("Archive metadata size overflowed")
            }
            let end = next.partialValue.addingReportingOverflow(payload.partialValue)
            guard !end.overflow, end.partialValue > offset, end.partialValue <= status.st_size else { return }
            offset = end.partialValue
        }
    }

    private static func readArchiveHeader(
        descriptor: Int32, offset: Int64, into buffer: inout [UInt8]
    ) throws -> Bool {
        precondition(buffer.count == 512)
        return try buffer.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
            var readBytes = 0
            while readBytes < bytes.count {
                let result = pread(
                    descriptor, base.advanced(by: readBytes), bytes.count - readBytes,
                    off_t(offset + Int64(readBytes)))
                if result > 0 {
                    readBytes += result
                } else if result == 0 {
                    return false
                } else if errno == EINTR {
                    continue
                } else {
                    throw SwiftPodsError("Cannot preflight archive metadata")
                }
            }
            return true
        }
    }

    private static func isRecognizedTarHeader(_ header: [UInt8]) -> Bool {
        guard header.count == 512,
            header[257] == 0x75, header[258] == 0x73, header[259] == 0x74,
            header[260] == 0x61, header[261] == 0x72,
            let expected = tarOctal(header[148..<156])
        else { return false }
        var actual: Int64 = 0
        for (index, byte) in header.enumerated() {
            actual += Int64((148..<156).contains(index) ? 0x20 : byte)
        }
        return actual == expected
    }

    private static func tarOctal(_ bytes: ArraySlice<UInt8>) -> Int64? {
        if let first = bytes.first, first & 0x80 != 0 {
            // POSIX/GNU base-256 form: the high bit marks binary encoding and the next bit is the sign. Archive sizes
            // must be non-negative and fit Int64; overflow fails the preflight closed rather than bypassing it.
            guard first & 0x40 == 0 else { return nil }
            var value = Int64(first & 0x3f)
            for byte in bytes.dropFirst() {
                let multiplied = value.multipliedReportingOverflow(by: 256)
                let added = multiplied.partialValue.addingReportingOverflow(Int64(byte))
                guard !multiplied.overflow, !added.overflow else { return nil }
                value = added.partialValue
            }
            return value
        }
        var value: Int64 = 0
        var foundDigit = false
        var finished = false
        for byte in bytes {
            if byte == 0 || byte == 0x20 {
                if foundDigit { finished = true }
                continue
            }
            guard !finished, (0x30...0x37).contains(byte) else { return nil }
            foundDigit = true
            let multiplied = value.multipliedReportingOverflow(by: 8)
            let added = multiplied.partialValue.addingReportingOverflow(Int64(byte - 0x30))
            guard !multiplied.overflow, !added.overflow else { return nil }
            value = added.partialValue
        }
        return foundDigit ? value : 0
    }

    private static func boundedArchiveString(
        _ pointer: UnsafePointer<CChar>?, maximumBytes: Int, missing: String, oversized: String
    ) throws -> String {
        guard let pointer else { throw SwiftPodsError(missing) }
        let length = strnlen(pointer, maximumBytes + 1)
        guard length <= maximumBytes else { throw SwiftPodsError(oversized) }
        let bytes = UnsafeRawBufferPointer(start: pointer, count: length)
        guard let value = String(bytes: bytes, encoding: .utf8) else { throw SwiftPodsError(missing) }
        return value
    }

    private static func optionalBoundedArchiveString(
        _ pointer: UnsafePointer<CChar>?, maximumBytes: Int, invalid: String
    ) throws -> String? {
        guard let pointer else { return nil }
        return try boundedArchiveString(
            pointer, maximumBytes: maximumBytes, missing: invalid, oversized: invalid)
    }

    private static func boundedArchiveDiagnostic(_ pointer: UnsafePointer<CChar>?) -> String {
        guard let pointer else { return "unknown libarchive error" }
        let maximumBytes = 4 * 1_024
        let length = strnlen(pointer, maximumBytes + 1)
        guard length <= maximumBytes else { return "libarchive error message exceeded its limit" }
        return String(bytes: UnsafeRawBufferPointer(start: pointer, count: length), encoding: .utf8)
            ?? "libarchive returned an invalid error message"
    }

    private static func readArchiveData(
        _ reader: OpaquePointer, url: String, deadline: UInt64, declaredSize: Int64?,
        maximumLogicalBytes: Int64, outputDescriptor: Int32?
    ) throws -> Int64 {
        var logicalSize: Int64 = 0
        var previousEnd: Int64 = 0
        var emptyBlocks = 0
        while true {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw SwiftPodsError("Archive inspection timed out")
            }
            var buffer: UnsafeRawPointer?
            var count = 0
            var offset: Int64 = 0
            let result = archive_read_data_block(reader, &buffer, &count, &offset)
            if result == ARCHIVE_EOF { break }
            if result == ARCHIVE_OK, count == 0 {
                // Apple's ZIP reader emits one empty block for a Unix symlink whose target is already represented in
                // archive_entry_symlink_utf8(). Bound these no-progress callbacks so malformed input cannot spin.
                emptyBlocks += 1
                guard emptyBlocks <= 16 else {
                    throw SwiftPodsError("Archive entry contains too many empty data blocks")
                }
                continue
            }
            guard result == ARCHIVE_OK, let buffer, count > 0, offset >= previousEnd,
                UInt64(count) <= UInt64(Int64.max)
            else { throw archiveInspectionError(reader, url: url, status: result) }
            let end = offset.addingReportingOverflow(Int64(count))
            guard !end.overflow, end.partialValue <= maximumLogicalBytes,
                declaredSize.map({ end.partialValue <= $0 }) ?? true
            else {
                throw SwiftPodsError("Expanded archive is larger than its declared or configured limit")
            }
            if let outputDescriptor {
                try writeArchiveBlock(
                    buffer, count: count, offset: offset, descriptor: outputDescriptor, deadline: deadline)
            }
            previousEnd = end.partialValue
            logicalSize = end.partialValue
        }
        return logicalSize
    }

    private static func writeArchiveBlock(
        _ buffer: UnsafeRawPointer, count: Int, offset: Int64, descriptor: Int32, deadline: UInt64
    ) throws {
        var written = 0
        while written < count {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw SwiftPodsError("Archive extraction timed out")
            }
            let result = pwrite(
                descriptor, buffer.advanced(by: written), count - written, off_t(offset + Int64(written)))
            if result > 0 {
                written += result
            } else if result < 0, errno == EINTR {
                continue
            } else {
                throw SwiftPodsError("Cannot write an extracted archive file: \(String(cString: strerror(errno)))")
            }
        }
    }

    private static func createArchiveExtractionRoot(at directory: URL) throws -> ArchiveExtractionRoot {
        let parent = directory.deletingLastPathComponent()
        let name = directory.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), name.utf8.count <= Int(NAME_MAX) else {
            throw SwiftPodsError("Archive extraction destination is unsafe")
        }
        let parentDescriptor = parent.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard parentDescriptor >= 0 else {
            throw SwiftPodsError("Cannot safely open the archive extraction parent")
        }
        var parentStatus = stat()
        guard fstat(parentDescriptor, &parentStatus) == 0, SecureFileTree.isDirectory(parentStatus),
            parentStatus.st_uid == geteuid(), parentStatus.st_mode & 0o022 == 0
        else {
            close(parentDescriptor)
            throw SwiftPodsError("Archive extraction parent is not a private owned directory")
        }
        guard name.withCString({ mkdirat(parentDescriptor, $0, 0o700) }) == 0 else {
            let problem = errno
            close(parentDescriptor)
            throw SwiftPodsError("Cannot create a private archive extraction root: \(String(cString: strerror(problem)))")
        }
        let descriptor = name.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            let problem = errno
            close(parentDescriptor)
            throw SwiftPodsError("Cannot open the private archive extraction root: \(String(cString: strerror(problem)))")
        }
        var status = stat()
        var linked = stat()
        guard fstat(descriptor, &status) == 0,
            name.withCString({ fstatat(parentDescriptor, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
            status.st_dev == linked.st_dev, status.st_ino == linked.st_ino,
            SecureFileTree.isDirectory(status), SecureFileTree.isDirectory(linked),
            status.st_uid == geteuid(), status.st_mode & 0o077 == 0, fchflags(descriptor, 0) == 0
        else {
            close(descriptor)
            close(parentDescriptor)
            throw SwiftPodsError("Archive extraction root changed or is not private")
        }
        return ArchiveExtractionRoot(
            parentDescriptor: parentDescriptor, descriptor: descriptor, name: name, status: status)
    }

    private static func verifyArchiveExtractionRoot(_ root: ArchiveExtractionRoot) throws {
        var opened = stat()
        var linked = stat()
        guard fstat(root.descriptor, &opened) == 0,
            root.name.withCString({
                fstatat(root.parentDescriptor, $0, &linked, AT_SYMLINK_NOFOLLOW)
            }) == 0,
            opened.st_dev == root.status.st_dev, opened.st_ino == root.status.st_ino,
            linked.st_dev == root.status.st_dev, linked.st_ino == root.status.st_ino,
            SecureFileTree.isDirectory(opened), SecureFileTree.isDirectory(linked), opened.st_uid == geteuid()
        else { throw SwiftPodsError("Archive extraction root changed while it was populated") }
    }

    private static func withArchiveParentDescriptor<Result>(
        root: Int32, path: [String], _ body: (Int32, String) throws -> Result
    ) throws -> Result {
        guard let name = path.last, !path.isEmpty else {
            throw SwiftPodsError("Archive contains an empty pathname")
        }
        var current = ".".withCString {
            openat(root, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard current >= 0 else { throw SwiftPodsError("Cannot duplicate the archive extraction root") }
        defer { close(current) }
        for component in path.dropLast() {
            let next = try openArchiveDirectory(parent: current, name: component, createIfMissing: true)
            close(current)
            current = next
        }
        return try body(current, name)
    }

    private static func openArchiveDirectory(
        parent: Int32, name: String, createIfMissing: Bool
    ) throws -> Int32 {
        var descriptor = name.withCString {
            openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        if descriptor < 0, errno == ENOENT, createIfMissing {
            let created = name.withCString { mkdirat(parent, $0, 0o700) }
            guard created == 0 || errno == EEXIST else {
                throw SwiftPodsError("Cannot create an extracted archive directory")
            }
            descriptor = name.withCString {
                openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
        }
        guard descriptor >= 0 else { throw SwiftPodsError("Archive path traverses a non-directory or symbolic link") }
        var opened = stat()
        var linked = stat()
        guard fstat(descriptor, &opened) == 0,
            name.withCString({ fstatat(parent, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
            opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino,
            SecureFileTree.isDirectory(opened), SecureFileTree.isDirectory(linked),
            opened.st_uid == geteuid(), opened.st_mode & 0o022 == 0
        else {
            close(descriptor)
            throw SwiftPodsError("Extracted archive directory changed or is unsafe")
        }
        return descriptor
    }

    private static func createArchiveDirectory(root: Int32, path: [String], permissions: mode_t) throws {
        try withArchiveParentDescriptor(root: root, path: path) { parent, name in
            let descriptor = try openArchiveDirectory(parent: parent, name: name, createIfMissing: true)
            defer { close(descriptor) }
            guard fchmod(descriptor, safeArchiveDirectoryMode(permissions)) == 0,
                fchflags(descriptor, 0) == 0
            else { throw SwiftPodsError("Cannot finalize an extracted archive directory") }
        }
    }

    private static func createArchiveFile(root: Int32, path: [String]) throws -> Int32 {
        try withArchiveParentDescriptor(root: root, path: path) { parent, name in
            let descriptor = name.withCString {
                openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            }
            guard descriptor >= 0 else { throw SwiftPodsError("Cannot create an extracted archive file") }
            var opened = stat()
            var linked = stat()
            guard fstat(descriptor, &opened) == 0,
                name.withCString({ fstatat(parent, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
                opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino,
                SecureFileTree.isRegularFile(opened), SecureFileTree.isRegularFile(linked),
                opened.st_uid == geteuid(), opened.st_nlink == 1
            else {
                close(descriptor)
                throw SwiftPodsError("Extracted archive file changed or is unsafe")
            }
            return descriptor
        }
    }

    private static func createArchiveSymbolicLink(
        root: Int32, path: [String], target: String
    ) throws {
        try withArchiveParentDescriptor(root: root, path: path) { parent, name in
            guard target.withCString({ targetPointer in
                name.withCString { namePointer in symlinkat(targetPointer, parent, namePointer) }
            }) == 0 else { throw SwiftPodsError("Cannot create an extracted archive symbolic link") }
            var linked = stat()
            guard name.withCString({ fstatat(parent, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
                SecureFileTree.isSymbolicLink(linked), linked.st_uid == geteuid()
            else { throw SwiftPodsError("Extracted archive symbolic link changed or is unsafe") }
        }
    }

    private static func createArchiveHardLink(
        root: Int32, path: [String], target: [String]
    ) throws {
        try withArchiveParentDescriptor(root: root, path: target) { sourceParent, sourceName in
            var source = stat()
            guard sourceName.withCString({
                fstatat(sourceParent, $0, &source, AT_SYMLINK_NOFOLLOW)
            }) == 0, SecureFileTree.isRegularFile(source), source.st_uid == geteuid() else {
                throw SwiftPodsError("Archive hard link target changed or is unsafe")
            }
            try withArchiveParentDescriptor(root: root, path: path) { destinationParent, destinationName in
                let linked = sourceName.withCString { sourcePointer in
                    destinationName.withCString { destinationPointer in
                        linkat(sourceParent, sourcePointer, destinationParent, destinationPointer, 0)
                    }
                }
                guard linked == 0 else { throw SwiftPodsError("Cannot create an extracted archive hard link") }
                var destination = stat()
                guard destinationName.withCString({
                    fstatat(destinationParent, $0, &destination, AT_SYMLINK_NOFOLLOW)
                }) == 0,
                    SecureFileTree.isRegularFile(destination), destination.st_dev == source.st_dev,
                    destination.st_ino == source.st_ino, destination.st_uid == geteuid()
                else { throw SwiftPodsError("Extracted archive hard link changed or is unsafe") }
            }
        }
    }

    private static func safeArchiveFileMode(_ permissions: mode_t) -> mode_t {
        0o600 | (permissions & 0o155)
    }

    private static func safeArchiveDirectoryMode(_ permissions: mode_t) -> mode_t {
        0o700 | (permissions & 0o055)
    }

    private static func archivePathComponents(
        _ value: String, depth: Int, metadata: inout ArchiveMetadataBudget
    ) throws -> [String] {
        guard !value.hasPrefix("/"), value.utf8.count <= maximumArchiveMetadataBytes,
            value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f })
        else { throw SwiftPodsError("Archive contains an unsafe pathname") }
        var result: [String] = []
        for raw in value.split(separator: "/", omittingEmptySubsequences: true) {
            let component = String(raw)
            if component == "." { continue }
            guard component != "..", !component.isEmpty, component.utf8.count <= Int(NAME_MAX) else {
                throw SwiftPodsError("Archive contains an unsafe pathname")
            }
            result.append(component)
            guard result.count <= depth else {
                throw SwiftPodsError("Archive path is nested too deeply: \(value)")
            }
        }
        let normalized = result.joined(separator: "/")
        guard normalized.utf8.count < Int(PATH_MAX) else {
            throw SwiftPodsError("Archive contains an excessively long pathname")
        }
        // `split` slices retain the source string, while each component and the normalized temporary may allocate its
        // own storage. Charge both representations plus collection elements before they can accumulate in dictionaries.
        try metadata.consume(
            bytes: normalized.utf8.count, copies: 2, objects: result.count + 1)
        return result
    }

    private static func normalizedArchivePathByteCount(_ components: [String]) -> Int {
        guard !components.isEmpty else { return 0 }
        return components.reduce(components.count - 1) { $0 + $1.utf8.count }
    }

    private static func insertArchivePath(
        _ components: [String], kind: ArchiveNodeKind, nodes: inout [String: ArchiveNodeKind],
        fileSystemPaths: inout [String: String], maximumEntries: Int,
        metadata: inout ArchiveMetadataBudget
    ) throws {
        for index in components.indices {
            let prefixCount = components.distance(from: components.startIndex, to: index) + 1
            let prefixBytes = components[...index].reduce(prefixCount - 1) { $0 + $1.utf8.count }
            // Per prefix this covers: joined `path`, canonicalized/lowercased component temporaries, joined collision
            // key, the nodes key, and both key/value strings in fileSystemPaths. Eight object overheads conservatively
            // include the two dictionary buckets and temporary arrays, even when Swift can share backing storage.
            try metadata.consume(bytes: prefixBytes, copies: 12, objects: 8)
            let path = components[...index].joined(separator: "/")
            let key = components[...index]
                .map { $0.precomposedStringWithCanonicalMapping.lowercased() }.joined(separator: "/")
            guard key.utf8.count <= maximumArchiveMetadataBytes else {
                throw SwiftPodsError("Archive contains an excessively long normalized pathname")
            }
            if let existing = fileSystemPaths[key], existing != path {
                throw SwiftPodsError("Archive contains names that collide on macOS: \(existing) and \(path)")
            }
            fileSystemPaths[key] = path
            let final = index == components.index(before: components.endIndex)
            let proposed: ArchiveNodeKind = final ? kind : .implicitDirectory
            if let existing = nodes[path] {
                if final, existing == .implicitDirectory, proposed == .directory {
                    nodes[path] = .directory
                } else if !final, existing.isDirectory {
                    continue
                } else {
                    throw SwiftPodsError("Archive contains duplicate or conflicting entries: \(path)")
                }
            } else {
                nodes[path] = proposed
                guard nodes.count <= maximumEntries else {
                    throw SwiftPodsError("Archive contains too many entries including implicit directories")
                }
            }
        }
    }

    private static func validateArchiveSymbolicLink(
        _ destination: String, from path: [String], maximumDepth: Int
    ) throws {
        guard !destination.hasPrefix("/"), !destination.isEmpty,
            destination.utf8.count <= maximumArchiveMetadataBytes,
            destination.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f })
        else { throw SwiftPodsError("Archive contains an unsafe symbolic-link target") }
        var resolved = Array(path.dropLast())
        for raw in destination.split(separator: "/", omittingEmptySubsequences: true) {
            let component = String(raw)
            if component == "." { continue }
            if component == ".." {
                guard !resolved.isEmpty else {
                    throw SwiftPodsError("Archive symbolic link escapes its root")
                }
                resolved.removeLast()
            } else {
                guard component.utf8.count <= Int(NAME_MAX) else {
                    throw SwiftPodsError("Archive contains an unsafe symbolic-link target")
                }
                resolved.append(component)
                guard resolved.count <= maximumDepth else {
                    throw SwiftPodsError("Archive symbolic-link target is nested too deeply")
                }
            }
        }
        guard resolved.joined(separator: "/").utf8.count < Int(PATH_MAX) else {
            throw SwiftPodsError("Archive contains an excessively long symbolic-link target")
        }
    }

    private static func archiveInspectionError(
        _ reader: OpaquePointer, url: String, status: Int32? = nil
    ) -> SwiftPodsError {
        let detail = boundedArchiveDiagnostic(archive_error_string(reader))
        let statusText = status.map { " (libarchive status \($0))" } ?? ""
        return SwiftPodsError("Cannot inspect \(redacted(url)): \(detail)\(statusText)")
    }

    private static func redacted(_ value: String) -> String {
        // Signed URLs may carry bearer material in user-info, path, query, fragment, or even a generated subdomain.
        // Only the validated scheme is useful enough for diagnostics to retain.
        guard let scheme = URLComponents(string: value)?.scheme?.lowercased(), !scheme.isEmpty else {
            return "the configured URL"
        }
        return "the configured \(scheme) URL"
    }

    /// Applies a deny-by-default Seatbelt profile after every inherited descriptor has been authenticated and before
    /// attacker-controlled bytes reach Foundation or libarchive. Existing descriptors remain usable; extraction gets
    /// pathname access only below its private root. There is deliberately no network, process-exec, user-home or
    /// project-wide read permission.
    private enum ArchiveWorkerSandbox {
        static func apply(extractionRootDescriptor: Int32?) throws {
            var profile = """
                (version 1)
                (deny default)
                (allow file-read-metadata)
                (allow file-read-data
                    (subpath \"/System\")
                    (subpath \"/usr/lib\")
                    (subpath \"/Library/Apple/System/Library\")
                    (literal \"/dev/null\")
                    (literal \"/dev/urandom\"))
                (allow sysctl-read)
                (allow signal (target self))
                """
            if let extractionRootDescriptor {
                let root = try descriptorPath(extractionRootDescriptor)
                let literal = try schemeLiteral(root)
                profile += "\n(allow file-read* (subpath \(literal)))"
                profile += "\n(allow file-write* (subpath \(literal)))"
            }

            var error: UnsafeMutablePointer<CChar>?
            let result = profile.withCString { swiftpodsSandboxInit($0, 0, &error) }
            if let error { swiftpodsSandboxFreeError(error) }
            guard result == 0 else {
                throw SwiftPodsError("Cannot apply the archive worker syscall sandbox")
            }
            try verifyAmbientReadIsDenied()
            try verifyNetworkIsDenied()
        }

        private static func descriptorPath(_ descriptor: Int32) throws -> String {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            let result = buffer.withUnsafeMutableBufferPointer {
                swiftpods_fgetpath(descriptor, $0.baseAddress!)
            }
            guard result == 0, buffer[0] != 0 else {
                throw SwiftPodsError("Cannot resolve the archive worker extraction root")
            }
            return String(
                decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }

        private static func schemeLiteral(_ value: String) throws -> String {
            guard !value.isEmpty, !value.contains("\0"), value.unicodeScalars.allSatisfy({
                $0.value >= 0x20 && $0.value != 0x7f && !(0x80...0x9f).contains($0.value)
            }) else { throw SwiftPodsError("Archive worker extraction root contains unsupported control characters") }
            return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }

        private static func verifyAmbientReadIsDenied() throws {
            let descriptor = "/etc/hosts".withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
            if descriptor >= 0 {
                close(descriptor)
                throw SwiftPodsError("Archive worker syscall sandbox permits ambient file reads")
            }
            guard errno == EPERM || errno == EACCES else {
                throw SwiftPodsError("Cannot verify archive worker ambient-read isolation")
            }
        }

        private static func verifyNetworkIsDenied() throws {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            if descriptor < 0 {
                guard errno == EPERM || errno == EACCES else {
                    throw SwiftPodsError("Cannot verify archive worker network isolation")
                }
                return
            }
            defer { close(descriptor) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(9).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            let problem = errno
            guard result != 0, problem == EPERM || problem == EACCES else {
                throw SwiftPodsError("Archive worker syscall sandbox permits network access")
            }
        }
    }

    /// Entry point used only by the hidden mode of the already-running SwiftPods executable. The parent supplies
    /// authenticated descriptors, never archive or destination pathnames. Resource limits are lowered irreversibly in
    /// this short-lived process before libarchive sees a byte, while ProcessRunner independently enforces wall time and
    /// terminates the complete worker process group.
    fileprivate static func archiveWorkerOutput(arguments: [String]) throws -> Data {
        guard arguments.count == 7, arguments[0] == "1",
            let operation = ArchiveWorkerOperation(rawValue: arguments[1]),
            let receivedArchiveDescriptor = Int32(arguments[2]),
            let receivedRootDescriptor = Int32(arguments[3]),
            let receivedExecutableDescriptor = Int32(arguments[4]),
            let receivedParentPipeDescriptor = Int32(arguments[5]),
            receivedArchiveDescriptor > STDERR_FILENO, receivedExecutableDescriptor > STDERR_FILENO,
            receivedParentPipeDescriptor > STDERR_FILENO,
            receivedRootDescriptor == -1 || receivedRootDescriptor > STDERR_FILENO,
            UUID(uuidString: arguments[6]) != nil,
            Set([receivedArchiveDescriptor, receivedExecutableDescriptor, receivedParentPipeDescriptor]
                + (receivedRootDescriptor >= 0 ? [receivedRootDescriptor] : [])).count
                == (receivedRootDescriptor >= 0 ? 4 : 3),
            (operation == .extract) == (receivedRootDescriptor >= 0)
        else { throw SwiftPodsError("Archive worker received an invalid bounded request") }

        // Descriptor numbers are ambient parent state. In a long-running test host or embedding process they can be
        // above the worker's deliberately small RLIMIT_NOFILE even though only a few capabilities are inherited. Darwin
        // permits fstat() on such an existing descriptor after lowering the limit, but poll() reports POLLNVAL. Move
        // only the explicitly supplied worker capabilities into genuinely free low slots first; F_DUPFD_CLOEXEC preserves
        // unrelated runtime and ProcessRunner tracking descriptors instead of overwriting fixed child numbers.
        let archiveDescriptor = try compactArchiveWorkerDescriptor(receivedArchiveDescriptor)
        var rootDescriptor = receivedRootDescriptor
        if rootDescriptor >= 0 { rootDescriptor = try compactArchiveWorkerDescriptor(rootDescriptor) }
        let executableDescriptor = try compactArchiveWorkerDescriptor(receivedExecutableDescriptor)
        let parentPipeDescriptor = try compactArchiveWorkerDescriptor(receivedParentPipeDescriptor)

        let memoryWatchdog = try ArchiveWorkerMemoryWatchdog(
            maximumPhysicalFootprint: operation == .frameworkInfo
                ? 256 * 1_024 * 1_024 : 512 * 1_024 * 1_024)
        let parentWatchdog = try ArchiveWorkerParentWatchdog(descriptor: parentPipeDescriptor)
        try PinnedArchiveWorkerExecutable.validateInheritedCurrentExecutable(executableDescriptor)

        var archiveStatus = stat()
        let maximumInputBytes = operation == .frameworkInfo
            ? Int64(FrameworkRepair.maximumInfoPlistBytes) : maximumArchiveBytes
        guard fstat(archiveDescriptor, &archiveStatus) == 0,
            SecureFileTree.isRegularFile(archiveStatus), archiveStatus.st_size >= 0,
            archiveStatus.st_size <= maximumInputBytes,
            fcntl(archiveDescriptor, F_GETFL) & O_ACCMODE == O_RDONLY,
            fcntl(executableDescriptor, F_GETFL) & O_ACCMODE == O_RDONLY
        else { throw SwiftPodsError("Archive worker did not receive a bounded regular archive") }

        let extractionRoot: Int32?
        var initialRootStatus: stat?
        if rootDescriptor >= 0 {
            var rootStatus = stat()
            guard fstat(rootDescriptor, &rootStatus) == 0, SecureFileTree.isDirectory(rootStatus),
                rootStatus.st_uid == geteuid(), rootStatus.st_mode & 0o077 == 0,
                fcntl(rootDescriptor, F_GETFL) & O_ACCMODE == O_RDONLY
            else { throw SwiftPodsError("Archive worker did not receive a private owned extraction directory") }
            initialRootStatus = rootStatus
            extractionRoot = rootDescriptor
        } else {
            extractionRoot = nil
        }

        try ArchiveWorkerSandbox.apply(extractionRootDescriptor: extractionRoot)
        // Seatbelt and the watchdog queues lazily initialize system libraries and allocator arenas. Measuring the
        // virtual baseline before that trusted setup makes sandbox_init sporadically fail with ENOMEM on macOS 15.
        // The parent already bounds physical memory and wall time during startup; lower all worker limits only after
        // setup, still before the first attacker-controlled archive/plist byte reaches any parser.
        try applyArchiveWorkerResourceLimits(
            additionalAddressBytes: operation == .frameworkInfo
                ? 256 * 1_024 * 1_024 : 512 * 1_024 * 1_024)
        let inspection: ArchiveInspection?
        let frameworkLibraries: [FrameworkLibraryMetadata]?
        switch operation {
        case .inspect, .extract:
            inspection = try processArchive(
                descriptor: archiveDescriptor, url: "authenticated binary archive", limits: .archive,
                inspectionTimeout: commandTimeout, extractionRoot: extractionRoot)
            frameworkLibraries = nil
        case .frameworkInfo:
            inspection = nil
            frameworkLibraries = try FrameworkRepair.decodeInfoPlist(descriptor: archiveDescriptor)
        }
        var finalArchiveStatus = stat()
        guard fstat(archiveDescriptor, &finalArchiveStatus) == 0,
            finalArchiveStatus.st_dev == archiveStatus.st_dev,
            finalArchiveStatus.st_ino == archiveStatus.st_ino,
            finalArchiveStatus.st_mode == archiveStatus.st_mode,
            finalArchiveStatus.st_uid == archiveStatus.st_uid,
            finalArchiveStatus.st_gid == archiveStatus.st_gid,
            finalArchiveStatus.st_nlink == archiveStatus.st_nlink,
            finalArchiveStatus.st_size == archiveStatus.st_size,
            finalArchiveStatus.st_mtimespec.tv_sec == archiveStatus.st_mtimespec.tv_sec,
            finalArchiveStatus.st_mtimespec.tv_nsec == archiveStatus.st_mtimespec.tv_nsec,
            finalArchiveStatus.st_ctimespec.tv_sec == archiveStatus.st_ctimespec.tv_sec,
            finalArchiveStatus.st_ctimespec.tv_nsec == archiveStatus.st_ctimespec.tv_nsec
        else { throw SwiftPodsError("Archive worker input changed while it was being processed") }
        if let initialRootStatus {
            var finalRootStatus = stat()
            guard fstat(rootDescriptor, &finalRootStatus) == 0,
                finalRootStatus.st_dev == initialRootStatus.st_dev,
                finalRootStatus.st_ino == initialRootStatus.st_ino,
                finalRootStatus.st_mode == initialRootStatus.st_mode,
                finalRootStatus.st_uid == initialRootStatus.st_uid,
                finalRootStatus.st_gid == initialRootStatus.st_gid,
                SecureFileTree.isDirectory(finalRootStatus)
            else { throw SwiftPodsError("Archive worker extraction root changed while it was populated") }
        }
        let response = ArchiveWorkerResponse(
            protocolVersion: 1, nonce: arguments[6].lowercased(), inspection: inspection,
            frameworkLibraries: frameworkLibraries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let output = try encoder.encode(response)
        guard output.count <= 128 * 1_024 else {
            throw SwiftPodsError("Archive worker response exceeded its fixed limit")
        }
        return withExtendedLifetime(memoryWatchdog) {
            withExtendedLifetime(parentWatchdog) { output }
        }
    }

    /// Packaging-only smoke path. It deliberately accepts only one local archive and a digest, extracts into an owned
    /// temporary cache through the same BinaryStore two-pass path as install, and validates a fixed sentinel without
    /// exposing a caller-selected destination or any network-capable input.
    fileprivate static func archiveParentProbeOutput(arguments: [String]) throws -> Data {
        guard arguments.count == 3, arguments[0] == "1", isValidSHA256(arguments[2]) else {
            throw SwiftPodsError("Archive parent probe received an invalid bounded request")
        }
        let archive = URL(fileURLWithPath: arguments[1]).standardizedFileURL
        guard archive.path.hasPrefix("/"), !archive.path.contains("\0") else {
            throw SwiftPodsError("Archive parent probe requires an absolute local archive path")
        }
        let descriptor = archive.path.withCString {
            open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw SwiftPodsError("Archive parent probe cannot open its local archive") }
        var archiveStatus = stat()
        let validArchive = fstat(descriptor, &archiveStatus) == 0 && SecureFileTree.isRegularFile(archiveStatus)
            && archiveStatus.st_size >= 0 && archiveStatus.st_size <= maximumArchiveBytes
        close(descriptor)
        guard validArchive else { throw SwiftPodsError("Archive parent probe requires a bounded regular archive") }

        var template = Array(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("swiftpods-archive-parent-probe.XXXXXX").path.utf8CString)
        guard template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress) }) != nil else {
            throw SwiftPodsError("Archive parent probe cannot create its private temporary directory")
        }
        let temporaryPath = String(
            decoding: template.lazy.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let temporary = URL(fileURLWithPath: temporaryPath, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let copiedArchive = temporary.appendingPathComponent("archive.tar.gz")
        try FileManager.default.copyItem(at: archive, to: copiedArchive)
        let podfile = temporary.appendingPathComponent("Podfile")
        try "target 'Probe' do\n  binary 'Kit', url: '\(copiedArchive.absoluteString)', sha256: '\(arguments[2].lowercased())'\nend\n"
            .write(to: podfile, atomically: true, encoding: .utf8)
        guard let binary = try Installer(directory: temporary).manifest().binaries.first else {
            throw SwiftPodsError("Archive parent probe could not construct its local binary declaration")
        }
        let contents = try BinaryStore(
            cache: temporary.appendingPathComponent("cache", isDirectory: true), runner: ProcessRunner(), offline: false,
            minimumFreeSpaceReserveBytes: 0
        ).contents(binary, podfileDirectory: temporary)
        guard contents.xcframeworks.count == 1,
            contents.xcframeworks[0].lastPathComponent == "Kit.xcframework"
        else { throw SwiftPodsError("Archive parent probe did not extract its expected framework") }
        let sentinel = contents.xcframeworks[0].appendingPathComponent("Info.plist")
        let sentinelDescriptor = sentinel.path.withCString {
            open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard sentinelDescriptor >= 0 else {
            throw SwiftPodsError("Archive parent probe did not extract its expected sentinel")
        }
        defer { close(sentinelDescriptor) }
        var sentinelStatus = stat()
        guard fstat(sentinelDescriptor, &sentinelStatus) == 0, SecureFileTree.isRegularFile(sentinelStatus),
            sentinelStatus.st_size == Int64("worker-smoke".utf8.count)
        else { throw SwiftPodsError("Archive parent probe extracted an invalid sentinel") }
        var sentinelBytes = [UInt8](repeating: 0, count: Int(sentinelStatus.st_size))
        var offset = 0
        while offset < sentinelBytes.count {
            let readCount = sentinelBytes.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    sentinelDescriptor, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
            }
            if readCount < 0, errno == EINTR { continue }
            guard readCount > 0 else {
                throw SwiftPodsError("Archive parent probe extracted unreadable sentinel bytes")
            }
            offset += readCount
        }
        var extra = UInt8()
        var extraCount: Int
        repeat { extraCount = Darwin.read(sentinelDescriptor, &extra, 1) } while extraCount < 0 && errno == EINTR
        var finalSentinelStatus = stat()
        guard extraCount == 0, fstat(sentinelDescriptor, &finalSentinelStatus) == 0,
            finalSentinelStatus.st_dev == sentinelStatus.st_dev,
            finalSentinelStatus.st_ino == sentinelStatus.st_ino,
            finalSentinelStatus.st_mode == sentinelStatus.st_mode,
            finalSentinelStatus.st_uid == sentinelStatus.st_uid,
            finalSentinelStatus.st_gid == sentinelStatus.st_gid,
            finalSentinelStatus.st_nlink == sentinelStatus.st_nlink,
            finalSentinelStatus.st_size == sentinelStatus.st_size,
            finalSentinelStatus.st_mtimespec.tv_sec == sentinelStatus.st_mtimespec.tv_sec,
            finalSentinelStatus.st_mtimespec.tv_nsec == sentinelStatus.st_mtimespec.tv_nsec,
            finalSentinelStatus.st_ctimespec.tv_sec == sentinelStatus.st_ctimespec.tv_sec,
            finalSentinelStatus.st_ctimespec.tv_nsec == sentinelStatus.st_ctimespec.tv_nsec,
            sentinelBytes == Array("worker-smoke".utf8)
        else {
            throw SwiftPodsError("Archive parent probe extracted unexpected sentinel bytes")
        }
        let output = try JSONSerialization.data(
            withJSONObject: ["protocolVersion": 1, "bytes": sentinelBytes.count], options: [.sortedKeys])
        guard output.count <= 1_024 else { throw SwiftPodsError("Archive parent probe response exceeded its limit") }
        return output
    }

    private static let archiveWorkerOpenFileLimit: Int32 = 32

    private static func compactArchiveWorkerDescriptor(_ descriptor: Int32) throws -> Int32 {
        guard descriptor >= archiveWorkerOpenFileLimit else { return descriptor }
        let compacted = fcntl(descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
        guard compacted >= 0 else {
            throw SwiftPodsError("Cannot compact an inherited archive worker descriptor")
        }
        guard compacted < archiveWorkerOpenFileLimit else {
            close(compacted)
            throw SwiftPodsError("Archive worker has no free descriptor below its open-file limit")
        }
        guard close(descriptor) == 0 else {
            let problem = errno
            close(compacted)
            throw SwiftPodsError(
                "Cannot retire an inherited archive worker descriptor: \(String(cString: strerror(problem)))")
        }
        return compacted
    }

    private static func applyArchiveWorkerResourceLimits(additionalAddressBytes: UInt64) throws {
        // RLIMIT_AS is defense in depth: macOS may reserve virtual address ranges without committing equivalent
        // physical memory, so the parent separately polls the worker's current and lifetime-peak physical footprint.
        // Archive callers keep 512 MiB above baseline for xz dictionaries and Swift/libarchive overhead; the bounded
        // framework-plist parser uses the smaller 256 MiB allowance supplied by its operation.
        let virtualSize = try archiveWorkerVirtualSize()
        let addressLimit = virtualSize.addingReportingOverflow(additionalAddressBytes)
        guard !addressLimit.overflow else { throw SwiftPodsError("Archive worker address-space limit overflowed") }
        try lowerArchiveWorkerLimit(RLIMIT_AS, to: rlim_t(addressLimit.partialValue))
        try lowerArchiveWorkerLimit(RLIMIT_CPU, to: rlim_t(commandTimeout.rounded(.up)) + 5)
        try lowerArchiveWorkerLimit(RLIMIT_FSIZE, to: rlim_t(SecureFileTree.Limits.archive.bytes))
        try lowerArchiveWorkerLimit(RLIMIT_NOFILE, to: rlim_t(archiveWorkerOpenFileLimit))
        try lowerArchiveWorkerLimit(RLIMIT_NPROC, to: 1)
        try lowerArchiveWorkerLimit(RLIMIT_CORE, to: 0)
    }

    private static func archiveWorkerVirtualSize() throws -> UInt64 {
        var information = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw SwiftPodsError("Cannot measure the archive worker address space")
        }
        return information.virtual_size
    }

    private static func lowerArchiveWorkerLimit(_ resource: Int32, to target: rlim_t) throws {
        var limit = rlimit()
        guard getrlimit(resource, &limit) == 0 else {
            throw SwiftPodsError("Cannot read an archive worker resource limit")
        }
        let hard = min(limit.rlim_max, target)
        limit.rlim_cur = min(limit.rlim_cur, hard)
        limit.rlim_max = hard
        guard setrlimit(resource, &limit) == 0 else {
            throw SwiftPodsError("Cannot enforce an archive worker resource limit")
        }
    }

    /// Hashes in chunks, draining autoreleased buffers per chunk so memory stays flat for large archives.
    static func sha256(of file: URL) throws -> String {
        let descriptor = file.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { throw SwiftPodsError("Cannot safely open \(file.path): \(String(cString: strerror(errno)))") }
        var status = stat()
        guard fstat(descriptor, &status) == 0, SecureFileTree.isRegularFile(status), status.st_size >= 0,
            status.st_size <= maximumArchiveBytes
        else {
            close(descriptor)
            throw SwiftPodsError("Expected a bounded regular archive at \(file.path)")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = status.st_size
        while remaining > 0 {
            let finished = try autoreleasepool { () throws -> Bool in
                guard let chunk = try handle.read(upToCount: min(1 << 20, Int(remaining))), !chunk.isEmpty else {
                    return true
                }
                remaining -= Int64(chunk.count)
                hasher.update(data: chunk)
                return false
            }
            if finished { throw SwiftPodsError("Archive was truncated while it was hashed") }
        }
        let extra = try handle.read(upToCount: 1)
        var final = stat()
        guard fstat(descriptor, &final) == 0, final.st_dev == status.st_dev, final.st_ino == status.st_ino,
            final.st_mode == status.st_mode, final.st_nlink == status.st_nlink, final.st_size == status.st_size,
            final.st_mtimespec.tv_sec == status.st_mtimespec.tv_sec,
            final.st_mtimespec.tv_nsec == status.st_mtimespec.tv_nsec,
            final.st_ctimespec.tv_sec == status.st_ctimespec.tv_sec,
            final.st_ctimespec.tv_nsec == status.st_ctimespec.tv_nsec,
            remaining == 0, extra?.isEmpty != false
        else { throw SwiftPodsError("Archive changed while it was hashed") }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
