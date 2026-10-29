import Foundation

/// Reads a Podfile and the files it includes into a checked `Manifest`.
public struct ManifestReader: Sendable {
    private let read: @Sendable (String) throws -> String
    private let catalog: (any PackageCatalog)?

    /// `catalog` resolves packages the Podfile names without a location; without it they are errors.
    public init(
        read: @escaping @Sendable (String) throws -> String = { try String(contentsOfFile: $0, encoding: .utf8) },
        catalog: (any PackageCatalog)? = nil
    ) {
        self.read = read
        self.catalog = catalog
    }

    public func load(_ path: String) throws(ManifestError) -> Manifest {
        let file = URL(fileURLWithPath: path).standardizedFileURL.path
        let text: String
        do { text = try read(file) } catch {
            throw ManifestError("Cannot read \(file): \(error.localizedDescription)", at: nil)
        }
        return try evaluate(text, file: file)
    }

    /// Evaluates Podfile text; includes resolve against the directory of `file`.
    public func evaluate(_ text: String, file: String) throws(ManifestError) -> Manifest {
        var evaluator = Evaluator(read: read, catalog: catalog, file: file)
        try evaluator.readRoot(try Parser.statements(text, file: file))
        return try evaluator.manifest()
    }
}

private enum Inheritance: String {
    case complete
    case searchPaths = "search_paths"
    case none
}

/// What a group, target or the root scope declares directly.
private struct Declarations {
    struct PackageUse {
        let package: Package
        let products: [String]
        let link: Bool
    }

    var packages: [PackageUse] = []
    var binaries: [Binary] = []
    var uses: [(name: String, location: SourceLocation)] = []
    var settings: [BuildSetting] = []
    var scripts: [ScriptPhase] = []
}

/// Declarations with groups applied.
private struct Expanded {
    var packages: [Declarations.PackageUse] = []
    var binaries: [Binary] = []
    var settings: [BuildSetting] = []
    var scripts: [ScriptPhase] = []

    mutating func append(_ other: Expanded) {
        packages += other.packages
        binaries += other.binaries
        settings += other.settings
        scripts += other.scripts
    }
}

private struct TargetNode {
    let name: String
    let abstract: Bool
    let location: SourceLocation
    var project: String?
    var platform: Platform?
    var inheritance: (Inheritance, SourceLocation)?
    var declarations = Declarations()
    var children: [TargetNode] = []
}

private struct Group {
    let location: SourceLocation
    let declarations: Declarations
}

private struct Evaluator {
    let read: @Sendable (String) throws -> String
    let catalog: (any PackageCatalog)?
    let file: String
    var sources: [Source] = []
    var platform: (Platform, SourceLocation)?
    var project: (String, SourceLocation)?
    var root = Declarations()
    var groups: [String: Group] = [:]
    var targets: [TargetNode] = []
    var included: [String] = []
    var expanded: [String: Expanded] = [:]

    init(read: @escaping @Sendable (String) throws -> String, catalog: (any PackageCatalog)?, file: String) {
        self.read = read
        self.catalog = catalog
        self.file = file
        included = [file]
    }

    private static let unsupported: [String: (String, String)] = [
        "pod": ("CocoaPods pods are not supported", "Use `spm` for a Swift package or `binary` for a prebuilt SDK"),
        "use_frameworks!": ("Swift Package Manager decides how packages link", "Remove this line"),
        "use_modular_headers!": ("Swift packages always provide modules", "Remove this line"),
        "inhibit_all_warnings!": ("Xcode does not report warnings from package dependencies", "Remove this line"),
        "workspace": ("A workspace is not needed: packages are added to the project itself", "Remove this line"),
        "install!": ("Installation options are not supported", "Remove this line"),
        "plugin": ("Plugins are not supported", "Remove this line"),
        "pre_install": ("Install hooks are not supported", "Use `settings` or `script_phase`"),
        "post_install": ("Install hooks are not supported", "Use `settings` or `script_phase`"),
        "pre_integrate": ("Install hooks are not supported", "Use `settings` or `script_phase`"),
        "post_integrate": ("Install hooks are not supported", "Use `settings` or `script_phase`"),
        "abstract!": ("`abstract!` is not supported", "Use `abstract_target 'Name' do … end`"),
        "xcodeproj": ("`xcodeproj` is not supported", "Use `project 'Path.xcodeproj'`"),
        "link_with": ("`link_with` is not supported", "Declare each target with `target`"),
        "swift_version": ("`swift_version` is not supported", "Set SWIFT_VERSION with `settings`"),
        "supports_swift_versions": ("`supports_swift_versions` is not supported", "Remove this line"),
        "generate_bridge_support!": ("BridgeSupport generation is not supported", "Remove this line"),
        "set_arc_compatibility_flag!": ("`set_arc_compatibility_flag!` is not supported", "Remove this line"),
        "ensure_bundler!": ("Bundler is not used", "Remove this line"),
    ]

    private enum Scope {
        case root, included, group, target(abstract: Bool)

        var name: String {
            switch self {
            case .root: "the top level"
            case .included: "an included file"
            case .group: "a group"
            case .target(let abstract): abstract ? "an abstract target" : "a target"
            }
        }
    }

    private func misplaced(_ statement: Statement, _ scope: Scope) -> ManifestError {
        if let (message, hint) = Self.unsupported[statement.name] {
            return ManifestError(message, at: statement.location, hint: hint)
        }
        let known = [
            "platform", "project", "source", "include", "group", "target", "abstract_target", "spm", "binary", "use",
            "settings", "script_phase", "inherit!",
        ]
        if known.contains(statement.name) {
            return ManifestError("`\(statement.name)` cannot be used in \(scope.name)", at: statement.location)
        }
        return ManifestError("Unknown declaration `\(statement.name)`", at: statement.location)
    }

    // MARK: Reading

    mutating func readRoot(_ statements: [Statement]) throws(ManifestError) {
        // Sources come first: packages anywhere in the Podfile or its includes may be looked up in them.
        for statement in statements where statement.name == "source" {
            let value = try source(statement)
            if let previous = sources.first(where: { PackageLocation.canonical($0.url) == PackageLocation.canonical(value.url) }) {
                throw ManifestError("Source \(value.url) is declared twice", at: statement.location, related: previous.declaredAt)
            }
            sources.append(value)
        }
        if sources.isEmpty { sources = [Source(url: Source.publicCatalog)] }
        for statement in statements where statement.name != "source" {
            switch statement.name {
            case "platform":
                let value = try platform(statement)
                if let previous = platform { throw ManifestError("`platform` is declared twice", at: statement.location, related: previous.1) }
                platform = (value, statement.location)
            case "project":
                let value = try project(statement)
                if let previous = project { throw ManifestError("`project` is declared twice", at: statement.location, related: previous.1) }
                project = (value, statement.location)
            case "include": try include(statement, from: file)
            case "group": try group(statement)
            case "target", "abstract_target": targets.append(try target(statement))
            default:
                guard try declaration(statement, into: &root) else { throw misplaced(statement, .root) }
            }
        }
    }

    private mutating func include(_ statement: Statement, from including: String) throws(ManifestError) {
        let arguments = try Arguments(statement)
        try arguments.requireNoBlock()
        try arguments.finish(allowed: [])
        try arguments.positionalCount(1...1, usage: "include 'path.podfile'")
        let relative = try Convert.string(arguments.positional[0], "The included path")
        let directory = URL(fileURLWithPath: including).deletingLastPathComponent()
        let path = URL(fileURLWithPath: relative, relativeTo: directory).standardizedFileURL.path
        if included.contains(path) {
            throw ManifestError("\(relative) is included more than once or includes itself", at: statement.location)
        }
        included.append(path)
        let text: String
        do { text = try read(path) } catch {
            throw ManifestError("Cannot read included file \(path): \(error.localizedDescription)", at: statement.location)
        }
        for nested in try Parser.statements(text, file: path) {
            switch nested.name {
            case "include": try include(nested, from: path)
            case "group": try group(nested)
            default:
                var error = misplaced(nested, .included)
                if Self.unsupported[nested.name] == nil {
                    error = ManifestError(
                        "Included files may only contain `group` and `include`", at: nested.location,
                        hint: "Put `\(nested.name)` in a group and `use` it from the Podfile")
                }
                throw error
            }
        }
    }

    private mutating func group(_ statement: Statement) throws(ManifestError) {
        let arguments = try Arguments(statement)
        try arguments.finish(allowed: [])
        try arguments.positionalCount(1...1, usage: "group :name do … end")
        let name = try Convert.nonEmpty(try Convert.name(arguments.positional[0], "A group name"), "A group name", at: statement.location)
        guard let block = statement.block else {
            throw ManifestError("`group` needs a `do … end` block", at: statement.location)
        }
        if let previous = groups[name] {
            throw ManifestError("Group `\(name)` is declared twice", at: statement.location, related: previous.location)
        }
        var declarations = Declarations()
        for nested in block {
            guard try declaration(nested, into: &declarations) else { throw misplaced(nested, .group) }
        }
        groups[name] = Group(location: statement.location, declarations: declarations)
    }

    private mutating func target(_ statement: Statement) throws(ManifestError) -> TargetNode {
        let abstract = statement.name == "abstract_target"
        let arguments = try Arguments(statement)
        try arguments.finish(allowed: [])
        try arguments.positionalCount(1...1, usage: "\(statement.name) 'Name' do … end")
        let name = try Convert.nonEmpty(try Convert.string(arguments.positional[0], "A target name"), "A target name", at: statement.location)
        var node = TargetNode(name: name, abstract: abstract, location: statement.location)
        guard let block = statement.block else {
            if abstract { throw ManifestError("`abstract_target` needs a `do … end` block", at: statement.location) }
            return node
        }
        var platformLocation: SourceLocation?
        var projectLocation: SourceLocation?
        for nested in block {
            switch nested.name {
            case "target", "abstract_target": node.children.append(try target(nested))
            case "platform":
                if let previous = platformLocation { throw ManifestError("`platform` is declared twice", at: nested.location, related: previous) }
                node.platform = try platform(nested)
                platformLocation = nested.location
            case "project":
                if let previous = projectLocation { throw ManifestError("`project` is declared twice", at: nested.location, related: previous) }
                node.project = try project(nested)
                projectLocation = nested.location
            case "inherit!":
                if let previous = node.inheritance {
                    throw ManifestError("`inherit!` is declared twice", at: nested.location, related: previous.1)
                }
                node.inheritance = (try inheritance(nested), nested.location)
            default:
                guard try declaration(nested, into: &node.declarations) else {
                    throw misplaced(nested, .target(abstract: abstract))
                }
            }
        }
        return node
    }

    /// Reads a statement allowed in groups, targets and the top level. Returns false for other statements.
    private func declaration(_ statement: Statement, into declarations: inout Declarations) throws(ManifestError) -> Bool {
        switch statement.name {
        case "spm": declarations.packages.append(try package(statement))
        case "binary": declarations.binaries.append(try binary(statement))
        case "settings": declarations.settings += try settings(statement)
        case "script_phase": declarations.scripts.append(try script(statement))
        case "use":
            let arguments = try Arguments(statement)
            try arguments.requireNoBlock()
            try arguments.finish(allowed: [])
            guard !arguments.positional.isEmpty else {
                throw ManifestError("Usage: use :group, ...", at: statement.location)
            }
            for node in arguments.positional {
                declarations.uses.append((try Convert.name(node, "A group name"), node.location))
            }
        default: return false
        }
        return true
    }

    // MARK: Statements

    private func source(_ statement: Statement) throws(ManifestError) -> Source {
        var arguments = try Arguments(statement)
        try arguments.requireNoBlock()
        try arguments.positionalCount(1...1, usage: "source 'https://github.com/…/catalog.git'")
        let node = arguments.positional[0]
        let url = try Convert.string(node, "The source")
        guard PackageLocation.isRemote(url) || url.hasPrefix("file://") || url.hasPrefix("/") else {
            throw ManifestError("A source is the URL of a catalog repository", at: node.location)
        }
        let revision = try arguments.take("revision").map { (node) throws(ManifestError) in
            let text = try Convert.string(node, "`revision`")
            guard text.range(of: #"\A[0-9a-fA-F]{7,40}\z"#, options: .regularExpression) != nil else {
                throw ManifestError("`revision` must be a commit hash", at: node.location)
            }
            return text.lowercased()
        }
        try arguments.finish(allowed: ["revision"])
        return Source(url: url, revision: revision, declaredAt: statement.location)
    }

    private func catalogEntry(_ name: String, at location: SourceLocation) throws(ManifestError) -> CatalogEntry {
        let names = sources.map(\.url).joined(separator: ", ")
        guard let catalog else {
            throw ManifestError(
                "Package `\(name)` has no location", at: location,
                hint: "Add `git: 'https://…'` or `path: 'Local/Package'`, or write the URL as the first argument")
        }
        let entry: CatalogEntry?
        do {
            entry = try catalog.entry(named: name, in: sources)
        } catch let error as ManifestError {
            throw error
        } catch {
            throw ManifestError("Cannot read the package catalog: \(error)", at: location)
        }
        guard let entry else {
            throw ManifestError(
                "`\(name)` is not in \(names)", at: location,
                hint: "Add `git: 'https://…'` to declare it directly, or add it to the catalog")
        }
        return entry
    }

    private func platform(_ statement: Statement) throws(ManifestError) -> Platform {
        let arguments = try Arguments(statement)
        try arguments.requireNoBlock()
        try arguments.finish(allowed: [])
        try arguments.positionalCount(1...2, usage: "platform :ios, '15.0'")
        let raw = try Convert.name(arguments.positional[0], "The platform")
        let aliases = ["osx": PlatformName.macos, "xros": .visionos]
        guard let name = PlatformName(rawValue: raw) ?? aliases[raw] else {
            throw ManifestError(
                "Unknown platform `\(raw)`", at: arguments.positional[0].location,
                hint: "Platforms: " + PlatformName.allCases.map(\.rawValue).joined(separator: ", "))
        }
        var target: String?
        if arguments.positional.count == 2 {
            let node = arguments.positional[1]
            let text = try Convert.versionText(node, "The deployment target")
            guard text.range(of: #"\A[0-9]+(\.[0-9]+){0,2}\z"#, options: .regularExpression) != nil else {
                throw ManifestError("'\(text)' is not a deployment target", at: node.location)
            }
            target = text
        }
        return Platform(name: name, deploymentTarget: target)
    }

    private func project(_ statement: Statement) throws(ManifestError) -> String {
        let arguments = try Arguments(statement)
        try arguments.requireNoBlock()
        if !statement.options.isEmpty || arguments.positional.count > 1 {
            throw ManifestError(
                "`project` takes only a path", at: statement.location,
                hint: "Configuration mappings are not needed: Xcode builds packages for every configuration")
        }
        try arguments.finish(allowed: [])
        try arguments.positionalCount(1...1, usage: "project 'Path.xcodeproj'")
        var path = try Convert.string(arguments.positional[0], "The project path")
        if !path.hasSuffix(".xcodeproj") { path += ".xcodeproj" }
        return path
    }

    private func inheritance(_ statement: Statement) throws(ManifestError) -> Inheritance {
        let arguments = try Arguments(statement)
        try arguments.requireNoBlock()
        try arguments.finish(allowed: [])
        try arguments.positionalCount(1...1, usage: "inherit! :complete | :search_paths | :none")
        let node = arguments.positional[0]
        guard let value = Inheritance(rawValue: try Convert.name(node, "The inheritance mode")) else {
            throw ManifestError("Unknown inheritance mode", at: node.location, hint: "Use :complete, :search_paths or :none")
        }
        if value == .searchPaths {
            throw ManifestError(
                "`inherit! :search_paths` is not supported yet", at: node.location,
                hint: "Use :complete to link the parent's packages, or declare `spm …, link: false` in this target")
        }
        return value
    }

    private static let requirementKeys = ["exact", "from", "up_to_next_major", "up_to_next_minor", "range", "branch", "revision"]

    private func package(_ statement: Statement) throws(ManifestError) -> Declarations.PackageUse {
        var arguments = try Arguments(statement)
        try arguments.requireNoBlock()
        let allowed = ["git", "path", "products", "link"] + Self.requirementKeys
        if let location = arguments.keyLocation("configurations") {
            throw ManifestError(
                "Per-configuration linking is not supported", at: location,
                hint: "Xcode links a package product in every configuration of a target")
        }
        guard let first = arguments.positional.first else {
            throw ManifestError("Usage: spm 'Name', git: 'https://…', exact: '1.2.3'", at: statement.location)
        }
        let firstText = try Convert.nonEmpty(try Convert.string(first, "The package name or URL"), "The package name", at: first.location)
        let gitNode = arguments.take("git")
        let pathNode = arguments.take("path")
        var name = firstText
        var url: String?
        if PackageLocation.isRemote(firstText) {
            url = firstText
            name = PackageLocation.name(firstText)
            if let gitNode { throw ManifestError("The URL is given twice", at: gitNode.location) }
        } else if let gitNode {
            url = try Convert.nonEmpty(try Convert.string(gitNode, "`git`"), "`git`", at: gitNode.location)
        }
        var requirements: [Requirement] = []
        let positionalRequirements = Array(arguments.positional.dropFirst())
        if !positionalRequirements.isEmpty {
            var texts: [(String, SourceLocation)] = []
            for node in positionalRequirements { texts.append((try Convert.versionText(node, "A version requirement"), node.location)) }
            requirements.append(try Requirement.parse(texts))
        }
        for key in Self.requirementKeys {
            guard let node = arguments.take(key) else { continue }
            requirements.append(try Self.requirement(key, node))
        }
        let productsNode = arguments.take("products")
        let link = try arguments.take("link").map { (node) throws(ManifestError) in try Convert.bool(node, "`link`") } ?? true
        try arguments.finish(allowed: allowed)

        let location: Package.Location
        let identity: String
        var catalogEntry: CatalogEntry?
        if let pathNode {
            if url != nil { throw ManifestError("A package has either a URL or a `path`", at: pathNode.location) }
            if !requirements.isEmpty {
                throw ManifestError("A local package takes no version requirement", at: pathNode.location)
            }
            let path = try Convert.nonEmpty(try Convert.string(pathNode, "`path`"), "`path`", at: pathNode.location)
            location = .local(path: path)
            identity = PackageLocation.identity(path)
        } else {
            if url == nil {
                let entry = try self.catalogEntry(name, at: statement.location)
                guard let packageURL = entry.url else {
                    throw ManifestError(
                        "`\(entry.name)` is a binary SDK in the catalog", at: statement.location,
                        hint: "Use `binary '\(entry.name)', '<version>'`")
                }
                catalogEntry = entry
                url = packageURL
                name = entry.name
            }
            guard let url else { preconditionFailure("set above") }
            guard requirements.count == 1 else {
                throw ManifestError(
                    requirements.isEmpty ? "Package `\(name)` needs a version requirement" : "Package `\(name)` has more than one version requirement",
                    at: statement.location, hint: "For example '~> 1.2', exact: '1.2.3' or branch: 'main'")
            }
            location = .remote(url: url)
            identity = PackageLocation.identity(url)
        }
        let products: [String]
        if let node = productsNode {
            products = try Convert.strings(node, "`products`")
            guard !products.isEmpty, products.allSatisfy({ !$0.isEmpty }) else {
                throw ManifestError("`products` must name at least one product", at: node.location)
            }
        } else if let catalogEntry {
            guard !catalogEntry.products.isEmpty else {
                throw ManifestError(
                    "`\(name)` has several products; choose them with `products: [...]`", at: statement.location)
            }
            products = catalogEntry.products
        } else {
            products = [name]
        }
        let package = Package(
            name: name, location: location, requirement: requirements.first, identity: identity,
            catalog: catalogEntry?.source, declaredAt: statement.location)
        return Declarations.PackageUse(package: package, products: products, link: link)
    }

    private static func requirement(_ key: String, _ node: Node) throws(ManifestError) -> Requirement {
        func version(_ node: Node) throws(ManifestError) -> Version {
            let text = try Convert.versionText(node, "`\(key)`")
            guard let version = Version(text) else {
                throw ManifestError(
                    "'\(text)' is not a version Swift Package Manager accepts", at: node.location,
                    hint: "Use at most three numeric components, for example 1.2.3")
            }
            return version
        }
        switch key {
        case "exact": return .exact(try version(node))
        case "from", "up_to_next_major": return .upToNextMajor(try version(node))
        case "up_to_next_minor": return .upToNextMinor(try version(node))
        case "branch": return .branch(try Convert.nonEmpty(try Convert.string(node, "`branch`"), "`branch`", at: node.location))
        case "revision":
            let text = try Convert.string(node, "`revision`")
            guard text.range(of: #"\A[0-9a-fA-F]{7,40}\z"#, options: .regularExpression) != nil else {
                throw ManifestError("`revision` must be a commit hash", at: node.location)
            }
            return .revision(text.lowercased())
        default:
            guard case .array(let bounds) = node.value, bounds.count == 2 else {
                throw ManifestError("`range` must be ['lower', 'upper']", at: node.location)
            }
            let lower = try version(bounds[0])
            let upper = try version(bounds[1])
            guard lower < upper else { throw ManifestError("The lower bound must be below the upper bound", at: node.location) }
            return .range(lower, upper)
        }
    }

    private func binary(_ statement: Statement) throws(ManifestError) -> Binary {
        var arguments = try Arguments(statement)
        try arguments.requireNoBlock()
        try arguments.positionalCount(1...2, usage: "binary 'Name', url: 'https://…', sha256: '…'  or  binary 'Name', '1.2.3'")
        let nameNode = arguments.positional[0]
        var name = try Convert.string(nameNode, "The binary name")
        guard name.range(of: #"\A[A-Za-z_][A-Za-z0-9_]*\z"#, options: .regularExpression) != nil else {
            throw ManifestError(
                "'\(name)' is not a valid binary name", at: nameNode.location,
                hint: "Use letters, digits and underscores; it becomes a Swift package product name")
        }
        let urlNode = arguments.take("url")
        let shaNode = arguments.take("sha256")
        let pathNode = arguments.take("path")
        func list(_ key: String, _ arguments: inout Arguments) throws(ManifestError) -> [String] {
            try arguments.take(key).map { (node) throws(ManifestError) in try Convert.strings(node, "`\(key)`") } ?? []
        }
        let xcframeworks = try arguments.take("xcframeworks").map { (node) throws(ManifestError) in try Convert.strings(node, "`xcframeworks`") }
        let frameworks = try list("system_frameworks", &arguments)
        let libraries = try list("libraries", &arguments)
        let flags = try list("linker_flags", &arguments)
        let dependencies = try list("dependencies", &arguments)
        let resources = try list("resources", &arguments)
        try arguments.finish(allowed: [
            "url", "sha256", "path", "xcframeworks", "system_frameworks", "libraries", "linker_flags", "dependencies",
            "resources",
        ])
        if let bundle = resources.first(where: { !$0.hasSuffix(".bundle") }) {
            throw ManifestError("Resource '\(bundle)' is not a .bundle", at: statement.location, hint: "List the SDK's resource bundles")
        }
        if arguments.positional.count == 2 {
            // A version alone: the catalog supplies the archive and how to link it.
            let versionNode = arguments.positional[1]
            let version = try Convert.versionText(versionNode, "The binary version")
            if let other = urlNode ?? shaNode ?? pathNode {
                throw ManifestError("A catalog binary takes a version, not a location", at: other.location)
            }
            if xcframeworks != nil || !frameworks.isEmpty || !libraries.isEmpty || !flags.isEmpty || !resources.isEmpty {
                throw ManifestError(
                    "How `\(name)` links comes from the catalog", at: statement.location,
                    hint: "Declare it with `url:` and `sha256:` to choose frameworks, libraries or resources yourself")
            }
            let entry = try catalogEntry(name, at: statement.location)
            guard let sdk = entry.binary else {
                throw ManifestError(
                    "`\(entry.name)` is a Swift package in the catalog", at: statement.location,
                    hint: "Use `spm '\(entry.name)', '\(version)'`")
            }
            guard let release = sdk.releases.first(where: { $0.version == version }) else {
                throw ManifestError(
                    "The catalog has no version \(version) of `\(entry.name)`", at: versionNode.location,
                    hint: "Versions: " + sdk.releases.map(\.version).joined(separator: ", "))
            }
            name = entry.name
            guard name.range(of: #"\A[A-Za-z_][A-Za-z0-9_]*\z"#, options: .regularExpression) != nil else {
                throw ManifestError("Catalog binary '\(name)' is not a valid binary name", at: statement.location)
            }
            return Binary(
                name: name, source: .remote(url: release.url, sha256: release.sha256), xcframeworks: sdk.xcframeworks,
                systemFrameworks: sdk.systemFrameworks, libraries: sdk.libraries, linkerFlags: sdk.linkerFlags,
                dependencies: dependencies, resources: sdk.resources, declaredAt: statement.location)
        }
        let source: Binary.Source
        if let pathNode {
            if let other = urlNode ?? shaNode {
                throw ManifestError("A binary has either `path` or `url` and `sha256`", at: other.location)
            }
            source = .local(path: try Convert.nonEmpty(try Convert.string(pathNode, "`path`"), "`path`", at: pathNode.location))
        } else {
            guard let urlNode, let shaNode else {
                throw ManifestError(
                    "Binary `\(name)` needs `url` and `sha256`, or `path`", at: statement.location,
                    hint: "Compute the checksum with: shasum -a 256 Archive.zip")
            }
            let url = try Convert.string(urlNode, "`url`")
            guard url.hasPrefix("https://") || url.hasPrefix("file://") else {
                throw ManifestError("`url` must use https", at: urlNode.location)
            }
            let sha = try Convert.string(shaNode, "`sha256`").lowercased()
            guard sha.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil else {
                throw ManifestError("`sha256` must be 64 hexadecimal characters", at: shaNode.location)
            }
            source = .remote(url: url, sha256: sha)
        }
        if xcframeworks?.isEmpty == true {
            throw ManifestError("`xcframeworks` must name at least one framework", at: statement.location)
        }
        return Binary(
            name: name, source: source, xcframeworks: xcframeworks, systemFrameworks: frameworks, libraries: libraries,
            linkerFlags: flags, dependencies: dependencies, resources: resources, declaredAt: statement.location)
    }

    private func settings(_ statement: Statement) throws(ManifestError) -> [BuildSetting] {
        var flattened = statement
        if statement.positional.count == 1, case .hash(let pairs) = statement.positional[0].value {
            flattened = Statement(
                name: statement.name, location: statement.location, positional: [], options: pairs + statement.options,
                block: statement.block)
        }
        var arguments = try Arguments(flattened, allowsStringKeys: true)
        try arguments.requireNoBlock()
        if let stray = arguments.positional.first {
            throw ManifestError("Usage: settings 'KEY' => 'value', configurations: ['Debug']", at: stray.location)
        }
        let configurations = try arguments.take("configurations").map { (node) throws(ManifestError) in try Convert.strings(node, "`configurations`") }
        try arguments.finish(allowed: ["configurations"])
        guard !arguments.settings.isEmpty else {
            throw ManifestError("`settings` needs at least one 'KEY' => 'value'", at: statement.location)
        }
        var result: [BuildSetting] = []
        for (key, node) in arguments.settings {
            guard key.range(of: #"\A[A-Za-z_][A-Za-z0-9_]*(\[[^\[\]=]+=[^\[\]]+\])*\z"#, options: .regularExpression) != nil else {
                throw ManifestError("'\(key)' is not a build setting name", at: node.location)
            }
            let value: String
            switch node.value {
            case .string(let text), .number(let text): value = text
            case .bool(let flag): value = flag ? "YES" : "NO"
            case .array(let elements):
                value = try elements.map { (element) throws(ManifestError) in
                    let text = try Convert.string(element, "Setting values")
                    return text.contains(" ") ? "\"\(text)\"" : text
                }.joined(separator: " ")
            default: throw ManifestError("A setting value must be a string, found \(node.kindName)", at: node.location)
            }
            result.append(BuildSetting(key: key, value: value, configurations: configurations, declaredAt: statement.location))
        }
        return result
    }

    private func script(_ statement: Statement) throws(ManifestError) -> ScriptPhase {
        var arguments = try Arguments(statement)
        try arguments.requireNoBlock()
        try arguments.positionalCount(0...0, usage: "script_phase name: '…', script: '…'")
        func list(_ key: String, _ arguments: inout Arguments) throws(ManifestError) -> [String] {
            try arguments.take(key).map { (node) throws(ManifestError) in try Convert.strings(node, "`\(key)`") } ?? []
        }
        guard let nameNode = arguments.take("name"), let scriptNode = arguments.take("script") else {
            throw ManifestError("`script_phase` needs `name` and `script`", at: statement.location)
        }
        let name = try Convert.nonEmpty(try Convert.string(nameNode, "`name`"), "`name`", at: nameNode.location)
        let script = try Convert.string(scriptNode, "`script`")
        let shell = try arguments.take("shell_path").map { (node) throws(ManifestError) in try Convert.string(node, "`shell_path`") } ?? "/bin/sh"
        let inputs = try list("input_files", &arguments)
        let outputs = try list("output_files", &arguments)
        let inputLists = try list("input_file_lists", &arguments)
        let outputLists = try list("output_file_lists", &arguments)
        var position = ScriptPhase.Position.any
        if let node = arguments.take("execution_position") {
            let raw = try Convert.name(node, "`execution_position`")
            guard let value = ScriptPhase.Position(rawValue: raw) else {
                throw ManifestError(
                    "Unknown execution position `\(raw)`", at: node.location,
                    hint: "Use :before_compile, :after_compile or :any")
            }
            position = value
        }
        let analysis = try arguments.take("based_on_dependency_analysis").map { (node) throws(ManifestError) in try Convert.bool(node, "`based_on_dependency_analysis`") } ?? true
        let environment = try arguments.take("show_env_vars_in_log").map { (node) throws(ManifestError) in try Convert.bool(node, "`show_env_vars_in_log`") } ?? true
        try arguments.finish(allowed: [
            "name", "script", "shell_path", "input_files", "output_files", "input_file_lists", "output_file_lists",
            "execution_position", "based_on_dependency_analysis", "show_env_vars_in_log",
        ])
        return ScriptPhase(
            name: name, script: script, shellPath: shell, inputFiles: inputs, outputFiles: outputs,
            inputFileLists: inputLists, outputFileLists: outputLists, position: position,
            basedOnDependencyAnalysis: analysis, showEnvironmentInLog: environment, declaredAt: statement.location)
    }

    // MARK: Evaluation

    private mutating func expand(_ declarations: Declarations, stack: [String] = []) throws(ManifestError) -> Expanded {
        var result = Expanded()
        for (name, location) in declarations.uses {
            if stack.contains(name) {
                throw ManifestError("Groups use each other in a cycle: " + (stack + [name]).joined(separator: " → "), at: location)
            }
            if let cached = expanded[name] {
                result.append(cached)
                continue
            }
            guard let group = groups[name] else {
                throw ManifestError(
                    "Unknown group `\(name)`", at: location,
                    hint: groups.isEmpty ? "Declare it with `group :\(name) do … end`" : "Groups: " + groups.keys.sorted().joined(separator: ", "))
            }
            let value = try expand(group.declarations, stack: stack + [name])
            expanded[name] = value
            result.append(value)
        }
        result.append(Expanded(
            packages: declarations.packages, binaries: declarations.binaries, settings: declarations.settings,
            scripts: declarations.scripts))
        return result
    }

    private struct Context {
        var project: String?
        var platform: Platform?
        /// Dependencies a nested target receives with `:complete`.
        var dependencies = Expanded()
        /// Settings and script phases from the root and abstract targets.
        var shared = Expanded()
    }

    mutating func manifest() throws(ManifestError) -> Manifest {
        var collector = Collector(file: file)
        let rootExpanded = try expand(root)
        try collector.register(rootExpanded)
        let context = Context(
            project: project?.0, platform: platform?.0,
            dependencies: Expanded(packages: rootExpanded.packages, binaries: rootExpanded.binaries),
            shared: Expanded(settings: rootExpanded.settings, scripts: rootExpanded.scripts))
        for node in targets { try walk(node, context, &collector) }
        for binary in collector.binaries {
            for dependency in binary.dependencies where dependency == binary.name || !collector.binaries.contains(where: { $0.name == dependency }) {
                throw ManifestError(
                    dependency == binary.name ? "Binary `\(binary.name)` depends on itself" : "Binary `\(binary.name)` depends on undeclared binary `\(dependency)`",
                    at: binary.declaredAt)
            }
        }
        guard !collector.targets.isEmpty else {
            throw ManifestError("The Podfile declares no targets", at: SourceLocation(file: file, line: 1, column: 1),
                hint: "Add `target 'MyApp' do … end`")
        }
        return Manifest(
            file: file, sources: sources, packages: collector.packages, binaries: collector.binaries, targets: collector.targets)
    }

    private mutating func walk(_ node: TargetNode, _ parent: Context, _ collector: inout Collector) throws(ManifestError) {
        let own = try expand(node.declarations)
        try collector.register(own)
        var context = parent
        context.project = node.project ?? parent.project
        context.platform = node.platform ?? parent.platform
        switch node.inheritance?.0 ?? .complete {
        case .complete: break
        case .none: context.dependencies = Expanded()
        case .searchPaths: preconditionFailure("rejected while reading")
        }
        context.dependencies.append(Expanded(packages: own.packages, binaries: own.binaries))
        if node.abstract {
            context.shared.append(Expanded(settings: own.settings, scripts: own.scripts))
        } else {
            var shared = parent.shared
            shared.append(Expanded(settings: own.settings, scripts: own.scripts))
            try collector.addTarget(node, context: (context.project, context.platform), dependencies: context.dependencies, shared: shared)
        }
        for child in node.children { try walk(child, context, &collector) }
    }

    /// Distinct packages, binaries and targets, with conflicts reported at both declarations.
    private struct Collector {
        let file: String
        var packages: [Package] = []
        var binaries: [Binary] = []
        var targets: [Target] = []
        var canonical: [String: String] = [:]

        mutating func register(_ expanded: Expanded) throws(ManifestError) {
            for use in expanded.packages { try register(use.package) }
            for binary in expanded.binaries { try register(binary) }
        }

        private func canonicalLocation(_ package: Package) -> String {
            switch package.location {
            case .remote(let url): PackageLocation.canonical(url)
            case .local(let path):
                URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: file).deletingLastPathComponent())
                    .standardizedFileURL.path
            }
        }

        private mutating func register(_ package: Package) throws(ManifestError) {
            guard let index = packages.firstIndex(where: { $0.identity == package.identity }) else {
                packages.append(package)
                return
            }
            let existing = packages[index]
            if existing.declaredAt == package.declaredAt { return }
            guard canonicalLocation(existing) == canonicalLocation(package) else {
                throw ManifestError(
                    "Two packages have the identity `\(package.identity)`", at: package.declaredAt,
                    hint: "Swift Package Manager identifies a package by the last component of its location", related: existing.declaredAt)
            }
            guard existing.requirement == package.requirement else {
                throw ManifestError(
                    "Package `\(package.identity)` is declared with different requirements: "
                        + "\(package.requirement.map(\.description) ?? "local") and \(existing.requirement.map(\.description) ?? "local")",
                    at: package.declaredAt, related: existing.declaredAt)
            }
        }

        private mutating func register(_ binary: Binary) throws(ManifestError) {
            guard let existing = binaries.first(where: { $0.name == binary.name }) else {
                binaries.append(binary)
                return
            }
            var comparable = binary
            comparable.declaredAt = existing.declaredAt
            guard comparable == existing else {
                throw ManifestError(
                    "Binary `\(binary.name)` is declared twice with different options", at: binary.declaredAt,
                    related: existing.declaredAt)
            }
        }

        mutating func addTarget(
            _ node: TargetNode, context: (project: String?, platform: Platform?), dependencies: Expanded, shared: Expanded
        ) throws(ManifestError) {
            if let existing = targets.first(where: { $0.name == node.name && $0.project == context.project }) {
                throw ManifestError("Target `\(node.name)` is declared twice", at: node.location, related: existing.declaredAt)
            }
            var products: [ProductUse] = []
            for use in dependencies.packages {
                for product in use.products {
                    let value = ProductUse(package: use.package.identity, product: product, link: use.link)
                    if let index = products.firstIndex(where: { $0.package == value.package && $0.product == value.product }) {
                        products[index].link = products[index].link || value.link
                    } else {
                        products.append(value)
                    }
                }
            }
            var names: [String] = []
            for binary in dependencies.binaries where !names.contains(binary.name) { names.append(binary.name) }

            var settings: [BuildSetting] = []
            for setting in shared.settings {
                if let other = settings.first(where: { $0.key == setting.key && Self.overlap($0.configurations, setting.configurations) }) {
                    if other.value == setting.value && other.configurations == setting.configurations { continue }
                    throw ManifestError(
                        "Target `\(node.name)` sets \(setting.key) twice", at: setting.declaredAt,
                        hint: "Keep one declaration, or restrict them to different configurations", related: other.declaredAt)
                }
                settings.append(setting)
            }
            var scripts: [ScriptPhase] = []
            for script in shared.scripts {
                if let other = scripts.first(where: { $0.name == script.name }) {
                    if other == script { continue }
                    throw ManifestError(
                        "Target `\(node.name)` has two script phases named '\(script.name)'", at: script.declaredAt,
                        related: other.declaredAt)
                }
                scripts.append(script)
            }
            targets.append(Target(
                name: node.name, project: context.project, platform: context.platform, products: products,
                binaries: names, settings: settings, scriptPhases: scripts, declaredAt: node.location))
        }

        private static func overlap(_ left: [String]?, _ right: [String]?) -> Bool {
            guard let left, let right else { return true }
            return !Set(left).isDisjoint(with: right)
        }
    }
}
