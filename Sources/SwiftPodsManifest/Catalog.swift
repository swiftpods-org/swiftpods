import Foundation

/// A package catalog: a Git repository that maps package names to their repositories.
public struct Source: Sendable, Codable, Equatable {
    /// The public catalog, used when a Podfile declares no `source`.
    public static let publicCatalog = "https://github.com/swiftpods-org/swiftpods-catalog.git"

    public var url: String
    /// A commit to read the catalog at; nil reads the cached or latest catalog.
    public var revision: String?
    /// Nil for the implicit public catalog.
    public var declaredAt: SourceLocation?

    public init(url: String, revision: String? = nil, declaredAt: SourceLocation? = nil) {
        self.url = url
        self.revision = revision
        self.declaredAt = declaredAt
    }
}

/// What a catalog knows about a name: a Swift package, a prebuilt SDK by version, or both.
/// Package versions stay in the Podfile; Swift Package Manager reads them from tags.
public struct CatalogEntry: Sendable, Equatable {
    public struct Release: Sendable, Equatable {
        public var version: String
        public var url: String
        public var sha256: String

        public init(version: String, url: String, sha256: String) {
            self.version = version
            self.url = url
            self.sha256 = sha256
        }
    }

    /// An SDK published as archives; each release pins one archive by checksum.
    public struct BinarySDK: Sendable, Equatable {
        public var xcframeworks: [String]?
        public var systemFrameworks: [String] = []
        public var libraries: [String] = []
        public var linkerFlags: [String] = []
        public var resources: [String] = []
        public var releases: [Release] = []

        public init(releases: [Release]) { self.releases = releases }
    }

    /// How a package writes its versions when they are not plain semantic versions.
    public enum VersionFormat: String, Sendable, Equatable {
        /// Components after the first padded to two digits and joined into the major version, as AppLovin
        /// publishes MAX adapters: adapter 13.9.0.0 is package version 13090000.0.0.
        case packed
    }

    public var name: String
    /// The Swift package's repository, when the name is a package.
    public var url: String?
    /// Nil for semantic versions.
    public var versionFormat: VersionFormat?
    /// Products a target links when the Podfile names none; empty means the Podfile must choose.
    public var products: [String]
    public var binary: BinarySDK?
    /// The catalog the entry came from.
    public var source: String

    public init(name: String, url: String?, products: [String], binary: BinarySDK? = nil, source: String) {
        self.name = name
        self.url = url
        self.products = products
        self.binary = binary
        self.source = source
    }

    /// Reads a catalog file: a `package` declaration, a `binary` declaration with `version` entries, or both.
    public static func parse(_ text: String, file: String, source: String) throws(ManifestError) -> CatalogEntry {
        let statements = try Parser.statements(text, file: file)
        let start = SourceLocation(file: file, line: 1, column: 1)
        guard !statements.isEmpty else { throw ManifestError("A catalog file needs a `package` or `binary` declaration", at: start) }
        var name: String?
        var entry = CatalogEntry(name: "", url: nil, products: [], source: source)
        for statement in statements {
            var arguments = try Arguments(statement)
            try arguments.positionalCount(1...1, usage: "\(statement.name) 'Name', …")
            let declared = try Convert.nonEmpty(try Convert.string(arguments.positional[0], "The name"), "The name", at: statement.location)
            if let name, name != declared {
                throw ManifestError("A catalog file declares one name; found `\(name)` and `\(declared)`", at: statement.location)
            }
            name = declared
            switch statement.name {
            case "package":
                guard entry.url == nil else { throw ManifestError("`package` is declared twice", at: statement.location) }
                try arguments.requireNoBlock()
                guard let gitNode = arguments.take("git") else {
                    throw ManifestError("Catalog package `\(declared)` needs `git`", at: statement.location)
                }
                let url = try Convert.string(gitNode, "`git`")
                guard PackageLocation.isRemote(url) else { throw ManifestError("`git` must be a repository URL", at: gitNode.location) }
                entry.url = url
                entry.products = try arguments.take("products").map { (node) throws(ManifestError) in try Convert.strings(node, "`products`") } ?? []
                if let node = arguments.take("version_format") {
                    let raw = try Convert.name(node, "`version_format`")
                    guard let format = VersionFormat(rawValue: raw) else {
                        throw ManifestError("Unknown version format `\(raw)`", at: node.location, hint: "Formats: packed")
                    }
                    entry.versionFormat = format
                }
                try arguments.finish(allowed: ["git", "products", "version_format"])
            case "binary":
                guard entry.binary == nil else { throw ManifestError("`binary` is declared twice", at: statement.location) }
                entry.binary = try binary(statement, &arguments)
            default:
                throw ManifestError("Catalog files contain `package` and `binary` declarations, not `\(statement.name)`", at: statement.location)
            }
        }
        entry.name = name!
        return entry
    }

    private static func binary(_ statement: Statement, _ arguments: inout Arguments) throws(ManifestError) -> BinarySDK {
        func list(_ key: String) throws(ManifestError) -> [String] {
            try arguments.take(key).map { (node) throws(ManifestError) in try Convert.strings(node, "`\(key)`") } ?? []
        }
        var sdk = BinarySDK(releases: [])
        sdk.xcframeworks = try arguments.take("xcframeworks").map { (node) throws(ManifestError) in try Convert.strings(node, "`xcframeworks`") }
        sdk.systemFrameworks = try list("system_frameworks")
        sdk.libraries = try list("libraries")
        sdk.linkerFlags = try list("linker_flags")
        sdk.resources = try list("resources")
        try arguments.finish(allowed: ["xcframeworks", "system_frameworks", "libraries", "linker_flags", "resources"])
        if let bundle = sdk.resources.first(where: { !$0.hasSuffix(".bundle") }) {
            throw ManifestError("Resource '\(bundle)' is not a .bundle", at: statement.location)
        }
        guard let block = statement.block, !block.isEmpty else {
            throw ManifestError("A catalog binary lists its releases in a block: version '1.0', url: '…', sha256: '…'", at: statement.location)
        }
        for release in block {
            guard release.name == "version" else {
                throw ManifestError("Expected `version`, found `\(release.name)`", at: release.location)
            }
            var values = try Arguments(release)
            try values.requireNoBlock()
            try values.positionalCount(1...1, usage: "version '1.2.3', url: 'https://…', sha256: '…'")
            let version = try Convert.nonEmpty(try Convert.versionText(values.positional[0], "The version"), "The version", at: release.location)
            guard let urlNode = values.take("url"), let shaNode = values.take("sha256") else {
                throw ManifestError("Version \(version) needs `url` and `sha256`", at: release.location)
            }
            let url = try Convert.string(urlNode, "`url`")
            guard url.hasPrefix("https://") else { throw ManifestError("`url` must use https", at: urlNode.location) }
            let sha = try Convert.string(shaNode, "`sha256`").lowercased()
            guard sha.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil else {
                throw ManifestError("`sha256` must be 64 hexadecimal characters", at: shaNode.location)
            }
            try values.finish(allowed: ["url", "sha256"])
            guard !sdk.releases.contains(where: { $0.version == version }) else {
                throw ManifestError("Version \(version) is listed twice", at: release.location)
            }
            sdk.releases.append(Release(version: version, url: url, sha256: sha))
        }
        return sdk
    }
}

/// Looks package names up in catalogs. Implemented outside the manifest module, which performs no IO itself.
public protocol PackageCatalog: Sendable {
    /// The entry for `name` (compared case-insensitively) from the first source that has it, or nil.
    func entry(named name: String, in sources: [Source]) throws -> CatalogEntry?
}
