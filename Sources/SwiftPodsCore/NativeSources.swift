import Foundation
import CryptoKit
import Darwin

final class NativeSources {
    private let cacheLease: NativeCacheLease
    let project: URL
    let cache: URL
    let dsl: NativeDSL?
    let offline: Bool
    let refresh: Bool
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
    init(project: URL, cache: URL, sources: [String], dsl: NativeDSL?, offline: Bool, refresh: Bool, hardened: Bool) throws {
        cacheLease = try NativeCacheLease(cache: cache, exclusive: false)
        self.project = project; self.cache = cache; self.sources = sources
        self.dsl = dsl; self.offline = offline; self.refresh = refresh; self.hardened = hardened
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    }
    func register(_ dependencies: [NativeDependency]) throws {
        for dependency in dependencies {
            if let source = dependency.options["source"] as? String {
                if let previous = explicitSpecSources[dependency.root], previous != source { throw Diagnostic("SP-SOURCE-CONFLICT", stage: "resolve", "Conflicting spec repositories for " + dependency.root) }
                explicitSpecSources[dependency.root] = source
            }
        }
        for dependency in dependencies where ["path", "git", "podspec", "http", "svn", "hg"].contains(where: { dependency.options[$0] != nil }) {
            guard ["path", "git", "podspec", "http", "svn", "hg"].filter({ dependency.options[$0] != nil }).count == 1,
                  ["commit", "tag", "branch"].filter({ dependency.options[$0] != nil }).count <= 1 else {
                throw Diagnostic("SP-SOURCE-CONFLICT", stage: "resolve", "Specify one source and one Git selector for \(dependency.name)")
            }
            let options = dependency.options.filter { ["path", "git", "podspec", "http", "svn", "hg", "tag", "branch", "commit", "revision", "folder", "submodules", "flatten", "type", "sha256", "sha1", "headers"].contains($0.key) }
            if let before = external[dependency.root], try jsonData(before) != jsonData(options) {
                throw Diagnostic("SP-SOURCE-CONFLICT", stage: "resolve", "Conflicting external sources for \(dependency.root)")
            }
            external[dependency.root] = options
        }
    }
    func spec(_ url: URL) throws -> [String: Any] {
        if hardened && url.pathExtension != "json" { throw Diagnostic("SP-HARDENED-RUBY", stage: "policy", "Hardened installs require JSON podspecs", file: url.path) }
        if url.pathExtension == "json" { return try readObject(url) }
        guard let dsl else { throw Diagnostic("SP-DSL-MISSING", stage: "dsl", "Ruby adapter is needed to evaluate this podspec") }
        return try dsl.spec(url)
    }
    func candidates(_ request: NativeDependency) throws -> [NativeSpec] {
        if let existing = found[request.root] { return existing }
        var result: [NativeSpec] = []
        if let options = external[request.root] {
            if let path = options["path"] as? String {
                let directory = URL(fileURLWithPath: path, relativeTo: project).standardizedFileURL.resolvingSymlinksInPath()
                result = [try parsedSpec(findSpec(request.root, directory: directory), directory: directory, local: true)]
            } else if let git = options["git"] as? String {
                let directory = try checkout(git, selector: pinnedSelector(request.root, source: options), fresh: shouldUpdate(request.root), submodules: options["submodules"] as? Bool == true)
                result = [try parsedSpec(findSpec(request.root, directory: directory), directory: directory)]
            } else if let path = options["podspec"] as? String {
                let url = URL(string: path)
                let file = url?.scheme == "https" || url?.scheme == "http" ? try download(path) : URL(fileURLWithPath: path, relativeTo: project).standardizedFileURL
                let data: [String: Any]
                if path.hasSuffix(".json") { data = try readObject(file) }
                else { data = try spec(file) }
                result = [try NativeSpec(data: data, checksum: specChecksum(file, external: true))]
            } else if options["http"] != nil || options["svn"] != nil || options["hg"] != nil {
                let directory = try sourceSnapshot(options, pod: request.root)
                result = [try parsedSpec(findSpec(request.root, directory: directory), directory: directory)]
            }
        } else {
            let selected = explicitSpecSources[request.root] ?? request.options["source"] as? String ?? lockedRepositories[request.root]
            let repositories = NativeRepositories(cache: cache)
            for raw in selected.map({ [$0] }) ?? sources {
                var entries: [NativeSpec] = []
                let registered = try repositories.record(raw)
                let source = registered?["url"] as? String ?? (raw == "trunk" ? "https://cdn.cocoapods.org/" : raw)
                if let registered, let directory = try repositories.snapshot(registered) {
                    entries = try catalog(request.root, directory: directory, repository: source)
                } else if source.hasPrefix("https://") || source.hasPrefix("http://") {
                    if source.hasSuffix(".git") {
                        entries = try catalog(request.root, directory: checkout(source, selector: "HEAD"), repository: source)
                    } else {
                        let hash = Insecure.MD5.hash(data: Data(request.root.utf8)).map { String(format: "%02x", $0) }.joined()
                        let partition = hash.prefix(3).map(String.init).joined(separator: "/")
                        let base = source.hasSuffix("/") ? source : source + "/"
                        let index = try download(base + "all_pods_versions_" + hash.prefix(3).map(String.init).joined(separator: "_") + ".txt")
                        let line = try String(contentsOf: index, encoding: .utf8).split(separator: "\n").first { $0.hasPrefix(request.root + "/") }
                        for version in line?.split(separator: "/").dropFirst().map(String.init) ?? [] {
                            let url = base + "Specs/" + partition + "/" + request.root + "/" + version + "/" + request.root + ".podspec.json"
                            entries.append(try NativeSpec(data: ["name": request.root, "version": version, "_spec_url": url], repository: source))
                        }
                    }
                } else if source.hasPrefix("git@") || source.hasPrefix("ssh://") {
                    entries = try catalog(request.root, directory: checkout(source, selector: "HEAD"), repository: source)
                } else {
                    let directory = source.hasPrefix("file://") ? URL(string: source)! : URL(fileURLWithPath: source, relativeTo: project).standardizedFileURL
                    entries = try catalog(request.root, directory: directory, repository: source)
                }
                result += entries
            }
        }
        guard result.allSatisfy({ $0.name == request.root }) else { throw Diagnostic("SP-SOURCE-NAME", stage: "resolve", "External podspec name does not match \(request.root)") }
        if installationOptions["warn_for_multiple_pod_sources"] as? Bool != false {
            for (version, duplicates) in Dictionary(grouping: result, by: \.version).sorted(by: { $0.key < $1.key }) where Set(duplicates.map(\.repository)).count > 1 {
                sourceWarnings.append(["code": "SP-SOURCE-MULTIPLE", "message": "Multiple sources contain \(request.root) (\(version)); source order chooses equal versions", "sources": duplicates.map(\.repository)])
            }
        }
        found[request.root] = result
        return result
    }
    func materialize(_ candidate: NativeSpec) throws -> NativeSpec {
        guard let url = candidate.data["_spec_url"] as? String else { return candidate }
        if let existing = materialized[url] { return existing }
        let file = try download(url)
        let spec = try NativeSpec(data: readObject(file), repository: candidate.repository, checksum: NativeLock.sha1(Data(contentsOf: file)))
        guard spec.name == candidate.name, spec.version == candidate.version else {
            throw Diagnostic("SP-SOURCE-IDENTITY", stage: "resolve", "CDN podspec identity differs from its index")
        }
        materialized[url] = spec
        return spec
    }
    private func catalog(_ name: String, directory: URL, repository: String) throws -> [NativeSpec] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var result: [NativeSpec] = []
        while let file = enumerator.nextObject() as? URL {
            if [name + ".podspec.json", name + ".podspec"].contains(file.lastPathComponent) {
                result.append(try parsedSpec(file, repository: repository))
            }
        }
        return result
    }
    private func parsedSpec(_ file: URL, repository: String = "", directory: URL? = nil, local: Bool = false) throws -> NativeSpec {
        let data = try spec(file)
        return try NativeSpec(data: data, repository: repository, directory: directory, local: local, checksum: specChecksum(file, external: directory != nil))
    }
    private func specChecksum(_ file: URL, external: Bool) throws -> String {
        let raw = try NativeLock.sha1(Data(contentsOf: file))
        guard external, let dsl else { return raw }
        let serialized = try dsl.serializedSpec(file), checksum = NativeLock.sha1(serialized)
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
    func download(_ location: String, pod: String? = nil, headers: [String: String] = [:]) throws -> URL {
        guard let url = URL(string: location), ["http", "https"].contains(url.scheme ?? "") else { throw Diagnostic("SP-SOURCE-URL", stage: "download", "Expected an HTTP(S) source URL") }
        var origin: [String: Any] = ["url": Redactor(environment: ProcessInfo.processInfo.environment).scrub(location), "request_identity": digest(Data(location.utf8)), "kind": "native-download"]
        if !headers.isEmpty { origin["headers_identity"] = try digest(jsonData(headers)) }
        let legacy = origin
        if let pod { origin["pod"] = pod }
        // Release the content-store lock before network I/O.
        let cached: [String: Any] = try {
            let store = try ContentStore(cacheRoot: cache)
            if pod != nil, try store.get(origin: origin)["status"] as? String == "miss", let path = try store.get(origin: legacy)["path"] as? String { _ = try store.put(file: URL(fileURLWithPath: path), origin: origin) }
            return try store.get(origin: origin)
        }()
        if (!refresh || offline), let path = cached["path"] as? String { return URL(fileURLWithPath: path) }
        guard !offline else { throw Diagnostic("SP-OFFLINE-MISSING", stage: "download", "Source is not cached: \(location)") }
        let temporary = cache.appendingPathComponent(".download-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let result = try ToolProcess.run("/usr/bin/curl", ["--fail", "--silent", "--show-error", "--location", "--proto", "=http,https", "--proto-redir", "=http,https", "--connect-timeout", "20", "--max-time", "120", "--output", temporary.path] + headers.sorted(by: { $0.key < $1.key }).flatMap { ["--header", $0.key + ": " + $0.value] } + ["--", location])
        guard result.status == 0 else { throw Diagnostic("SP-DOWNLOAD", stage: "download", String(decoding: result.error, as: UTF8.self)) }
        let store = try ContentStore(cacheRoot: cache)
        _ = try store.put(file: temporary, origin: origin)
        return URL(fileURLWithPath: try store.get(origin: origin)["path"] as! String)
    }
    func checkout(_ location: String, selector: String, fresh: Bool = false, submodules: Bool = false) throws -> URL {
        guard !location.hasPrefix("-"), !selector.hasPrefix("-"), !selector.isEmpty else { throw Diagnostic("SP-SOURCE-URL", stage: "download", "Invalid Git source or revision") }
        let identity = digest(Data((location + "\n" + selector + (submodules ? "\nsubmodules" : "")).utf8))
        let directory = cache.appendingPathComponent("git/" + identity)
        let cacheLock = try NativeCacheLock(cache: cache, key: identity)
        defer { cacheLock.release() }
        let receipt = directory.appendingPathExtension("sha256")
        if FileManager.default.fileExists(atPath: directory.path), ((!refresh && !fresh) || offline) {
            guard let expected = try? String(contentsOf: receipt, encoding: .utf8), try FileFingerprint.tree(directory, requireContainedLinks: true) == expected else {
                throw Diagnostic("SP-CACHE-INTEGRITY", stage: "cache", "Cached Git checkout changed", file: directory.path)
            }
            if !FileManager.default.fileExists(atPath: directory.appendingPathExtension("origin.json").path) {
                guard selector.range(of: #"\A[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?\z"#, options: .regularExpression) != nil else { throw Diagnostic("SP-CACHE-REVISION", stage: "cache", "Cached checkout predates revision metadata; refresh it with --repo-update", file: directory.path) }
                try jsonData(["commit": selector, "origin_identity": digest(Data(location.utf8))]).write(to: directory.appendingPathExtension("origin.json"), options: .atomic)
            }
            try cacheCommit(directory, location: location)
            return directory
        }
        guard !offline else { throw Diagnostic("SP-OFFLINE-MISSING", stage: "download", "Git source is not cached: \(location)") }
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = directory.deletingLastPathComponent().appendingPathComponent(".git-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try command("/usr/bin/git", ["clone", "--no-checkout", "--", location, staging.path])
        try command("/usr/bin/git", ["-C", staging.path, "checkout", "--detach", selector])
        if submodules, FileManager.default.fileExists(atPath: staging.appendingPathComponent(".gitmodules").path) {
            try command("/usr/bin/git", ["-C", staging.path, "submodule", "update", "--init", "--recursive"])
        }
        let revision = try ToolProcess.run("/usr/bin/git", ["-C", staging.path, "rev-parse", "HEAD"])
        guard revision.status == 0 else { throw Diagnostic("SP-SOURCE-REVISION", stage: "download", "Cannot record Git checkout revision") }
        let commit = String(decoding: revision.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        try FileManager.default.removeItem(at: staging.appendingPathComponent(".git"))
        let fingerprint = try FileFingerprint.tree(staging, requireContainedLinks: true)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        try FileManager.default.moveItem(at: staging, to: directory)
        try Data(fingerprint.utf8).write(to: receipt, options: .atomic)
        try jsonData(["commit": commit, "origin_identity": digest(Data(location.utf8)), "submodules": submodules]).write(to: directory.appendingPathExtension("origin.json"), options: .atomic)
        try cacheCommit(directory, location: location)
        return directory
    }
    func install(_ input: NativeSpec) throws -> NativeSpec {
        var spec = input
        if spec.local { try prepare(spec); return spec }
        let destination = project.appendingPathComponent("Pods/" + spec.name)
        let receipt = project.appendingPathComponent("Pods/Target Support Files/" + spec.name + "/source-state.json")
        if installationOptions["incremental_installation"] as? Bool == true, !cleanInstall, !shouldUpdate(spec.name), let previous = try? readObject(receipt), previous["identity"] as? String == (try sourceIdentity(spec)), previous["fingerprint"] as? String == (try FileFingerprint.tree(destination, requireContainedLinks: true)) {
            spec.directory = destination; spec.checkout = previous["checkout"] as? [String: String] ?? [:]; return spec
        }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        if let directory = spec.directory {
            try FileManager.default.copyItem(at: directory, to: destination)
            if !spec.local { spec.checkout = try sourceCheckoutIdentity(spec.name, source: external[spec.name] ?? (spec.data["source"] as? [String: Any] ?? [:]), directory: directory) }
        } else {
            let source = spec.data["source"] as? [String: Any] ?? [:]
            if let git = source["git"] as? String {
                let directory = try prefetchedSources[spec.name] ?? checkout(git, selector: pinnedSelector(spec.name, source: source), fresh: shouldUpdate(spec.name), submodules: source["submodules"] as? Bool == true)
                try FileManager.default.copyItem(at: directory, to: destination)
                spec.checkout = try checkoutIdentity(spec.name, source: source, directory: directory)
            } else if let http = source["http"] as? String {
                let archive = try prefetchedSources[spec.name] ?? download(http, pod: spec.name, headers: source["headers"] as? [String: String] ?? [:]), data = try Data(contentsOf: archive)
                if let sha = source["sha256"] as? String, digest(data) != sha.lowercased() { throw Diagnostic("SP-SOURCE-CHECKSUM", stage: "download", "Archive SHA-256 mismatch for \(spec.name)") }
                if let sha = source["sha1"] as? String, Insecure.SHA1.hash(data: data).map({ String(format: "%02x", $0) }).joined() != sha.lowercased() { throw Diagnostic("SP-SOURCE-CHECKSUM", stage: "download", "Archive SHA-1 mismatch for \(spec.name)") }
                try ExecutionPolicy.validateArchive(archive.path)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try command("/usr/bin/tar", ["-xf", archive.path, "-C", destination.path])
                _ = try FileFingerprint.tree(destination, requireContainedLinks: true)
                let children = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: [.isDirectoryKey]).filter { $0.lastPathComponent != "__MACOSX" }
                if source["flatten"] as? Bool != false, children.count == 1, (try children[0].resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
                    for child in try FileManager.default.contentsOfDirectory(at: children[0], includingPropertiesForKeys: nil) { try FileManager.default.moveItem(at: child, to: destination.appendingPathComponent(child.lastPathComponent)) }
                    try FileManager.default.removeItem(at: children[0])
                }
            } else if source["svn"] != nil || source["hg"] != nil {
                let directory = try sourceSnapshot(source, pod: spec.name)
                try FileManager.default.copyItem(at: directory, to: destination)
                spec.checkout = try sourceCheckoutIdentity(spec.name, source: source, directory: directory)
            } else { throw Diagnostic("SP-SOURCE-UNSUPPORTED", stage: "download", "\(spec.name) requires a supported :git, :http, :svn or :hg source") }
        }
        spec.directory = destination
        try prepareCached(spec)
        return spec
    }
    func prepare(_ spec: NativeSpec) throws {
        if let script = spec.data["prepare_command"] as? String, !script.isEmpty {
            guard !hardened else { throw Diagnostic("SP-HARDENED-SCRIPT", stage: "policy", "prepare_command is forbidden", file: spec.name) }
            try command("/bin/sh", ["-c", script], directory: spec.directory)
        }
    }
}

func command(_ executable: String, _ arguments: [String], directory: URL? = nil) throws {
    let result = try ToolProcess.run(executable, arguments, directory: directory)
    let redactor = Redactor(environment: ProcessInfo.processInfo.environment)
    if !result.output.isEmpty { FileHandle.standardError.write(Data(redactor.scrub(String(decoding: result.output, as: UTF8.self)).utf8)) }
    if !result.error.isEmpty { FileHandle.standardError.write(Data(redactor.scrub(String(decoding: result.error, as: UTF8.self)).utf8)) }
    guard result.status == 0 else { throw Diagnostic("SP-TOOL-FAILED", stage: "execute", "\(URL(fileURLWithPath: executable).lastPathComponent) exited with status \(result.status)") }
}
