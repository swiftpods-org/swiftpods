/// An evaluated Podfile: groups applied, inheritance resolved, declarations checked.
public struct Manifest: Sendable, Codable, Equatable {
    /// The Podfile that was read.
    public var file: String
    /// Catalogs that resolve package names, in lookup order.
    public var sources: [Source]
    /// Every distinct Swift package, in declaration order.
    public var packages: [Package]
    /// Every distinct binary SDK, in declaration order.
    public var binaries: [Binary]
    /// Concrete Xcode targets, in declaration order.
    public var targets: [Target]
}

public enum PlatformName: String, Sendable, Codable, CaseIterable {
    case ios, macos, tvos, watchos, visionos
}

public struct Platform: Sendable, Codable, Equatable {
    public var name: PlatformName
    public var deploymentTarget: String?

    public init(name: PlatformName, deploymentTarget: String?) {
        self.name = name
        self.deploymentTarget = deploymentTarget
    }
}

public struct Package: Sendable, Codable, Equatable {
    public enum Location: Sendable, Codable, Equatable {
        case remote(url: String)
        /// Relative to the directory of the Podfile.
        case local(path: String)
    }

    public var name: String
    public var location: Location
    /// Nil exactly for local packages.
    public var requirement: Requirement?
    /// Swift Package Manager's identity; products refer to packages by it.
    public var identity: String
    /// The catalog that supplied the location, when the Podfile named the package only.
    public var catalog: String?
    public var declaredAt: SourceLocation
}

public struct Binary: Sendable, Codable, Equatable {
    public enum Source: Sendable, Codable, Equatable {
        case remote(url: String, sha256: String)
        /// Relative to the directory of the Podfile: an `.xcframework` or a directory containing some.
        case local(path: String)
    }

    public var name: String
    public var source: Source
    /// Paths inside the archive or directory; nil selects every `.xcframework`.
    public var xcframeworks: [String]?
    public var systemFrameworks: [String]
    public var libraries: [String]
    public var linkerFlags: [String]
    /// Names of other binaries this one requires.
    public var dependencies: [String]
    /// Resource bundles inside the archive or directory, copied into the app bundle of targets that link the binary.
    public var resources: [String]
    public var declaredAt: SourceLocation
}

public struct ProductUse: Sendable, Codable, Equatable, Hashable {
    /// The package's identity.
    public var package: String
    public var product: String
    public var link: Bool

    public init(package: String, product: String, link: Bool) {
        self.package = package
        self.product = product
        self.link = link
    }
}

public struct BuildSetting: Sendable, Codable, Equatable {
    public var key: String
    public var value: String
    /// Nil applies to every configuration.
    public var configurations: [String]?
    public var declaredAt: SourceLocation
}

public struct ScriptPhase: Sendable, Codable, Equatable {
    public enum Position: String, Sendable, Codable {
        case beforeCompile = "before_compile"
        case afterCompile = "after_compile"
        case any
    }

    public var name: String
    public var script: String
    public var shellPath: String
    public var inputFiles: [String]
    public var outputFiles: [String]
    public var inputFileLists: [String]
    public var outputFileLists: [String]
    public var position: Position
    public var basedOnDependencyAnalysis: Bool
    public var showEnvironmentInLog: Bool
    public var declaredAt: SourceLocation
}

public struct Target: Sendable, Codable, Equatable {
    public var name: String
    /// Relative to the directory of the Podfile; nil means the only project next to it.
    public var project: String?
    public var platform: Platform?
    public var products: [ProductUse]
    /// Names of binaries the target links.
    public var binaries: [String]
    public var settings: [BuildSetting]
    public var scriptPhases: [ScriptPhase]
    public var declaredAt: SourceLocation
}
