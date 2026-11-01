import Foundation

/// The exact bytes of a Podfile or include that were parsed successfully.
public struct ManifestFile: Sendable, Equatable {
    public var path: String
    public var contents: Data

    public init(path: String, contents: Data) {
        self.path = path
        self.contents = contents
    }
}

/// An evaluated Podfile: groups applied, inheritance resolved, declarations checked.
public struct Manifest: Sendable, Codable, Equatable {
    /// The Podfile that was read.
    public var file: String
    /// The exact parsed snapshots, starting with the root Podfile and followed by includes in reading order.
    public var files: [ManifestFile]
    /// Files the Podfile included, in reading order.
    public var includes: [String]
    /// Catalogs that resolve package names, in lookup order.
    public var sources: [Source]
    /// Every distinct Swift package, in declaration order.
    public var packages: [Package]
    /// Every distinct binary SDK, in declaration order.
    public var binaries: [Binary]
    /// Concrete Xcode targets, in declaration order.
    public var targets: [Target]
    /// Production filesystem readers retain descriptor-backed snapshots here. The closure is deliberately omitted
    /// from Codable and equality: it is a process-local capability, not manifest data.
    private var verifyFileSnapshotsBody: (@Sendable () throws -> Void)?

    private enum CodingKeys: String, CodingKey {
        case file, includes, sources, packages, binaries, targets
    }

    init(
        file: String, files: [ManifestFile], includes: [String], sources: [Source], packages: [Package], binaries: [Binary],
        targets: [Target], verifyFileSnapshots: (@Sendable () throws -> Void)? = nil
    ) {
        self.file = file
        self.files = files
        self.includes = includes
        self.sources = sources
        self.packages = packages
        self.binaries = binaries
        self.targets = targets
        verifyFileSnapshotsBody = verifyFileSnapshots
    }

    /// Proves that every Podfile/include pathname still names the exact inode and metadata snapshot that supplied the
    /// parsed bytes. Manifests produced by an injected in-memory reader have no filesystem capability and therefore
    /// require no revalidation.
    public func verifyFileSnapshots() throws {
        try verifyFileSnapshotsBody?()
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        file = try values.decode(String.self, forKey: .file)
        files = []
        includes = try values.decode([String].self, forKey: .includes)
        sources = try values.decode([Source].self, forKey: .sources)
        packages = try values.decode([Package].self, forKey: .packages)
        binaries = try values.decode([Binary].self, forKey: .binaries)
        targets = try values.decode([Target].self, forKey: .targets)
        verifyFileSnapshotsBody = nil
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(file, forKey: .file)
        try values.encode(includes, forKey: .includes)
        try values.encode(sources, forKey: .sources)
        try values.encode(packages, forKey: .packages)
        try values.encode(binaries, forKey: .binaries)
        try values.encode(targets, forKey: .targets)
    }

    public static func == (lhs: Manifest, rhs: Manifest) -> Bool {
        lhs.file == rhs.file && lhs.includes == rhs.includes && lhs.sources == rhs.sources
            && lhs.packages == rhs.packages && lhs.binaries == rhs.binaries && lhs.targets == rhs.targets
    }
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
