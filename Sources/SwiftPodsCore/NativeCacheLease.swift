import Foundation
import Darwin

/// Source operations hold a shared lease; inspection/cleanup get a consistent
/// exclusive snapshot. Per-object locks still serialize concurrent publishers.
final class NativeCacheLease {
    private var descriptor: Int32 = -1
    init(cache: URL, exclusive: Bool) throws {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        descriptor = open(cache.appendingPathComponent("sources.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Diagnostic("SP-CACHE-LOCK", stage: "cache", "Cannot open source cache lease") }
        do { try Self.lock(descriptor, exclusive ? LOCK_EX : LOCK_SH, failIfBusy: exclusive) }
        catch { close(descriptor); descriptor = -1; throw error }
    }
    static func lock(_ descriptor: Int32, _ mode: Int32, failIfBusy: Bool = false) throws {
        while flock(descriptor, mode | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw Diagnostic("SP-CACHE-LOCK", stage: "cache", "Cannot acquire cache lock") }
            if failIfBusy { throw Diagnostic("SP-CACHE-BUSY", stage: "cache", "Cached sources are in use by an active operation; retry after it completes") }
            try NativeCancellation.check(); usleep(25_000)
        }
    }
    deinit { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) } }
}
