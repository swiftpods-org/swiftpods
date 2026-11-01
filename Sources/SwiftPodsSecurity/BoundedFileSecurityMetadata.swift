import Darwin
import Foundation

/// Descriptor-anchored ACL/xattr snapshots used when replacing trusted workspace files. Extended attributes may
/// contain arbitrarily large resource forks, so every allocation and copy is preceded by an explicit ceiling.
package enum BoundedFileSecurityMetadata {
    package struct Limits: Sendable {
        package let maximumAttributeNamesBytes: Int
        package let maximumAttributeCount: Int
        package let maximumAttributeValueBytes: Int
        package let maximumAggregateAttributeValueBytes: Int
        package let maximumACLEntries: Int
        package let maximumACLBytes: Int

        package init(
            maximumAttributeNamesBytes: Int,
            maximumAttributeCount: Int,
            maximumAttributeValueBytes: Int,
            maximumAggregateAttributeValueBytes: Int,
            maximumACLEntries: Int,
            maximumACLBytes: Int
        ) {
            self.maximumAttributeNamesBytes = maximumAttributeNamesBytes
            self.maximumAttributeCount = maximumAttributeCount
            self.maximumAttributeValueBytes = maximumAttributeValueBytes
            self.maximumAggregateAttributeValueBytes = maximumAggregateAttributeValueBytes
            self.maximumACLEntries = maximumACLEntries
            self.maximumACLBytes = maximumACLBytes
        }

        package static let standard = Limits(
            maximumAttributeNamesBytes: 64 * 1_024,
            maximumAttributeCount: 128,
            maximumAttributeValueBytes: 8 * 1_024 * 1_024,
            maximumAggregateAttributeValueBytes: 16 * 1_024 * 1_024,
            maximumACLEntries: 128,
            maximumACLBytes: 256 * 1_024)
    }

    package struct Attribute: Codable, Equatable, Sendable {
        package let name: String
        package let value: Data

        package init(name: String, value: Data) {
            self.name = name
            self.value = value
        }
    }

    package struct Snapshot: Equatable, Sendable {
        package let attributes: [Attribute]
        package let acl: Data
        fileprivate let state: DescriptorState
    }

    package struct Failure: Error, CustomStringConvertible, Sendable {
        package let description: String

        fileprivate init(_ description: String) {
            self.description = description
        }
    }

    fileprivate struct DescriptorState: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let links: UInt64
        let owner: UInt32
        let group: UInt32
        let flags: UInt32
        let size: Int64
        let blocks: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ status: stat) {
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
            mode = UInt32(status.st_mode)
            links = UInt64(status.st_nlink)
            owner = status.st_uid
            group = status.st_gid
            flags = status.st_flags
            size = status.st_size
            blocks = status.st_blocks
            modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            changedSeconds = Int64(status.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        }
    }

    package static func capture(
        _ descriptor: Int32, limits: Limits = .standard
    ) throws -> Snapshot {
        try validate(limits)
        let initial = try descriptorState(descriptor)
        let attributes = try readAttributes(descriptor, limits: limits)
        let acl = try readACL(descriptor, limits: limits)
        let final = try descriptorState(descriptor)
        guard final == initial else {
            throw Failure("File security metadata changed while it was inspected")
        }
        return Snapshot(attributes: attributes, acl: acl, state: final)
    }

    /// Copies only a previously bounded in-memory snapshot. The source is rechecked after the destination has been
    /// populated, so a same-UID writer cannot swap in a large resource fork between validation and copying.
    @discardableResult
    package static func copy(
        from source: Int32, to destination: Int32, limits: Limits = .standard
    ) throws -> Snapshot {
        let snapshot = try capture(source, limits: limits)
        try replace(snapshot, on: destination, limits: limits)
        try requireUnchanged(source, since: snapshot)
        return snapshot
    }

    package static func replace(
        _ snapshot: Snapshot, on descriptor: Int32, limits: Limits = .standard
    ) throws {
        try validate(limits)
        guard snapshot.attributes.count <= limits.maximumAttributeCount,
            snapshot.acl.count <= limits.maximumACLBytes
        else { throw Failure("File security metadata exceeds configured limits") }

        var aggregate = 0
        for attribute in snapshot.attributes {
            guard attribute.value.count <= limits.maximumAttributeValueBytes else {
                throw Failure("Extended attribute value exceeds the configured limit")
            }
            let (next, overflow) = aggregate.addingReportingOverflow(attribute.value.count)
            guard !overflow, next <= limits.maximumAggregateAttributeValueBytes else {
                throw Failure("Aggregate extended attribute values exceed the configured limit")
            }
            aggregate = next
        }

        let initial = try descriptorState(descriptor)
        let existingNames = try readAttributeNames(descriptor, limits: limits)
        guard try descriptorState(descriptor) == initial else {
            throw Failure("Destination security metadata changed while it was inspected")
        }
        for name in existingNames {
            guard name.withCString({ fremovexattr(descriptor, $0, 0) }) == 0 else {
                throw Failure("Cannot remove destination extended attribute: \(failureDescription())")
            }
        }
        for attribute in snapshot.attributes {
            let result = attribute.value.withUnsafeBytes { bytes in
                attribute.name.withCString {
                    fsetxattr(descriptor, $0, bytes.baseAddress, bytes.count, 0, 0)
                }
            }
            guard result == 0 else {
                throw Failure("Cannot restore extended attribute: \(failureDescription())")
            }
        }
        try applyACL(snapshot.acl, to: descriptor, limits: limits)

        let restored = try capture(descriptor, limits: limits)
        guard restored.attributes == snapshot.attributes, restored.acl == snapshot.acl else {
            throw Failure("Restored file security metadata does not match its bounded snapshot")
        }
    }

    package static func requireUnchanged(_ descriptor: Int32, since snapshot: Snapshot) throws {
        guard try descriptorState(descriptor) == snapshot.state else {
            throw Failure("File security metadata source changed while it was copied")
        }
    }

    /// Revalidates a prepared destination after its data fork or ordinary stat metadata has intentionally changed.
    /// Only the ACL/xattrs are compared; capture still bounds them and verifies the descriptor around the scan.
    package static func requireEquivalentMetadata(
        _ descriptor: Int32, to snapshot: Snapshot, limits: Limits = .standard
    ) throws {
        let current = try capture(descriptor, limits: limits)
        guard current.attributes == snapshot.attributes, current.acl == snapshot.acl else {
            throw Failure("Prepared file security metadata changed before publication")
        }
    }

    private static func validate(_ limits: Limits) throws {
        guard limits.maximumAttributeNamesBytes >= 0, limits.maximumAttributeCount >= 0,
            limits.maximumAttributeValueBytes >= 0, limits.maximumAggregateAttributeValueBytes >= 0,
            limits.maximumACLEntries >= 0, limits.maximumACLBytes >= 0
        else { throw Failure("File security metadata limits are invalid") }
    }

    private static func descriptorState(_ descriptor: Int32) throws -> DescriptorState {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw Failure("Cannot inspect file security metadata descriptor: \(failureDescription())")
        }
        return DescriptorState(status)
    }

    private static func readAttributes(_ descriptor: Int32, limits: Limits) throws -> [Attribute] {
        let names = try readAttributeNames(descriptor, limits: limits)
        var aggregate = 0
        var result: [Attribute] = []
        result.reserveCapacity(names.count)
        for name in names {
            errno = 0
            let length = name.withCString { fgetxattr(descriptor, $0, nil, 0, 0, 0) }
            guard length >= 0 else {
                throw Failure("Cannot inspect extended attribute: \(failureDescription())")
            }
            guard length <= limits.maximumAttributeValueBytes else {
                throw Failure("Extended attribute value exceeds the configured limit")
            }
            let (next, overflow) = aggregate.addingReportingOverflow(length)
            guard !overflow, next <= limits.maximumAggregateAttributeValueBytes else {
                throw Failure("Aggregate extended attribute values exceed the configured limit")
            }
            aggregate = next
            var value = Data(count: length)
            let actual = value.withUnsafeMutableBytes { bytes in
                name.withCString {
                    fgetxattr(descriptor, $0, bytes.baseAddress, bytes.count, 0, 0)
                }
            }
            guard actual == length else {
                throw Failure("Extended attribute changed while it was inspected")
            }
            result.append(Attribute(name: name, value: value))
        }
        return result
    }

    private static func readAttributeNames(_ descriptor: Int32, limits: Limits) throws -> [String] {
        errno = 0
        let length = flistxattr(descriptor, nil, 0, 0)
        guard length >= 0 else {
            throw Failure("Cannot inspect extended attribute names: \(failureDescription())")
        }
        guard length <= limits.maximumAttributeNamesBytes else {
            throw Failure("Extended attribute name list exceeds the configured limit")
        }
        guard length > 0 else { return [] }
        var bytes = [CChar](repeating: 0, count: length)
        let actual = bytes.withUnsafeMutableBufferPointer {
            flistxattr(descriptor, $0.baseAddress, $0.count, 0)
        }
        guard actual == length else {
            throw Failure("Extended attribute names changed while they were inspected")
        }

        var names: [String] = []
        var offset = 0
        while offset < bytes.count {
            guard names.count < limits.maximumAttributeCount,
                let end = bytes[offset...].firstIndex(of: 0), end > offset
            else {
                if names.count >= limits.maximumAttributeCount {
                    throw Failure("File has too many extended attributes")
                }
                throw Failure("File has malformed extended attribute names")
            }
            let name = bytes.withUnsafeBufferPointer { buffer -> String? in
                guard let base = buffer.baseAddress else { return nil }
                return String(validatingCString: base.advanced(by: offset))
            }
            guard let name else { throw Failure("File has an invalid extended attribute name") }
            names.append(name)
            offset = end + 1
        }
        names.sort { Data($0.utf8).lexicographicallyPrecedes(Data($1.utf8)) }
        for index in names.indices.dropFirst() where names[index] == names[names.index(before: index)] {
            throw Failure("File has duplicate extended attribute names")
        }
        return names
    }

    private static func readACL(_ descriptor: Int32, limits: Limits) throws -> Data {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            let failure = errno
            if failure == ENOENT || failure == ENOTSUP || failure == EOPNOTSUPP { return Data() }
            throw Failure("Cannot inspect file ACL: \(String(cString: strerror(failure)))")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }

        var entries = 0
        var selector = Int32(ACL_FIRST_ENTRY.rawValue)
        var readEntry = false
        while true {
            var entry: acl_entry_t?
            errno = 0
            let result = acl_get_entry(acl, selector, &entry)
            let failure = errno
            if result != 0, readEntry, selector == Int32(ACL_NEXT_ENTRY.rawValue), failure == EINVAL {
                break
            }
            guard result == 0 else {
                throw Failure("Cannot inspect file ACL entries: \(String(cString: strerror(failure)))")
            }
            guard entry != nil else { break }
            readEntry = true
            entries += 1
            guard entries <= limits.maximumACLEntries else {
                throw Failure("File ACL has too many entries")
            }
            selector = Int32(ACL_NEXT_ENTRY.rawValue)
        }
        guard entries > 0 else { return Data() }

        let binaryLength = acl_size(acl)
        guard binaryLength >= 0, binaryLength <= limits.maximumACLBytes else {
            throw Failure("File ACL exceeds the configured limit")
        }
        var textLength: ssize_t = 0
        guard let text = acl_to_text(acl, &textLength), textLength >= 0 else {
            throw Failure("Cannot serialize file ACL")
        }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        guard textLength <= limits.maximumACLBytes else {
            throw Failure("Serialized file ACL exceeds the configured limit")
        }
        return Data(bytes: text, count: textLength)
    }

    private static func applyACL(_ data: Data, to descriptor: Int32, limits: Limits) throws {
        guard data.count <= limits.maximumACLBytes else {
            throw Failure("Serialized file ACL exceeds the configured limit")
        }
        let acl: acl_t?
        if data.isEmpty {
            acl = acl_init(0)
        } else {
            var text = [CChar](repeating: 0, count: data.count + 1)
            _ = text.withUnsafeMutableBytes { destination in
                data.copyBytes(to: destination.bindMemory(to: UInt8.self))
            }
            acl = text.withUnsafeBufferPointer { acl_from_text($0.baseAddress) }
        }
        guard let acl else { throw Failure("Cannot deserialize file ACL") }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        errno = 0
        let result = acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED)
        let failure = errno
        if result == 0 { return }
        if data.isEmpty, failure == ENOTSUP || failure == EOPNOTSUPP { return }
        throw Failure("Cannot restore file ACL: \(String(cString: strerror(failure)))")
    }

    private static func failureDescription() -> String {
        String(cString: strerror(errno))
    }
}
