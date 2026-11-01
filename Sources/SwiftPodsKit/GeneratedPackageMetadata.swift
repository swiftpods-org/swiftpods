import Foundation

/// Only these top-level directories belong to the SwiftPM/Xcode resolver rather than generated package payload.
enum GeneratedPackageMetadata {
    static let directories: Set<String> = [".build", ".swiftpm"]

    static func isPackage(_ name: String) -> Bool {
        name == DependencyPackage.directoryName || name == BinaryPackage.directoryName
    }

    static func contains(_ relative: String) -> Bool {
        directories.contains(String(relative.prefix { $0 != "/" }))
    }
}
