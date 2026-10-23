import Darwin
import Dispatch
import Foundation

final class NativeCacheLock {
    private var descriptor: Int32
    init(cache: URL, key: String) throws {
        let root = cache.appendingPathComponent("locks")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        descriptor = open(root.appendingPathComponent(key).path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Diagnostic("SP-CACHE-LOCK", stage: "download", "Cannot open checkout lock") }
        do { try NativeCacheLease.lock(descriptor, LOCK_EX) } catch {
            close(descriptor)
            descriptor = -1
            throw error
        }
    }
    func release() {
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }
    deinit { release() }
}

private final class NativeDownloadResults {
    let lock = NSLock()
    var errors: [String: Error] = [:]
    var paths: [String: URL] = [:]
    func failed(_ name: String, _ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        errors[name] = error
    }
    func downloaded(_ name: String, _ path: URL) {
        lock.lock()
        defer { lock.unlock() }
        paths[name] = path
    }
}

extension NativeSources {
    func sourceIdentity(_ spec: NativeSpec) throws -> String {
        try digest(
            jsonData([
                "spec": spec.data, "external": sourceOptions(spec.name), "pin": pinnedCheckouts[spec.name] ?? [:],
                "clean": installationOptions["clean"] ?? true,
                "requests": selectedRequests.filter { $0.root == spec.name }.map { $0.name + ":" + $0.platform }
                    .sorted(), "lock": installationOptions["lock_pod_sources"] ?? true,
            ]))
    }
    func prefetch(_ specs: [String: NativeSpec]) throws {
        guard installationOptions["parallel_pod_downloads"] as? Bool == true else { return }
        let size = installationOptions["parallel_pod_download_thread_pool_size"] as? Int ?? 40
        guard size >= 0 else {
            throw Diagnostic(
                "SP-INSTALL-OPTION", stage: "download", "parallel_pod_download_thread_pool_size must be nonnegative")
        }
        let semaphore = DispatchSemaphore(value: max(1, min(size, 256)))
        let group = DispatchGroup()
        let results = NativeDownloadResults()
        for spec in specs.values.sorted(by: { $0.name < $1.name }) where !spec.local && spec.directory == nil {
            let source = spec.data["source"] as? [String: Any] ?? [:]
            guard source["git"] != nil || source["http"] != nil else { continue }
            semaphore.wait()
            group.enter()
            DispatchQueue.global().async {
                defer {
                    semaphore.signal()
                    group.leave()
                }
                do {
                    if let git = source["git"] as? String {
                        results.downloaded(
                            spec.name,
                            try self.checkout(
                                git, selector: self.pinnedSelector(spec.name, source: source),
                                fresh: self.shouldUpdate(spec.name), submodules: source["submodules"] as? Bool == true,
                                pod: spec.name))
                    } else if source["http"] != nil {
                        results.downloaded(
                            spec.name,
                            try self.downloadArchive(source, pod: spec.name))
                    }
                } catch { results.failed(spec.name, error) }
            }
        }
        group.wait()
        if let name = results.errors.keys.sorted().first { throw results.errors[name]! }
        prefetchedSources = results.paths
    }
    func finalize(_ specs: [String: NativeSpec], requests: [NativeDependency]) throws {
        for spec in specs.values where !spec.local {
            guard let root = spec.directory else { continue }
            var used = Set<URL>()
            var sources = Set<URL>()
            for request in requests where request.root == spec.name {
                let attributes = try spec.attributes(request.name, platform: request.platform)
                let files = Set(try NativeFileSelection.sourceFiles(attributes, root: root))
                sources.formUnion(
                    files.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true })
                used.formUnion(files)
                for key in [
                    "public_header_files", "private_header_files", "project_header_files", "resources",
                    "preserve_paths", "vendored_libraries", "vendored_frameworks", "prefix_header_file", "module_map",
                ] {
                    if attributes[key] is String || attributes[key] is [String] {
                        used.formUnion(try nativeGlob(attributes[key], root: root))
                    }
                }
                for patterns in (attributes["resource_bundles"] as? [String: Any] ?? [:]).values {
                    used.formUnion(try nativeGlob(patterns, root: root))
                }
                used.formUnion(try NativeOnDemandResources(attributes: attributes, root: root).files.keys)
            }
            used.formUnion(
                try nativeGlob(
                    ["*podspec*", "LICENSE{,.*}", "LICENCE{,.*}", "COPYING{,.*}", "README{,.*}", "readme{,.*}"],
                    root: root))
            if let license = spec.data["license"] as? [String: String], let file = license["file"] {
                used.insert(root.appendingPathComponent(file))
            }
            if installationOptions["clean"] as? Bool != false {
                try NativeSourceCleanup.run(root: root, used: used)
            }
            if installationOptions["lock_pod_sources"] as? Bool != false {
                for file in sources where FileManager.default.fileExists(atPath: file.path) {
                    let mode =
                        try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int ?? 0o644
                    try FileManager.default.setAttributes([.posixPermissions: mode & ~0o200], ofItemAtPath: file.path)
                }
            }
            let receipt = project.appendingPathComponent(
                "Pods/Target Support Files/" + spec.name + "/source-state.json")
            try FileManager.default.createDirectory(
                at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
            try jsonData(
                NativeSourceState.metadata(
                    identity: sourceIdentity(spec),
                    fingerprint: FileFingerprint.tree(root, requireContainedLinks: true),
                    checkout: spec.checkout)
            ).write(to: receipt, options: .atomic)
        }
    }
}

enum NativeVCS {
    static func export(_ source: [String: Any], destination: URL) throws -> [String: String] {
        try NativeSourceOptions.validate(source, file: destination.path)
        var checkout: [String: String] = [:]
        if let location = source["svn"] as? String {
            guard !CommandOptions.hasOptionPrefix(location) else {
                throw Diagnostic("SP-SOURCE-URL", stage: "download", "Invalid SVN source")
            }
            let suffix = source["tag"] as? String ?? source["branch"] as? String ?? source["folder"] as? String
            let url =
                suffix.map { location.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + $0 } ?? location
            var info = ["svn", "info", "--non-interactive", "--show-item", "revision"]
            let selectedRevision = try NativeSourceOptions.revision(source["revision"], file: location)
            if let revision = selectedRevision {
                info += ["-r", revision]
            }
            let infoURL = selectedRevision.map { svnPeggedURL(url, revision: $0) } ?? url
            let result = try ToolProcess.run("/usr/bin/env", info + ["--", infoURL])
            guard result.status == 0 else {
                throw Diagnostic("SP-SOURCE-SVN", stage: "download", String(decoding: result.error, as: UTF8.self))
            }
            let revision = String(decoding: result.output, as: UTF8.self).trimmingCharacters(
                in: .whitespacesAndNewlines)
            let arguments = ["svn", "export", "--non-interactive", "--force", "-r", revision]
            checkout = ["svn": location, "revision": revision]
            for key in ["tag", "branch", "folder"] { if let value = source[key] as? String { checkout[key] = value } }
            try command("/usr/bin/env", arguments + ["--", svnPeggedURL(url, revision: revision), destination.path])
        } else if let location = source["hg"] as? String {
            guard !CommandOptions.hasOptionPrefix(location) else {
                throw Diagnostic("SP-SOURCE-URL", stage: "download", "Invalid Mercurial source")
            }
            let revision =
                try NativeSourceOptions.revision(source["revision"], file: location) ?? source["tag"] as? String
                ?? source["branch"] as? String
            try command(
                "/usr/bin/env",
                ["hg", "clone"] + (revision.map { ["-u", $0] } ?? []) + ["--", location, destination.path])
            let result = try ToolProcess.run(
                "/usr/bin/env", ["hg", "-R", destination.path, "log", "-r", ".", "--template", "{node}"])
            guard result.status == 0 else {
                throw Diagnostic("SP-SOURCE-HG", stage: "download", "Cannot determine Mercurial revision")
            }
            checkout = [
                "hg": location,
                "revision": String(decoding: result.output, as: UTF8.self).trimmingCharacters(
                    in: .whitespacesAndNewlines),
            ]
            for key in ["tag", "branch"] { if let value = source[key] as? String { checkout[key] = value } }
            try FileManager.default.removeItem(at: destination.appendingPathComponent(".hg"))
        }
        _ = try FileFingerprint.tree(destination, requireContainedLinks: true)
        return checkout
    }

    /// An operative -r alone still resolves a path at HEAD. Preserve an explicit
    /// peg, but replace SVN's trailing @ escape with the selected revision.
    static func svnPeggedURL(_ url: String, revision: String) -> String {
        let scalars = url.unicodeScalars
        if let at = scalars.lastIndex(of: "@"),
            scalars.lastIndex(of: "/").map({ at > $0 }) ?? true
        {
            if scalars.index(after: at) != scalars.endIndex { return url }
            return String(scalars[..<at]) + "@" + revision
        }
        return url + "@" + revision
    }
}
