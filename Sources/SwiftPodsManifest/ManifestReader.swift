import Darwin
import Foundation

/// Reads a Podfile and the files it includes into a checked `Manifest`.
public struct ManifestReader: Sendable {
    private static let maximumFileBytes = 8 * 1_024 * 1_024
    private static let maximumTotalBytes = 16 * 1_024 * 1_024
    private static let maximumIncludeDepth = 64
    private static let maximumManifestFiles = 256

    fileprivate struct Snapshot: Sendable {
        let text: String
        /// Stable path spelling used in diagnostics and generated freshness files.
        let path: String
        /// Physical identity derived by the same resolution that selected the bytes.
        let identity: String
        /// Keeps the selected inode alive until the complete include graph has been evaluated.
        let verification: SnapshotVerification?
    }

    fileprivate final class SnapshotVerification: @unchecked Sendable {
        private let descriptor: Int32
        private let requestedPath: String
        private let identity: PathIdentity

        init(descriptor: Int32, requestedPath: String, identity: PathIdentity) {
            self.descriptor = descriptor
            self.requestedPath = requestedPath
            self.identity = identity
        }

        deinit { close(descriptor) }

        func verify() throws {
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, PathIdentity(opened) == identity else {
                throw SnapshotError.pathChanged
            }
            var linked = stat()
            guard requestedPath.withCString({ lstat($0, &linked) }) == 0,
                PathIdentity(linked) == identity
            else { throw SnapshotError.pathChanged }
        }
    }

    fileprivate enum SnapshotError: LocalizedError {
        case symbolicLink
        case nonRegular
        case tooLarge
        case pathChanged
        case unsafeCanonicalPath

        var errorDescription: String? {
            switch self {
            case .symbolicLink: "Refusing a symbolic link manifest file"
            case .nonRegular: "Refusing a non-regular manifest file"
            case .tooLarge: "Manifest file is too large"
            case .pathChanged: "Manifest path changed while it was being read"
            case .unsafeCanonicalPath: "A canonical manifest path cannot contain control characters or backslashes"
            }
        }
    }

    private let read: @Sendable (String) throws -> Snapshot
    private let catalog: (any PackageCatalog)?

    /// Reads manifests through a descriptor-anchored component walk. Symlink aliases are resolved once, then every
    /// directory edge is kept open and checked again after the read so an ancestor A -> B -> A swap cannot attribute
    /// B's bytes to A's canonical path.
    public init(catalog: (any PackageCatalog)? = nil) {
        read = { try Self.secureSnapshot($0) }
        self.catalog = catalog
    }

    /// Test seam for deterministic filesystem-race coverage. Production callers use `init(catalog:)` above.
    init(
        catalog: (any PackageCatalog)? = nil,
        beforeAncestorVerification: @escaping @Sendable () throws -> Void
    ) {
        read = { try Self.secureSnapshot($0, beforeAncestorVerification: beforeAncestorVerification) }
        self.catalog = catalog
    }

    /// Injects a reader for tests and virtual filesystems. The injected reader is a trusted boundary and is responsible
    /// for providing stable bytes; filesystem callers should use `init(catalog:)` above.
    public init(
        read: @escaping @Sendable (String) throws -> String,
        catalog: (any PackageCatalog)? = nil
    ) {
        self.read = { path in
            let before = physicalManifestPath(path) ?? canonicalManifestPath(path)
            let display = standardizedManifestPath(path)
            let text = try read(path)
            guard (physicalManifestPath(path) ?? canonicalManifestPath(path)) == before else {
                throw SnapshotError.pathChanged
            }
            return Snapshot(text: text, path: display, identity: before, verification: nil)
        }
        self.catalog = catalog
    }

    public func load(_ path: String) throws(ManifestError) -> Manifest {
        let file = standardizedManifestPath(path)
        guard isSafeManifestPath(file) else {
            throw ManifestError("A manifest path cannot contain control characters or backslashes", at: nil)
        }
        let snapshot: Snapshot
        do { snapshot = try read(file) } catch {
            throw ManifestError("Cannot read \(file): \(error.localizedDescription)", at: nil)
        }
        guard isSafeManifestPath(snapshot.path), isSafeManifestPath(snapshot.identity) else {
            throw ManifestError("A canonical manifest path cannot contain control characters or backslashes", at: nil)
        }
        return try evaluate(
            snapshot.text, file: snapshot.path, identity: snapshot.identity,
            verification: snapshot.verification)
    }

    /// Evaluates Podfile text; includes resolve against the directory of `file`.
    public func evaluate(_ text: String, file: String) throws(ManifestError) -> Manifest {
        let file = canonicalManifestPath(file)
        return try evaluate(text, file: file, identity: file, verification: nil)
    }

    private func evaluate(
        _ text: String, file: String, identity: String, verification: SnapshotVerification?
    ) throws(ManifestError) -> Manifest {
        guard isSafeManifestPath(file), isSafeManifestPath(identity) else {
            throw ManifestError("A canonical manifest path cannot contain control characters or backslashes", at: nil)
        }
        guard text.utf8.count <= Self.maximumFileBytes else {
            throw ManifestError("Podfile exceeds the \(Self.maximumFileBytes / 1_024 / 1_024) MiB limit", at: nil)
        }
        let parserBudget = Parser.Budget()
        let rootStatements = try Parser.statements(text, file: file, budget: parserBudget)
        var evaluator = Evaluator(
            read: read, catalog: catalog, file: file, rootIdentity: identity, rootVerification: verification,
            rootContents: Data(text.utf8), bytesRead: text.utf8.count,
            maximumFileBytes: Self.maximumFileBytes, maximumTotalBytes: Self.maximumTotalBytes,
            maximumIncludeDepth: Self.maximumIncludeDepth, maximumManifestFiles: Self.maximumManifestFiles,
            parserBudget: parserBudget)
        try evaluator.readRoot(rootStatements)
        return try evaluator.manifest()
    }

    fileprivate struct PathIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let links: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ status: stat) {
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
            mode = UInt32(status.st_mode)
            links = UInt64(status.st_nlink)
            size = status.st_size
            modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            changedSeconds = Int64(status.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        }
    }

    /// A directory's contents may legitimately change while a manifest is read. Only the stable object identity and
    /// file type are relevant when proving that an opened descriptor is still bound through the same parent edge.
    private struct DirectoryIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let type: UInt32

        init(_ status: stat) {
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
            type = UInt32(status.st_mode & S_IFMT)
        }
    }

    private static func secureSnapshot(
        _ requested: String, beforeAncestorVerification: (@Sendable () throws -> Void)? = nil
    ) throws -> Snapshot {
        var requestedInitial = stat()
        guard requested.withCString({ lstat($0, &requestedInitial) }) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        if requestedInitial.st_mode & S_IFMT == S_IFLNK { throw SnapshotError.symbolicLink }
        guard requestedInitial.st_mode & S_IFMT == S_IFREG else {
            throw SnapshotError.nonRegular
        }
        let requestedIdentity = PathIdentity(requestedInitial)
        guard let pointer = requested.withCString({ realpath($0, nil) }) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { free(pointer) }
        // Walk the physical path selected by this exact realpath call. Keep the caller's lexical spelling separately
        // for diagnostics and freshness files; physical identity, rather than a second resolution, drives cycles.
        let physical = String(cString: pointer)
        let display = standardizedManifestPath(requested)
        guard isSafeManifestPath(physical), physical.hasPrefix("/"), isSafeManifestPath(display) else {
            throw SnapshotError.unsafeCanonicalPath
        }
        let components = URL(fileURLWithPath: physical).pathComponents.dropFirst()
        guard let fileName = components.last, !fileName.isEmpty else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }

        let root = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NONBLOCK)
        guard root >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var descriptors = [root]
        var identities: [DirectoryIdentity] = []
        defer { for descriptor in descriptors.reversed() { close(descriptor) } }
        var rootStatus = stat()
        guard fstat(root, &rootStatus) == 0 else { throw CocoaError(.fileReadUnknown) }
        identities.append(DirectoryIdentity(rootStatus))

        for component in components.dropLast() {
            let descriptor = component.withCString {
                openat(descriptors.last!, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard descriptor >= 0 else {
                let code = errno
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(code),
                    userInfo: [NSLocalizedDescriptionKey: "Cannot securely open directory component \(component): "
                        + String(cString: strerror(code))])
            }
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
                close(descriptor)
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            descriptors.append(descriptor)
            identities.append(DirectoryIdentity(status))
        }

        let descriptor = fileName.withCString {
            openat(descriptors.last!, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw CocoaError(.fileReadUnsupportedScheme) }
            let code = errno
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "Cannot securely open manifest file \(fileName): "
                    + String(cString: strerror(code))])
        }
        descriptors.append(descriptor)
        var initial = stat()
        guard fstat(descriptor, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        guard initial.st_size >= 0, initial.st_size <= maximumFileBytes else {
            throw SnapshotError.tooLarge
        }
        let initialIdentity = PathIdentity(initial)
        guard initialIdentity == requestedIdentity else { throw SnapshotError.pathChanged }
        let reader = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard reader >= 0 else { throw CocoaError(.fileReadUnknown) }
        let handle = FileHandle(fileDescriptor: reader, closeOnDealloc: true)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(1 << 20, maximumFileBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumFileBytes else { throw SnapshotError.tooLarge }
        }
        var final = stat()
        guard fstat(descriptor, &final) == 0, PathIdentity(final) == initialIdentity,
            data.count == Int(initial.st_size)
        else { throw SnapshotError.pathChanged }
        try beforeAncestorVerification?()
        for index in identities.indices {
            var opened = stat()
            guard fstat(descriptors[index], &opened) == 0, DirectoryIdentity(opened) == identities[index] else {
                throw SnapshotError.pathChanged
            }
            if index + 1 < identities.count {
                var linked = stat()
                let component = components[components.index(components.startIndex, offsetBy: index)]
                guard component.withCString({ fstatat(descriptors[index], $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
                    DirectoryIdentity(linked) == identities[index + 1]
                else { throw SnapshotError.pathChanged }
            }
        }
        var linkedFile = stat()
        guard fileName.withCString({ fstatat(descriptors[descriptors.count - 2], $0, &linkedFile, AT_SYMLINK_NOFOLLOW) }) == 0,
            PathIdentity(linkedFile) == initialIdentity
        else { throw SnapshotError.pathChanged }
        var requestedFinal = stat()
        guard requested.withCString({ lstat($0, &requestedFinal) }) == 0,
            PathIdentity(requestedFinal) == requestedIdentity
        else { throw SnapshotError.pathChanged }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let retained = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard retained >= 0 else { throw CocoaError(.fileReadUnknown) }
        return Snapshot(
            text: text, path: display, identity: physical,
            verification: SnapshotVerification(
                descriptor: retained, requestedPath: display, identity: initialIdentity))
    }
}

private func canonicalManifestPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
}

private func physicalManifestPath(_ path: String) -> String? {
    guard let pointer = path.withCString({ realpath($0, nil) }) else { return nil }
    defer { free(pointer) }
    return String(cString: pointer)
}

private func standardizedManifestPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
}

private func isSafeManifestPath(_ path: String) -> Bool {
    PackageLocation.isSafePathText(path) && !path.contains("\\")
}

private func sourceIdentity(_ source: String) -> String {
    if PackageLocation.isSafeRemote(source) { return PackageLocation.fetchIdentity(source) }
    let url: URL
    if source.hasPrefix("/") {
        url = URL(fileURLWithPath: source)
    } else if let parsed = URL(string: source), parsed.isFileURL {
        url = parsed
    } else {
        return source.precomposedStringWithCanonicalMapping
    }
    return url.standardizedFileURL.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping
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

    struct Use {
        let name: String
        let arguments: [(name: String, value: Bool, location: SourceLocation)]
        let location: SourceLocation
    }

    /// A `with :parameter do … end` block of a group.
    struct Conditional {
        let parameterIndex: Int
        let declarations: Declarations
        let location: SourceLocation
    }

    var packages: [PackageUse] = []
    var binaries: [Binary] = []
    var uses: [Use] = []
    var settings: [BuildSetting] = []
    var scripts: [ScriptPhase] = []
    var conditionals: [Conditional] = []
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

    var itemCount: Int { packages.count + binaries.count + settings.count + scripts.count }
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
    /// Parameters with their defaults, in declaration order.
    let parameters: [(name: String, value: Bool)]
    let parameterIndices: [String: Int]
    let declarations: Declarations
}

private struct ExpansionKey: Hashable {
    let group: String
    let values: [Bool]
}

private final class CatalogLookupCache {
    enum Value {
        case found(CatalogEntry)
        case missing
    }

    var values: [String: Value] = [:]
    var nameBytes = 0
}

private struct Evaluator {
    private static let maximumGroupExpansionDepth = 128
    private static let maximumGroupExpansionWork = 100_000
    private static let maximumGroupParameters = 1_024
    private static let maximumTargetItemWork = 200_000
    private static let maximumSources = 32
    private static let maximumCatalogLookupNames = 256
    private static let maximumCatalogMetadataBytes = 4_096
    private static let maximumSourceMetadataBytes = 128 * 1_024
    private static let maximumCatalogLookupMetadataBytes = 1_024 * 1_024

    let read: @Sendable (String) throws -> ManifestReader.Snapshot
    let catalog: (any PackageCatalog)?
    let file: String
    var sources: [Source] = []
    var platform: (Platform, SourceLocation)?
    var project: (String, SourceLocation)?
    var root = Declarations()
    var groups: [String: Group] = [:]
    var targets: [TargetNode] = []
    var included: Set<String> = []
    var expanded: [ExpansionKey: Expanded] = [:]
    let catalogLookups = CatalogLookupCache()
    var files: [ManifestFile]
    var snapshotVerifications: [ManifestReader.SnapshotVerification]
    var bytesRead: Int
    var groupExpansionWork = 0
    let maximumFileBytes: Int
    let maximumTotalBytes: Int
    let maximumIncludeDepth: Int
    let maximumManifestFiles: Int
    let parserBudget: Parser.Budget

    init(
        read: @escaping @Sendable (String) throws -> ManifestReader.Snapshot, catalog: (any PackageCatalog)?, file: String,
        rootIdentity: String, rootVerification: ManifestReader.SnapshotVerification?,
        rootContents: Data, bytesRead: Int,
        maximumFileBytes: Int, maximumTotalBytes: Int, maximumIncludeDepth: Int,
        maximumManifestFiles: Int, parserBudget: Parser.Budget
    ) {
        self.read = read
        self.catalog = catalog
        self.file = file
        files = [ManifestFile(path: file, contents: rootContents)]
        snapshotVerifications = rootVerification.map { [$0] } ?? []
        self.bytesRead = bytesRead
        self.maximumFileBytes = maximumFileBytes
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumIncludeDepth = maximumIncludeDepth
        self.maximumManifestFiles = maximumManifestFiles
        self.parserBudget = parserBudget
        included = [rootIdentity]
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
            "settings", "script_phase", "inherit!", "with",
        ]
        if known.contains(statement.name) {
            return ManifestError("`\(statement.name)` cannot be used in \(scope.name)", at: statement.location)
        }
        return ManifestError("Unknown declaration `\(statement.name)`", at: statement.location)
    }

    // MARK: Reading

    mutating func readRoot(_ statements: [Statement]) throws(ManifestError) {
        // Sources come first: packages anywhere in the Podfile or its includes may be looked up in them.
        var sourceLocations: [String: SourceLocation] = [:]
        var sourceBytes = 0
        for statement in statements where statement.name == "source" {
            guard sources.count < Self.maximumSources else {
                throw ManifestError(
                    "A Podfile cannot declare more than \(Self.maximumSources) catalog sources", at: statement.location)
            }
            let value = try source(statement)
            let bytes = value.url.utf8.count
            guard bytes <= Self.maximumSourceMetadataBytes - sourceBytes else {
                throw ManifestError(
                    "Catalog source URLs exceed the \(Self.maximumSourceMetadataBytes)-byte aggregate limit",
                    at: statement.location)
            }
            let identity = sourceIdentity(value.url)
            if let previous = sourceLocations[identity] {
                throw ManifestError("Source \(value.url) is declared twice", at: statement.location, related: previous)
            }
            sourceLocations[identity] = value.declaredAt
            sources.append(value)
            sourceBytes += bytes
        }
        if sources.isEmpty { sources = [Source(url: Source.publicCatalog)] }
        for statement in statements where statement.name != "source" {
            switch statement.name {
            case "platform": try declarePlatform(statement)
            case "project":
                let value = try project(statement)
                if let previous = project { throw ManifestError("`project` is declared twice", at: statement.location, related: previous.1) }
                project = (value, statement.location)
            case "include": try include(statement, from: file, depth: 1)
            case "group": try group(statement)
            case "target", "abstract_target": targets.append(try target(statement))
            default:
                guard try declaration(statement, into: &root) else { throw misplaced(statement, .root) }
            }
        }
    }

    private mutating func declarePlatform(_ statement: Statement) throws(ManifestError) {
        let value = try platform(statement)
        if let previous = platform { throw ManifestError("`platform` is declared twice", at: statement.location, related: previous.1) }
        platform = (value, statement.location)
    }

    private mutating func include(_ statement: Statement, from including: String, depth: Int) throws(ManifestError) {
        let arguments = try Arguments(statement)
        try arguments.requireNoBlock()
        try arguments.finish(allowed: [])
        try arguments.positionalCount(1...1, usage: "include 'path.podfile'")
        let relative = try Convert.string(arguments.positional[0], "The included path")
        guard PackageLocation.isSafeRelativePath(relative, allowingParentComponents: true) else {
            throw ManifestError(
                "An included path must be relative and cannot contain control characters, backslashes, empty components or `.` components",
                at: statement.location)
        }
        guard depth <= maximumIncludeDepth else {
            throw ManifestError("Podfile includes are nested more than \(maximumIncludeDepth) levels", at: statement.location)
        }
        let directory = URL(fileURLWithPath: including).deletingLastPathComponent()
        let requestedPath = standardizedManifestPath(URL(fileURLWithPath: relative, relativeTo: directory).path)
        // Resolve once before opening so a symlink alias of a file already on the include stack is reported as the
        // cycle it is. The descriptor-backed reader and the post-read check below still validate the actual snapshot.
        if let preliminaryIdentity = physicalManifestPath(requestedPath), included.contains(preliminaryIdentity) {
            throw ManifestError("\(relative) is included more than once or includes itself", at: statement.location)
        }
        let snapshot: ManifestReader.Snapshot
        do {
            snapshot = try read(requestedPath)
        } catch ManifestReader.SnapshotError.pathChanged {
            throw ManifestError("Included path changed while it was being read", at: statement.location)
        } catch {
            throw ManifestError("Cannot read included file \(requestedPath): \(error.localizedDescription)", at: statement.location)
        }
        let path = snapshot.path
        guard isSafeManifestPath(path), isSafeManifestPath(snapshot.identity) else {
            throw ManifestError(
                "A canonical included path cannot contain control characters or backslashes", at: statement.location)
        }
        if included.contains(snapshot.identity) {
            throw ManifestError("\(relative) is included more than once or includes itself", at: statement.location)
        }
        guard included.count < maximumManifestFiles else {
            throw ManifestError(
                "Podfile and its includes exceed the \(maximumManifestFiles)-file limit", at: statement.location)
        }
        included.insert(snapshot.identity)
        if let verification = snapshot.verification { snapshotVerifications.append(verification) }
        let text = snapshot.text
        guard text.utf8.count <= maximumFileBytes else {
            throw ManifestError("Included file \(path) exceeds the \(maximumFileBytes / 1_024 / 1_024) MiB limit", at: statement.location)
        }
        guard bytesRead <= maximumTotalBytes - text.utf8.count else {
            throw ManifestError("Podfile includes exceed the \(maximumTotalBytes / 1_024 / 1_024) MiB total limit", at: statement.location)
        }
        bytesRead += text.utf8.count
        files.append(ManifestFile(path: path, contents: Data(text.utf8)))
        for nested in try Parser.statements(text, file: path, budget: parserBudget) {
            switch nested.name {
            case "platform": try declarePlatform(nested)
            case "include": try include(nested, from: path, depth: depth + 1)
            case "group": try group(nested)
            default:
                var error = misplaced(nested, .included)
                if Self.unsupported[nested.name] == nil {
                    error = ManifestError(
                        "Included files may only contain `platform`, `group` and `include`", at: nested.location,
                        hint: "Put `\(nested.name)` in a group and `use` it from the Podfile")
                }
                throw error
            }
        }
    }

    private mutating func group(_ statement: Statement) throws(ManifestError) {
        var arguments = try Arguments(statement)
        try arguments.positionalCount(1...1, usage: "group :name, parameter: true do … end")
        let name = try Convert.nonEmpty(try Convert.name(arguments.positional[0], "A group name"), "A group name", at: statement.location)
        guard PackageLocation.isSafeMetadataText(name) else {
            throw ManifestError("A group name cannot contain control characters or exceed 4096 bytes", at: statement.location)
        }
        let options = arguments.takeAll()
        guard options.count <= Self.maximumGroupParameters else {
            throw ManifestError(
                "A group cannot declare more than \(Self.maximumGroupParameters) parameters", at: statement.location)
        }
        var parameters: [(name: String, value: Bool)] = []
        var parameterIndices: [String: Int] = [:]
        parameters.reserveCapacity(options.count)
        parameterIndices.reserveCapacity(options.count)
        for option in options {
            guard PackageLocation.isSafeMetadataText(option.key) else {
                throw ManifestError(
                    "A group parameter name cannot contain control characters or exceed 4096 bytes",
                    at: option.keyLocation)
            }
            parameterIndices[option.key] = parameters.count
            parameters.append((
                name: option.key, value: try Convert.bool(option.node, "The default of `\(option.key)`")))
        }
        guard let block = statement.block else {
            throw ManifestError("`group` needs a `do … end` block", at: statement.location)
        }
        if let previous = groups[name] {
            throw ManifestError("Group `\(name)` is declared twice", at: statement.location, related: previous.location)
        }
        let declarations = try groupDeclarations(block, group: name, parameterIndices: parameterIndices)
        let value = Group(
            location: statement.location, parameters: parameters, parameterIndices: parameterIndices,
            declarations: declarations)
        groups[name] = value
    }

    private func groupDeclarations(
        _ block: [Statement], group: String, parameterIndices: [String: Int]
    ) throws(ManifestError) -> Declarations {
        var declarations = Declarations()
        for nested in block {
            if nested.name == "with" {
                let arguments = try Arguments(nested)
                try arguments.finish(allowed: [])
                try arguments.positionalCount(1...1, usage: "with :parameter do … end")
                let parameter = try Convert.name(arguments.positional[0], "A parameter name")
                guard PackageLocation.isSafeMetadataText(parameter) else {
                    throw ManifestError(
                        "A group parameter name cannot contain control characters or exceed 4096 bytes",
                        at: arguments.positional[0].location)
                }
                guard let parameterIndex = parameterIndices[parameter] else {
                    throw ManifestError(
                        "Group `\(group)` has no parameter `\(parameter)`", at: nested.location,
                        hint: "Declare it with a default: group :\(group), \(parameter): true do … end")
                }
                guard let block = nested.block else { throw ManifestError("`with` needs a `do … end` block", at: nested.location) }
                declarations.conditionals.append(.init(
                    parameterIndex: parameterIndex,
                    declarations: try groupDeclarations(block, group: group, parameterIndices: parameterIndices),
                    location: nested.location))
            } else {
                guard try declaration(nested, into: &declarations) else { throw misplaced(nested, .group) }
            }
        }
        return declarations
    }

    private mutating func target(_ statement: Statement) throws(ManifestError) -> TargetNode {
        let abstract = statement.name == "abstract_target"
        let arguments = try Arguments(statement)
        try arguments.finish(allowed: [])
        try arguments.positionalCount(1...1, usage: "\(statement.name) 'Name' do … end")
        let name = try Convert.nonEmpty(try Convert.string(arguments.positional[0], "A target name"), "A target name", at: statement.location)
        guard PackageLocation.isSafePathText(name) else {
            throw ManifestError("A target name cannot contain control characters or exceed 4096 bytes", at: statement.location)
        }
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
            var arguments = try Arguments(statement)
            try arguments.requireNoBlock()
            guard !arguments.positional.isEmpty else {
                throw ManifestError("Usage: use :group, ...", at: statement.location)
            }
            let values: [(name: String, value: Bool, location: SourceLocation)] = try arguments.takeAll().map {
                (option) throws(ManifestError) in
                guard PackageLocation.isSafeMetadataText(option.key) else {
                    throw ManifestError(
                        "A group parameter name cannot contain control characters or exceed 4096 bytes",
                        at: option.keyLocation)
                }
                return (
                    name: option.key, value: try Convert.bool(option.node, "`\(option.key)`"),
                    location: option.keyLocation)
            }
            if let first = values.first, arguments.positional.count > 1 {
                throw ManifestError("Parameters apply to one group", at: first.2, hint: "Write one `use` per group: use :group, \(first.0): …")
            }
            for node in arguments.positional {
                let name = try Convert.name(node, "A group name")
                guard PackageLocation.isSafeMetadataText(name) else {
                    throw ManifestError(
                        "A group name cannot contain control characters or exceed 4096 bytes", at: node.location)
                }
                declarations.uses.append(.init(name: name, arguments: values, location: node.location))
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
        guard PackageLocation.isSafeMetadataText(url, maximumBytes: Self.maximumCatalogMetadataBytes) else {
            throw ManifestError(
                "A source cannot be empty, contain control characters or exceed \(Self.maximumCatalogMetadataBytes) bytes",
                at: node.location)
        }
        guard PackageLocation.isSafeCatalogSource(url) else {
            throw ManifestError("A source must be an HTTPS/SSH repository URL, file URL or absolute local path", at: node.location)
        }
        let revision = try arguments.take("revision").map { (node) throws(ManifestError) in
            try Self.commitRevision(node)
        }
        try arguments.finish(allowed: ["revision"])
        return Source(url: url, revision: revision, declaredAt: statement.location)
    }

    private func catalogEntry(_ name: String, at location: SourceLocation) throws(ManifestError) -> CatalogEntry {
        guard PackageLocation.isSafeMetadataText(name, maximumBytes: Self.maximumCatalogMetadataBytes) else {
            throw ManifestError(
                "A catalog lookup name cannot be empty, contain control characters or exceed \(Self.maximumCatalogMetadataBytes) bytes",
                at: location)
        }
        let key = name.precomposedStringWithCanonicalMapping.lowercased().precomposedStringWithCanonicalMapping
        guard PackageLocation.isSafeMetadataText(key, maximumBytes: Self.maximumCatalogMetadataBytes) else {
            throw ManifestError(
                "A normalized catalog lookup name cannot exceed \(Self.maximumCatalogMetadataBytes) bytes", at: location)
        }
        guard let catalog else {
            throw ManifestError(
                "Package `\(name)` has no location", at: location,
                hint: "Add `git: 'https://…'` or `path: 'Local/Package'`, or write the URL as the first argument")
        }
        if let cached = catalogLookups.values[key] {
            switch cached {
            case .found(let entry): return entry
            case .missing:
                let names = sources.map(\.url).joined(separator: ", ")
                throw ManifestError(
                    "`\(name)` is not in \(names)", at: location,
                    hint: "Add `git: 'https://…'` to declare it directly, or add it to the catalog")
            }
        }
        guard catalogLookups.values.count < Self.maximumCatalogLookupNames else {
            throw ManifestError(
                "A Podfile cannot look up more than \(Self.maximumCatalogLookupNames) distinct catalog names", at: location)
        }
        let keyBytes = key.utf8.count
        guard keyBytes <= Self.maximumCatalogLookupMetadataBytes - catalogLookups.nameBytes else {
            throw ManifestError(
                "Catalog lookup names exceed the \(Self.maximumCatalogLookupMetadataBytes)-byte aggregate limit",
                at: location)
        }
        catalogLookups.nameBytes += keyBytes
        let entry: CatalogEntry?
        do {
            entry = try catalog.entry(named: name, in: sources)
        } catch let error as ManifestError {
            throw error
        } catch {
            throw ManifestError("Cannot read the package catalog: \(error)", at: location)
        }
        guard let entry else {
            catalogLookups.values[key] = .missing
            let names = sources.map(\.url).joined(separator: ", ")
            throw ManifestError(
                "`\(name)` is not in \(names)", at: location,
                hint: "Add `git: 'https://…'` to declare it directly, or add it to the catalog")
        }
        guard PackageLocation.isSafeMetadataText(entry.name) else {
            throw ManifestError("The catalog returned an invalid package name", at: location)
        }
        guard entry.products.allSatisfy({ PackageLocation.isSafeMetadataText($0) }) else {
            throw ManifestError("The catalog returned an invalid package product name", at: location)
        }
        catalogLookups.values[key] = .found(entry)
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
        guard PackageLocation.isSafeRelativePath(path) else {
            throw ManifestError("A project path must stay inside the Podfile directory", at: statement.location)
        }
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

    private static func commitRevision(_ node: Node) throws(ManifestError) -> String {
        let text = try Convert.string(node, "`revision`")
        guard text.range(of: #"\A(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\z"#, options: .regularExpression) != nil else {
            throw ManifestError("`revision` must be a full 40- or 64-character commit hash", at: node.location)
        }
        return text.lowercased()
    }

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
        } else if PackageLocation.looksLikeRemote(firstText) {
            throw ManifestError("A package repository must use a safe HTTPS or SSH URL", at: first.location)
        } else if let gitNode {
            url = try Convert.nonEmpty(try Convert.string(gitNode, "`git`"), "`git`", at: gitNode.location)
        }
        // A name alone comes from the catalog, which also says how the package writes its versions.
        var catalogEntry: CatalogEntry?
        if url == nil && pathNode == nil {
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
        guard PackageLocation.isSafeMetadataText(name) else {
            throw ManifestError("A package name cannot be empty, contain control characters or exceed 4096 bytes", at: first.location)
        }
        let packed = catalogEntry?.versionFormat == .packed
        var requirements: [Requirement] = []
        let positionalRequirements = Array(arguments.positional.dropFirst())
        if !positionalRequirements.isEmpty {
            var texts: [(String, SourceLocation)] = []
            for node in positionalRequirements { texts.append((try Convert.versionText(node, "A version requirement"), node.location)) }
            requirements.append(packed ? try Requirement.parsePacked(texts) : try Requirement.parse(texts))
        }
        for key in Self.requirementKeys {
            guard let node = arguments.take(key) else { continue }
            if packed {
                guard key == "exact" else {
                    throw ManifestError(
                        "`\(key)` is not available for `\(name)`, whose versions are packed", at: node.location,
                        hint: "Write the version as the vendor does: '13.9.0.0' or '~> 13.9.0.0'")
                }
                requirements.append(try Requirement.parsePacked([(try Convert.versionText(node, "`exact`"), node.location)]))
            } else {
                requirements.append(try Self.requirement(key, node))
            }
        }
        let productsNode = arguments.take("products")
        let link = try arguments.take("link").map { (node) throws(ManifestError) in try Convert.bool(node, "`link`") } ?? true
        try arguments.finish(allowed: allowed)

        let location: Package.Location
        let identity: String
        if let pathNode {
            if url != nil { throw ManifestError("A package has either a URL or a `path`", at: pathNode.location) }
            if !requirements.isEmpty {
                throw ManifestError("A local package takes no version requirement", at: pathNode.location)
            }
            let path = try Convert.nonEmpty(try Convert.string(pathNode, "`path`"), "`path`", at: pathNode.location)
            guard PackageLocation.isSafeRelativePath(path, allowingParentComponents: true) else {
                throw ManifestError("A package path must be relative and cannot contain ambiguous path components", at: pathNode.location)
            }
            location = .local(path: path)
            identity = PackageLocation.identity(path)
        } else {
            guard let url else { preconditionFailure("set above") }
            guard PackageLocation.isSafeRemote(url) else {
                throw ManifestError("A package repository must use a safe HTTPS or SSH URL", at: gitNode?.location ?? first.location)
            }
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
            guard !products.isEmpty, products.allSatisfy({ PackageLocation.isSafeMetadataText($0) }) else {
                throw ManifestError("`products` must contain bounded names without control characters", at: node.location)
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
        case "branch":
            let branch = try Convert.nonEmpty(try Convert.string(node, "`branch`"), "`branch`", at: node.location)
            let components = branch.split(separator: "/", omittingEmptySubsequences: false)
            guard PackageLocation.isSafeMetadataText(branch), !branch.hasPrefix("-"), branch != "@",
                !branch.contains(".."), !branch.contains("@{"), !branch.contains("\\"),
                !branch.unicodeScalars.contains(where: { " ~^:?*[".unicodeScalars.contains($0) }),
                !branch.hasSuffix("."), components.allSatisfy({
                    !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock")
                })
            else {
                throw ManifestError("`branch` must be a bounded valid Git branch name", at: node.location)
            }
            return .branch(branch)
        case "revision": return .revision(try commitRevision(node))
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
        for (kind, values) in [
            ("system_frameworks", frameworks), ("libraries", libraries), ("dependencies", dependencies),
        ] where !values.allSatisfy({ PackageLocation.isSafeMetadataText($0) }) {
            throw ManifestError("`\(kind)` must contain bounded names without control characters", at: statement.location)
        }
        if let bundle = resources.first(where: { !PackageLocation.isSafeArchivePath($0, extension: "bundle") }) {
            throw ManifestError(
                "Resource '\(bundle)' is not a safe relative .bundle path", at: statement.location,
                hint: "List a path inside the SDK archive without traversal, variables or control characters")
        }
        if let framework = xcframeworks?.first(where: { !PackageLocation.isSafeArchivePath($0, extension: "xcframework") }) {
            throw ManifestError(
                "XCFramework '\(framework)' is not a safe relative .xcframework path", at: statement.location,
                hint: "List a path inside the SDK archive without traversal, variables or control characters")
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
            guard PackageLocation.isSafeHTTPSDownloadURL(release.url) else {
                throw ManifestError(
                    "Catalog binary `\(entry.name)` has an unsafe release URL", at: versionNode.location,
                    hint: "Catalog binary releases must use HTTPS without credentials or fragments")
            }
            guard sdk.systemFrameworks.allSatisfy({ PackageLocation.isSafeMetadataText($0) }),
                sdk.libraries.allSatisfy({ PackageLocation.isSafeMetadataText($0) })
            else {
                throw ManifestError("Catalog framework and library names cannot contain control characters", at: statement.location)
            }
            name = entry.name
            guard name.range(of: #"\A[A-Za-z_][A-Za-z0-9_]*\z"#, options: .regularExpression) != nil else {
                throw ManifestError("Catalog binary '\(name)' is not a valid binary name", at: statement.location)
            }
            if let bundle = sdk.resources.first(where: { !PackageLocation.isSafeArchivePath($0, extension: "bundle") }) {
                throw ManifestError("Catalog resource '\(bundle)' is not a safe relative .bundle path", at: statement.location)
            }
            if let framework = sdk.xcframeworks?.first(where: { !PackageLocation.isSafeArchivePath($0, extension: "xcframework") }) {
                throw ManifestError("Catalog XCFramework '\(framework)' is not a safe relative .xcframework path", at: statement.location)
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
            let path = try Convert.nonEmpty(try Convert.string(pathNode, "`path`"), "`path`", at: pathNode.location)
            guard PackageLocation.isSafeRelativePath(path) else {
                throw ManifestError("A binary path must stay inside the Podfile directory", at: pathNode.location)
            }
            source = .local(path: path)
        } else {
            guard let urlNode, let shaNode else {
                throw ManifestError(
                    "Binary `\(name)` needs `url` and `sha256`, or `path`", at: statement.location,
                    hint: "Compute the checksum with: shasum -a 256 Archive.zip")
            }
            let url = try Convert.string(urlNode, "`url`")
            guard PackageLocation.isSafeHTTPSDownloadURL(url) || PackageLocation.isSafeLocalFileURL(url) else {
                throw ManifestError(
                    "`url` must be a safe HTTPS or local file URL", at: urlNode.location,
                    hint: "HTTPS URLs may use signed query parameters; file URLs must name an absolute local path")
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
        func safeText(_ text: String, maximumBytes: Int = 65_536) -> Bool {
            text.utf8.count <= maximumBytes
                && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
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
        let configurations = try arguments.take("configurations").map { (node) throws(ManifestError) in
            let values = try Convert.strings(node, "`configurations`")
            guard values.allSatisfy({
                !$0.isEmpty && safeText($0, maximumBytes: 4_096)
                    && !$0.contains("[") && !$0.contains("]") && !$0.contains("=") && !$0.contains("\\")
            }) else {
                throw ManifestError(
                    "Configuration names cannot be empty, contain control or selector characters, or exceed 4096 bytes",
                    at: node.location)
            }
            return values
        }
        try arguments.finish(allowed: ["configurations"])
        guard !arguments.settings.isEmpty else {
            throw ManifestError("`settings` needs at least one 'KEY' => 'value'", at: statement.location)
        }
        var result: [BuildSetting] = []
        for (key, node) in arguments.settings {
            guard safeText(key, maximumBytes: 4_096), !key.contains("\\"),
                key.range(of: #"\A[A-Za-z_][A-Za-z0-9_]*(\[[^\[\]=]+=[^\[\]]+\])*\z"#, options: .regularExpression) != nil
            else {
                throw ManifestError("'\(key)' is not a build setting name", at: node.location)
            }
            let value: String
            switch node.value {
            case .string(let text), .number(let text): value = text
            case .bool(let flag): value = flag ? "YES" : "NO"
            case .array(let elements):
                value = try elements.map { (element) throws(ManifestError) in
                    let text = try Convert.string(element, "Setting values")
                    guard safeText(text) else {
                        throw ManifestError("Setting values cannot contain control characters or exceed 65536 bytes", at: element.location)
                    }
                    guard !text.contains("\"") && !text.contains("\\") else {
                        throw ManifestError(
                            "Array setting values cannot contain quotes or backslashes",
                            at: element.location,
                            hint: "Use one scalar xcconfig value when explicit quoting or escaping is required")
                    }
                    return text.contains(" ") ? "\"\(text)\"" : text
                }.joined(separator: " ")
            default: throw ManifestError("A setting value must be a string, found \(node.kindName)", at: node.location)
            }
            guard safeText(value) else {
                throw ManifestError("A setting value cannot contain control characters or exceed 65536 bytes", at: node.location)
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
            guard let node = arguments.take(key) else { return [] }
            let values = try Convert.strings(node, "`\(key)`")
            if values.contains(where: { !PackageLocation.isSafePathText($0) }) {
                throw ManifestError("`\(key)` paths cannot be empty, contain control characters or exceed 4096 bytes", at: node.location)
            }
            return values
        }
        guard let nameNode = arguments.take("name"), let scriptNode = arguments.take("script") else {
            throw ManifestError("`script_phase` needs `name` and `script`", at: statement.location)
        }
        let name = try Convert.nonEmpty(try Convert.string(nameNode, "`name`"), "`name`", at: nameNode.location)
        guard PackageLocation.isSafePathText(name) else {
            throw ManifestError("A script phase name cannot contain control characters or exceed 4096 bytes", at: nameNode.location)
        }
        let script = try Convert.string(scriptNode, "`script`")
        guard script.utf8.count <= 256 * 1_024 else {
            throw ManifestError("A script phase body cannot exceed 256 KiB", at: scriptNode.location)
        }
        let shell = try arguments.take("shell_path").map { (node) throws(ManifestError) in try Convert.string(node, "`shell_path`") } ?? "/bin/sh"
        guard PackageLocation.isSafePathText(shell) else {
            throw ManifestError("`shell_path` cannot contain control characters or exceed 4096 bytes", at: statement.location)
        }
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
        let environment = try arguments.take("show_env_vars_in_log").map { (node) throws(ManifestError) in try Convert.bool(node, "`show_env_vars_in_log`") } ?? false
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

    private mutating func consumeGroupExpansion(_ amount: Int, at location: SourceLocation) throws(ManifestError) {
        guard amount >= 0, groupExpansionWork <= Self.maximumGroupExpansionWork - amount else {
            throw ManifestError(
                "Group expansion exceeds the work budget of \(Self.maximumGroupExpansionWork)", at: location,
                hint: "Reduce repeated or exponentially nested `use` declarations")
        }
        groupExpansionWork += amount
    }

    private mutating func expand(
        _ declarations: Declarations, values: [Bool] = [], stack: [String] = [], depth: Int = 0,
        at location: SourceLocation
    ) throws(ManifestError) -> Expanded {
        guard depth <= Self.maximumGroupExpansionDepth else {
            throw ManifestError(
                "Group expansion is nested more than \(Self.maximumGroupExpansionDepth) levels", at: location)
        }
        try consumeGroupExpansion(1, at: location)
        var result = Expanded()
        for use in declarations.uses {
            try consumeGroupExpansion(1, at: use.location)
            let name = use.name
            if stack.contains(name) {
                throw ManifestError("Groups use each other in a cycle: " + (stack + [name]).joined(separator: " → "), at: use.location)
            }
            guard let group = groups[name] else {
                throw ManifestError(
                    "Unknown group `\(name)`", at: use.location,
                    hint: groups.isEmpty ? "Declare it with `group :\(name) do … end`" : "Groups: " + groups.keys.sorted().joined(separator: ", "))
            }
            try consumeGroupExpansion(group.parameters.count + use.arguments.count, at: use.location)
            var groupValues = group.parameters.map(\.value)
            for argument in use.arguments {
                guard let index = group.parameterIndices[argument.name] else {
                    throw ManifestError(
                        "Group `\(name)` has no parameter `\(argument.name)`", at: argument.location,
                        hint: group.parameters.isEmpty ? nil : "Parameters: " + group.parameters.map(\.name).joined(separator: ", "))
                }
                groupValues[index] = argument.value
            }
            let key = ExpansionKey(group: name, values: groupValues)
            if let cached = expanded[key] {
                try consumeGroupExpansion(cached.itemCount, at: use.location)
                result.append(cached)
                continue
            }
            let value = try expand(
                group.declarations, values: groupValues, stack: stack + [name], depth: depth + 1, at: use.location)
            expanded[key] = value
            try consumeGroupExpansion(value.itemCount, at: use.location)
            result.append(value)
        }
        let direct = Expanded(
            packages: declarations.packages, binaries: declarations.binaries, settings: declarations.settings,
            scripts: declarations.scripts)
        try consumeGroupExpansion(direct.itemCount, at: location)
        result.append(direct)
        for conditional in declarations.conditionals
        where conditional.parameterIndex < values.count && values[conditional.parameterIndex]
        {
            let value = try expand(
                conditional.declarations, values: values, stack: stack, depth: depth + 1, at: conditional.location)
            try consumeGroupExpansion(value.itemCount, at: conditional.location)
            result.append(value)
        }
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
        let rootLocation = SourceLocation(file: file, line: 1, column: 1)
        let rootExpanded = try expand(root, at: rootLocation)
        try collector.register(rootExpanded)
        let context = Context(
            project: project?.0, platform: platform?.0,
            dependencies: Expanded(packages: rootExpanded.packages, binaries: rootExpanded.binaries),
            shared: Expanded(settings: rootExpanded.settings, scripts: rootExpanded.scripts))
        for node in targets { try walk(node, context, &collector) }
        let binaryNames = Set(collector.binaries.map(\.name))
        for binary in collector.binaries {
            for dependency in binary.dependencies where dependency == binary.name || !binaryNames.contains(dependency) {
                throw ManifestError(
                    dependency == binary.name ? "Binary `\(binary.name)` depends on itself" : "Binary `\(binary.name)` depends on undeclared binary `\(dependency)`",
                    at: binary.declaredAt)
            }
        }
        guard !collector.targets.isEmpty else {
            throw ManifestError("The Podfile declares no targets", at: SourceLocation(file: file, line: 1, column: 1),
                hint: "Add `target 'MyApp' do … end`")
        }
        // Every file read was individually stable, but the graph must also describe one filesystem generation.
        // Retained descriptors make an A -> B -> A directory swap observable after all includes are evaluated.
        do {
            for verification in snapshotVerifications { try verification.verify() }
            for verification in snapshotVerifications.reversed() { try verification.verify() }
        } catch {
            throw ManifestError(
                "Podfile or an included path changed while the manifest graph was being read", at: nil)
        }
        let verifications = snapshotVerifications
        return Manifest(
            file: file, files: files, includes: files.dropFirst().map(\.path), sources: sources, packages: collector.packages,
            binaries: collector.binaries, targets: collector.targets,
            verifyFileSnapshots: {
                for verification in verifications { try verification.verify() }
                for verification in verifications.reversed() { try verification.verify() }
            })
    }

    private mutating func walk(_ node: TargetNode, _ parent: Context, _ collector: inout Collector) throws(ManifestError) {
        let own = try expand(node.declarations, at: node.location)
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
        private struct ProductKey: Hashable {
            let package: String
            let product: String
        }

        private struct TargetKey: Hashable {
            let name: String
            let project: String?
        }

        private struct SettingLookup {
            var first: Int?
            var unrestricted: Int?
            var configurations: [String: Int] = [:]
        }

        let file: String
        var packages: [Package] = []
        var binaries: [Binary] = []
        var targets: [Target] = []
        private var packageIndices: [String: Int] = [:]
        private var binaryIndices: [String: Int] = [:]
        private var targetLocations: [TargetKey: SourceLocation] = [:]
        private var targetItemWork = 0

        init(file: String) {
            self.file = file
        }

        private mutating func consumeTargetItems(_ amount: Int, at location: SourceLocation) throws(ManifestError) {
            guard amount >= 0, targetItemWork <= Evaluator.maximumTargetItemWork - amount else {
                throw ManifestError(
                    "Expanded targets exceed the item budget of \(Evaluator.maximumTargetItemWork)", at: location,
                    hint: "Reduce inherited products, binaries, settings or script paths across targets")
            }
            targetItemWork += amount
        }

        mutating func register(_ expanded: Expanded) throws(ManifestError) {
            for use in expanded.packages { try register(use.package) }
            for binary in expanded.binaries { try register(binary) }
        }

        private func canonicalLocation(_ package: Package) -> String {
            switch package.location {
            case .remote(let url): PackageLocation.fetchIdentity(url)
            case .local(let path):
                URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: file).deletingLastPathComponent())
                    .standardizedFileURL.path
            }
        }

        private mutating func register(_ package: Package) throws(ManifestError) {
            guard let index = packageIndices[package.identity] else {
                packageIndices[package.identity] = packages.count
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
            guard let index = binaryIndices[binary.name] else {
                binaryIndices[binary.name] = binaries.count
                binaries.append(binary)
                return
            }
            let existing = binaries[index]
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
            guard targets.count < 2_048 else {
                throw ManifestError("A Podfile cannot declare more than 2048 concrete targets", at: node.location)
            }
            let targetKey = TargetKey(name: node.name, project: context.project)
            if let existing = targetLocations[targetKey] {
                throw ManifestError("Target `\(node.name)` is declared twice", at: node.location, related: existing)
            }
            targetLocations[targetKey] = node.location
            try consumeTargetItems(dependencies.packages.count, at: node.location)
            try consumeTargetItems(dependencies.binaries.count, at: node.location)
            try consumeTargetItems(shared.settings.count, at: node.location)
            try consumeTargetItems(shared.scripts.count, at: node.location)
            var products: [ProductUse] = []
            var productIndices: [ProductKey: Int] = [:]
            for use in dependencies.packages {
                try consumeTargetItems(use.products.count, at: node.location)
                for product in use.products {
                    let value = ProductUse(package: use.package.identity, product: product, link: use.link)
                    let key = ProductKey(package: value.package, product: value.product)
                    if let index = productIndices[key] {
                        products[index].link = products[index].link || value.link
                    } else {
                        productIndices[key] = products.count
                        products.append(value)
                    }
                }
            }
            var names: [String] = []
            var binaryNameSet: Set<String> = []
            for binary in dependencies.binaries where binaryNameSet.insert(binary.name).inserted {
                try consumeTargetItems(binary.xcframeworks?.count ?? 0, at: node.location)
                try consumeTargetItems(binary.systemFrameworks.count, at: node.location)
                try consumeTargetItems(binary.libraries.count, at: node.location)
                try consumeTargetItems(binary.linkerFlags.count, at: node.location)
                try consumeTargetItems(binary.dependencies.count, at: node.location)
                try consumeTargetItems(binary.resources.count, at: node.location)
                names.append(binary.name)
            }

            var settings: [BuildSetting] = []
            var settingLookup: [String: SettingLookup] = [:]
            for setting in shared.settings {
                try consumeTargetItems(setting.configurations?.count ?? 0, at: node.location)
                var lookup = settingLookup[setting.key] ?? SettingLookup()
                let overlapping: Int?
                if let configurations = setting.configurations {
                    var candidate = lookup.unrestricted
                    for configuration in configurations {
                        if let index = lookup.configurations[configuration], candidate.map({ index < $0 }) ?? true {
                            candidate = index
                        }
                    }
                    overlapping = candidate
                } else {
                    overlapping = lookup.first
                }
                if let index = overlapping {
                    let other = settings[index]
                    if other.value == setting.value && other.configurations == setting.configurations { continue }
                    throw ManifestError(
                        "Target `\(node.name)` sets \(setting.key) twice", at: setting.declaredAt,
                        hint: "Keep one declaration, or restrict them to different configurations", related: other.declaredAt)
                }
                let index = settings.count
                settings.append(setting)
                if lookup.first == nil { lookup.first = index }
                if let configurations = setting.configurations {
                    for configuration in configurations where lookup.configurations[configuration] == nil {
                        lookup.configurations[configuration] = index
                    }
                } else if lookup.unrestricted == nil {
                    lookup.unrestricted = index
                }
                settingLookup[setting.key] = lookup
            }
            var scripts: [ScriptPhase] = []
            var scriptIndices: [String: Int] = [:]
            for script in shared.scripts {
                try consumeTargetItems(script.inputFiles.count, at: node.location)
                try consumeTargetItems(script.outputFiles.count, at: node.location)
                try consumeTargetItems(script.inputFileLists.count, at: node.location)
                try consumeTargetItems(script.outputFileLists.count, at: node.location)
                if let index = scriptIndices[script.name] {
                    let other = scripts[index]
                    if other == script { continue }
                    throw ManifestError(
                        "Target `\(node.name)` has two script phases named '\(script.name)'", at: script.declaredAt,
                        related: other.declaredAt)
                }
                scriptIndices[script.name] = scripts.count
                scripts.append(script)
            }
            targets.append(Target(
                name: node.name, project: context.project, platform: context.platform, products: products,
                binaries: names, settings: settings, scriptPhases: scripts, declaredAt: node.location))
        }

    }
}
