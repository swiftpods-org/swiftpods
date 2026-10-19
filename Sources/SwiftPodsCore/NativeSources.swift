import CryptoKit
import Foundation

final class NativeSources {
    private let cacheLease: NativeCacheLease
    let project: URL
    let cache: URL
    let dsl: NativeDSL?
    let offline: Bool
    let refreshRepositories: Bool
    let hardened: Bool
    private let sources: [String]
    private var found: [String: [NativeSpec]] = [:]
    private var external: [String: [String: Any]] = [:]
    private var explicitSpecSources: [String: String] = [:]
    func sourceOptions(_ name: String) -> [String: Any] { external[name] ?? [:] }
    var lockedRepositories: [String: String] = [:]
    var installationOptions: [String: Any] = [:]
    var cleanInstall = false
    var sourceWarnings: [[String: Any]] = []
    var serializedSpecifications: [String: Data] = [:]
    var checksumAliases: [String: Set<String>] = [:]
    var selectedRequests: [NativeDependency] = []
    var prefetchedSources: [String: URL] = [:]
    var pinnedCheckouts: [String: [String: String]] = [:]
    var updating = false
    var updateRoots = Set<String>()
    private var materialized: [String: NativeSpec] = [:]
    private var registeredRepositories: [String: [String: Any]] = [:]
    init(
        project: URL, cache: URL, sources: [String], dsl: NativeDSL?, offline: Bool,
        refreshRepositories: Bool, hardened: Bool
    ) throws {
        for source in sources { try NativeSourceOptions.validate(["source": source], file: "Podfile source") }
        cacheLease = try NativeCacheLease(cache: cache, exclusive: false)
        self.project = project
        self.cache = cache
        self.sources = sources
        self.dsl = dsl
        self.offline = offline
        self.refreshRepositories = refreshRepositories
        self.hardened = hardened
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    }
    func register(_ dependencies: [NativeDependency]) throws {
        for dependency in dependencies {
            if let source = dependency.options["source"] as? String {
                if let previous = explicitSpecSources[dependency.root], previous != source {
                    throw Diagnostic(
                        "SP-SOURCE-CONFLICT", stage: "resolve", "Conflicting spec repositories for " + dependency.root)
                }
                explicitSpecSources[dependency.root] = source
            }
        }
        for dependency in dependencies
        where ["path", "git", "podspec", "http", "svn", "hg"].contains(where: { dependency.options[$0] != nil }) {
            guard ["path", "git", "podspec", "http", "svn", "hg"].filter({ dependency.options[$0] != nil }).count == 1,
                ["commit", "tag", "branch"].filter({ dependency.options[$0] != nil }).count <= 1
            else {
                throw Diagnostic(
                    "SP-SOURCE-CONFLICT", stage: "resolve",
                    "Specify one source and one Git selector for \(dependency.name)")
            }
            let options = dependency.options.filter {
                [
                    "path", "git", "podspec", "http", "svn", "hg", "tag", "branch", "commit", "revision", "folder",
                    "submodules", "flatten", "type", "sha256", "sha1", "headers",
                ].contains($0.key)
            }
            if let before = external[dependency.root], try jsonData(before) != jsonData(options) {
                throw Diagnostic(
                    "SP-SOURCE-CONFLICT", stage: "resolve", "Conflicting external sources for \(dependency.root)")
            }
            external[dependency.root] = options
        }
    }
    func spec(_ url: URL) throws -> [String: Any] {
        if hardened && url.pathExtension != "json" {
            throw Diagnostic(
                "SP-HARDENED-RUBY", stage: "policy", "Hardened installs require JSON podspecs", file: url.path)
        }
        if url.pathExtension == "json" { return try readObject(url) }
        guard let dsl else {
            throw Diagnostic("SP-DSL-MISSING", stage: "dsl", "Ruby adapter is needed to evaluate this podspec")
        }
        return try dsl.spec(url)
    }
    func candidates(_ request: NativeDependency) throws -> [NativeSpec] {
        if let existing = found[request.root] { return existing }
        var result: [NativeSpec] = []
        if let options = external[request.root] {
            if let path = options["path"] as? String {
                let directory = URL(fileURLWithPath: path, relativeTo: project).standardizedFileURL
                    .resolvingSymlinksInPath()
                result = [
                    try parsedSpec(findSpec(request.root, directory: directory), directory: directory, local: true)
                ]
            } else if let git = options["git"] as? String {
                let directory = try checkout(
                    git, selector: pinnedSelector(request.root, source: options), fresh: shouldUpdate(request.root),
                    submodules: options["submodules"] as? Bool == true, pod: request.root)
                result = [try parsedSpec(findSpec(request.root, directory: directory), directory: directory)]
            } else if let path = options["podspec"] as? String {
                let location =
                    ["podspec", "json"].contains((path as NSString).pathExtension)
                        || path.contains("://") ? path : path + "/" + request.root + ".podspec"
                let url = URL(string: location)
                let file =
                    url?.scheme == "https" || url?.scheme == "http"
                    ? try downloadedPodspec(location, pod: request.root)
                    : URL(fileURLWithPath: location, relativeTo: project).standardizedFileURL
                result = [try parsedSpec(file, external: true)]
            } else if options["http"] != nil || options["svn"] != nil || options["hg"] != nil {
                let directory = try sourceSnapshot(options, pod: request.root)
                result = [try parsedSpec(findSpec(request.root, directory: directory), directory: directory)]
            }
        } else {
            let selected =
                explicitSpecSources[request.root] ?? request.options["source"] as? String
                ?? lockedRepositories[request.root]
            let repositories = NativeRepositories(cache: cache)
            for raw in selected.map({ [$0] }) ?? sources {
                var entries: [NativeSpec] = []
                let registered = try registeredRepository(raw, repositories: repositories)
                let source = registered?["url"] as? String ?? (raw == "trunk" ? "https://cdn.cocoapods.org/" : raw)
                if let registered, let directory = try repositories.snapshot(registered) {
                    entries = try catalog(request.root, directory: directory, repository: source)
                } else if source.hasPrefix("https://") || source.hasPrefix("http://") {
                    if source.hasSuffix(".git") {
                        entries = try catalog(
                            request.root, directory: checkout(source, selector: "HEAD"), repository: source)
                    } else {
                        let hash = Insecure.MD5.hash(data: Data(request.root.utf8)).map { String(format: "%02x", $0) }
                            .joined()
                        let partition = hash.prefix(3).map(String.init).joined(separator: "/")
                        let base = source.hasSuffix("/") ? source : source + "/"
                        let index = try download(
                            base + "all_pods_versions_" + hash.prefix(3).map(String.init).joined(separator: "_")
                                + ".txt")
                        let line = try String(contentsOf: index, encoding: .utf8).split(separator: "\n").first {
                            $0.hasPrefix(request.root + "/")
                        }
                        for version in line?.split(separator: "/").dropFirst().map(String.init) ?? [] {
                            let url =
                                base + "Specs/" + partition + "/" + request.root + "/" + version + "/" + request.root
                                + ".podspec.json"
                            entries.append(
                                try NativeSpec(
                                    data: ["name": request.root, "version": version, "_spec_url": url],
                                    repository: source))
                        }
                    }
                } else if source.hasPrefix("git@") || source.hasPrefix("ssh://") {
                    entries = try catalog(
                        request.root, directory: checkout(source, selector: "HEAD"), repository: source)
                } else {
                    let directory =
                        source.hasPrefix("file://")
                        ? URL(string: source)! : URL(fileURLWithPath: source, relativeTo: project).standardizedFileURL
                    entries = try catalog(request.root, directory: directory, repository: source)
                }
                result += entries
            }
        }
        guard result.allSatisfy({ $0.name == request.root }) else {
            throw Diagnostic("SP-SOURCE-NAME", stage: "resolve", "External podspec name does not match \(request.root)")
        }
        if installationOptions["warn_for_multiple_pod_sources"] as? Bool != false {
            for (version, duplicates) in Dictionary(grouping: result, by: \.version).sorted(by: { $0.key < $1.key })
            where Set(duplicates.map(\.repository)).count > 1 {
                sourceWarnings.append([
                    "code": "SP-SOURCE-MULTIPLE",
                    "message":
                        "Multiple sources contain \(request.root) (\(version)); source order chooses equal versions",
                    "sources": duplicates.map(\.repository),
                ])
            }
        }
        found[request.root] = result
        return result
    }
    /// Content-store object names carry no extension. Preserve a JSON podspec's
    /// format for both hardened parsing and the Ruby checksum serializer.
    private func downloadedPodspec(_ location: String, pod: String) throws -> URL {
        let downloaded = try download(location, pod: pod)
        guard URL(string: location)?.pathExtension == "json" else { return downloaded }
        let content = try Data(contentsOf: downloaded)
        return try NativePodspecCache(cache: cache).project(content)
    }
    func materialize(_ candidate: NativeSpec) throws -> NativeSpec {
        if let file = candidate.catalogFile {
            let identity = candidate.repository + "\n" + file.path
            if let existing = materialized[identity] { return existing }
            let spec = try parsedSpec(file, repository: candidate.repository)
            guard spec.name == candidate.name, spec.version == candidate.version else {
                throw Diagnostic(
                    "SP-SOURCE-IDENTITY", stage: "resolve", "Catalog podspec identity differs from its index")
            }
            materialized[identity] = spec
            return spec
        }
        guard let url = candidate.data["_spec_url"] as? String else { return candidate }
        if let existing = materialized[url] { return existing }
        let file = try download(url)
        let spec = try NativeSpec(
            data: readObject(file), repository: candidate.repository, checksum: NativeLock.sha1(Data(contentsOf: file)))
        guard spec.name == candidate.name, spec.version == candidate.version else {
            throw Diagnostic("SP-SOURCE-IDENTITY", stage: "resolve", "CDN podspec identity differs from its index")
        }
        materialized[url] = spec
        return spec
    }
    /// One command keeps one catalog revision even if another command refreshes it.
    private func registeredRepository(_ raw: String, repositories: NativeRepositories) throws -> [String: Any]? {
        guard var entry = try repositories.record(raw), let name = entry["name"] as? String else { return nil }
        if let selected = registeredRepositories[name] { return selected }
        if refreshRepositories, !offline, entry["kind"] as? String == "git" {
            _ = try repositories.update(name)
            guard let updated = try repositories.record(name) else {
                throw Diagnostic(
                    "SP-REPO-MISSING", stage: "resolve", "Repository disappeared during refresh", file: name)
            }
            entry = updated
        }
        registeredRepositories[name] = entry
        return entry
    }

    private func catalog(_ name: String, directory: URL, repository: String) throws -> [NativeSpec] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        var result: [NativeSpec] = []
        while let file = enumerator.nextObject() as? URL {
            if [name + ".podspec.json", name + ".podspec"].contains(file.lastPathComponent) {
                if file.pathExtension != "json",
                    FileManager.default.fileExists(atPath: file.appendingPathExtension("json").path)
                {
                    continue
                }
                let parent = file.deletingLastPathComponent()
                if parent.deletingLastPathComponent().lastPathComponent == name,
                    (try? PodVersion(parent.lastPathComponent)) != nil
                {
                    var entry = try NativeSpec(
                        data: ["name": name, "version": parent.lastPathComponent], repository: repository)
                    entry.catalogFile = file
                    result.append(entry)
                } else {
                    result.append(try parsedSpec(file, repository: repository))
                }
            }
        }
        return result
    }
    private func parsedSpec(
        _ file: URL, repository: String = "", directory: URL? = nil, local: Bool = false, external: Bool = false
    ) throws -> NativeSpec {
        let data = try spec(file)
        return try NativeSpec(
            data: data, repository: repository, directory: directory, local: local,
            checksum: specChecksum(file, external: external || directory != nil))
    }
    private func specChecksum(_ file: URL, external: Bool) throws -> String {
        let raw = try NativeLock.sha1(Data(contentsOf: file))
        guard external, let dsl else { return raw }
        let serialized = try dsl.serializedSpec(file)
        let checksum = NativeLock.sha1(serialized)
        serializedSpecifications[checksum] = serialized
        checksumAliases[checksum, default: []].insert(raw)
        return checksum
    }
    private func findSpec(_ name: String, directory: URL) throws -> URL {
        for filename in [name + ".podspec.json", name + ".podspec"] {
            let file = directory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        throw Diagnostic("SP-SPEC-MISSING", stage: "resolve", "No podspec for \(name)", file: directory.path)
    }
}
func command(_ executable: String, _ arguments: [String], directory: URL? = nil) throws {
    let result = try ToolProcess.run(executable, arguments, directory: directory)
    let redactor = Redactor(environment: ProcessInfo.processInfo.environment)
    if !result.output.isEmpty {
        FileHandle.standardError.write(Data(redactor.scrub(String(decoding: result.output, as: UTF8.self)).utf8))
    }
    if !result.error.isEmpty {
        FileHandle.standardError.write(Data(redactor.scrub(String(decoding: result.error, as: UTF8.self)).utf8))
    }
    guard result.status == 0 else {
        throw Diagnostic(
            "SP-TOOL-FAILED", stage: "execute",
            "\(URL(fileURLWithPath: executable).lastPathComponent) exited with status \(result.status)")
    }
}
