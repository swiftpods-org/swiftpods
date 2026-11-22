import Foundation

/// Only these top-level directories belong to the SwiftPM/Xcode resolver rather than generated package payload.
enum GeneratedPackageMetadata {
    static let overridesDirectory = "Overrides"
    static let overridesMarker = ".swiftpods-overrides-owner"
    static let overridesOwnership = "swiftpods-generated-overrides-v1\n"
    static let directories: Set<String> = [".build", ".swiftpm"]

    enum Layout {
        case none, package, overrides

        init(_ name: String) {
            switch name {
            case DependencyPackage.directoryName, BinaryPackage.directoryName: self = .package
            case GeneratedPackageMetadata.overridesDirectory: self = .overrides
            default: self = .none
            }
        }

        var resolverRootDepth: Int? {
            switch self {
            case .none: nil
            case .package: 1
            case .overrides: 2
            }
        }

        func contains(_ relative: String) -> Bool {
            switch self {
            case .none: false
            case .package: GeneratedPackageMetadata.contains(relative)
            case .overrides:
                relative.firstIndex(of: "/").map {
                    GeneratedPackageMetadata.contains(String(relative[relative.index(after: $0)...]))
                } ?? false
            }
        }

        func isResolverRoot(_ relative: String) -> Bool {
            contains(relative) && relative.split(separator: "/").count == resolverRootDepth
        }

        func isPackageRoot(_ relative: String) -> Bool {
            switch self {
            case .none: false
            case .package: relative.isEmpty
            case .overrides:
                !relative.isEmpty && relative != GeneratedPackageMetadata.overridesMarker && !relative.contains("/")
            }
        }
    }

    static func contains(_ relative: String) -> Bool {
        directories.contains(String(relative.prefix { $0 != "/" }))
    }
}
