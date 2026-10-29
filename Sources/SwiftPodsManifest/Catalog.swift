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

/// What a catalog knows about a package. Versions stay in the Podfile; Swift Package Manager reads them from tags.
public struct CatalogEntry: Sendable, Equatable {
    public var name: String
    public var url: String
    /// Products a target links when the Podfile names none; empty means the Podfile must choose.
    public var products: [String]
    /// The catalog the entry came from.
    public var source: String

    public init(name: String, url: String, products: [String], source: String) {
        self.name = name
        self.url = url
        self.products = products
        self.source = source
    }

    /// Reads a catalog file: one `package 'Name', git: '…', products: [...]` statement.
    public static func parse(_ text: String, file: String, source: String) throws(ManifestError) -> CatalogEntry {
        let statements = try Parser.statements(text, file: file)
        guard statements.count == 1, let statement = statements.first, statement.name == "package" else {
            throw ManifestError(
                "A catalog file holds exactly one `package` declaration", at: statements.first?.location ?? SourceLocation(file: file, line: 1, column: 1))
        }
        var arguments = try Arguments(statement)
        try arguments.requireNoBlock()
        try arguments.positionalCount(1...1, usage: "package 'Name', git: 'https://…', products: ['Product']")
        let name = try Convert.nonEmpty(try Convert.string(arguments.positional[0], "The package name"), "The package name", at: statement.location)
        guard let gitNode = arguments.take("git") else {
            throw ManifestError("Catalog package `\(name)` needs `git`", at: statement.location)
        }
        let url = try Convert.string(gitNode, "`git`")
        guard PackageLocation.isRemote(url) else { throw ManifestError("`git` must be a repository URL", at: gitNode.location) }
        let products = try arguments.take("products").map { (node) throws(ManifestError) in try Convert.strings(node, "`products`") } ?? []
        try arguments.finish(allowed: ["git", "products"])
        return CatalogEntry(name: name, url: url, products: products, source: source)
    }
}

/// Looks package names up in catalogs. Implemented outside the manifest module, which performs no IO itself.
public protocol PackageCatalog: Sendable {
    /// The entry for `name` (compared case-insensitively) from the first source that has it, or nil.
    func entry(named name: String, in sources: [Source]) throws -> CatalogEntry?
}
