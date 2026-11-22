import Foundation

/// Names in generated package directories. Xcode and SwiftPM write `.build` and `.swiftpm` into local packages;
/// those belong to the resolver, not to what SwiftPods generates.
enum GeneratedPackageMetadata {
    static let overridesDirectory = "Overrides"
    static let overridesMarker = ".swiftpods-overrides-owner"
    static let overridesOwnership = "swiftpods-generated-overrides-v1\n"
    static let directories: Set<String> = [".build", ".swiftpm"]

    static func contains(_ relative: String) -> Bool {
        directories.contains(String(relative.prefix { $0 != "/" }))
    }
}
