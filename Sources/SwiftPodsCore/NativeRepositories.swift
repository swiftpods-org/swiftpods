import Foundation

struct NativeRepositories {
    let cache: URL
    var root: URL { cache.appendingPathComponent("repositories") }
    func records() throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter {
            $0.pathExtension == "json"
        }.sorted { $0.path < $1.path }.map { path in
            let entry = try readObject(path)
            guard let name = entry["name"] as? String, name == path.deletingPathExtension().lastPathComponent,
                let url = entry["url"] as? String, !url.isEmpty, !CommandOptions.hasOptionPrefix(url),
                let kind = entry["kind"] as? String, ["git", "cdn"].contains(kind),
                path.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath()
            else { throw Diagnostic("SP-REPO-RECORD", stage: "repo", "Invalid repository record", file: path.path) }
            try validate(name)
            if kind == "git" {
                guard let revision = entry["revision"] as? String,
                    revision.range(of: #"\A[0-9a-fA-F]{40,64}\z"#, options: .regularExpression) != nil,
                    root.appendingPathComponent(name).resolvingSymlinksInPath().deletingLastPathComponent()
                        == root.resolvingSymlinksInPath()
                else {
                    throw Diagnostic("SP-REPO-RECORD", stage: "repo", "Invalid repository checkout", file: path.path)
                }
            }
            return entry
        }
    }
    func record(_ name: String) throws -> [String: Any]? {
        try records().first { $0["name"] as? String == name || $0["url"] as? String == name }
    }
    func validate(_ name: String) throws {
        guard name.range(of: #"\A[A-Za-z0-9_-][A-Za-z0-9_.-]*\z"#, options: .regularExpression) != nil else {
            throw Diagnostic("SP-REPO-NAME", stage: "repo", "Invalid repository name", file: name)
        }
    }
    func write(_ record: [String: Any]) throws {
        let name = record["name"] as! String
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try jsonData(record).write(to: root.appendingPathComponent(name + ".json"), options: .atomic)
    }
    func revision(_ directory: URL) throws -> String {
        let value = try ToolProcess.run("/usr/bin/git", ["-C", directory.path, "rev-parse", "HEAD"])
        guard value.status == 0 else {
            throw Diagnostic("SP-REPO-GIT", stage: "repo", "Cannot determine repository revision", file: directory.path)
        }
        return String(decoding: value.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func requireClean(_ directory: URL) throws {
        let value = try ToolProcess.run("/usr/bin/git", ["-C", directory.path, "status", "--porcelain"])
        guard value.status == 0, value.output.isEmpty else {
            throw Diagnostic("SP-REPO-DIRTY", stage: "repo", "Repository contains local changes", file: directory.path)
        }
    }
    func add(name: String, url: String, branch: String?, cdn: Bool = false) throws -> [String: Any] {
        try validate(name)
        if let old = try record(name) {
            guard old["url"] as? String == url, old["branch"] as? String == branch else {
                throw Diagnostic(
                    "SP-REPO-CONFLICT", stage: "repo", "Repository name already has a different source", file: name)
            }
            return old
        }
        guard !CommandOptions.hasOptionPrefix(url), branch.map({ CommandOptions.hasOptionPrefix($0) }) != true else {
            throw Diagnostic("SP-REPO-URL", stage: "repo", "Invalid source or branch")
        }
        if cdn, !(url.hasPrefix("https://") || url.hasPrefix("http://")) {
            throw Diagnostic("SP-REPO-URL", stage: "repo", "CDN sources require HTTP(S)")
        }
        var entry: [String: Any] = ["name": name, "url": url, "kind": cdn ? "cdn" : "git"]
        if let branch { entry["branch"] = branch }
        if !cdn {
            let destination = root.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw Diagnostic(
                    "SP-REPO-CONFLICT", stage: "repo", "Destination exists without a repository record",
                    file: destination.path)
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let staging = root.appendingPathComponent(".add-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: staging) }
            try command(
                "/usr/bin/git", ["clone"] + (branch.map { ["--branch", $0] } ?? []) + ["--", url, staging.path])
            entry["revision"] = try revision(staging)
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        try write(entry)
        return entry
    }
    func update(_ name: String?) throws -> [[String: Any]] {
        let entries = try records().filter { name == nil || $0["name"] as? String == name }
        if let name, entries.isEmpty {
            throw Diagnostic("SP-REPO-MISSING", stage: "repo", "Repository is not registered", file: name)
        }
        return try entries.map { old in
            var entry = old
            if entry["kind"] as? String == "git" {
                let repositoryLock = try NativeCacheLock(cache: cache, key: repositoryKey(entry))
                defer { repositoryLock.release() }
                let directory = root.appendingPathComponent(entry["name"] as! String)
                try requireClean(directory)
                try command(
                    "/usr/bin/git", ["fetch", "origin", entry["branch"] as? String ?? "HEAD"], directory: directory)
                try command("/usr/bin/git", ["merge", "--ff-only", "FETCH_HEAD"], directory: directory)
                entry["revision"] = try revision(directory)
                try write(entry)
            }
            return entry
        }
    }
    func remove(_ name: String) throws {
        try validate(name)
        guard let entry = try record(name), entry["name"] as? String == name else {
            throw Diagnostic("SP-REPO-MISSING", stage: "repo", "Repository is not registered", file: name)
        }
        if entry["kind"] as? String == "git" {
            let directory = root.appendingPathComponent(name)
            try requireClean(directory)
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.removeItem(at: root.appendingPathComponent(name + ".json"))
    }
    func snapshot(_ entry: [String: Any]) throws -> URL? {
        guard entry["kind"] as? String == "git", let url = entry["url"] as? String,
            let commit = entry["revision"] as? String
        else { return nil }
        let repositoryLock = try NativeCacheLock(cache: cache, key: repositoryKey(entry))
        defer { repositoryLock.release() }
        let directory = cache.appendingPathComponent("git/" + digest(Data((url + "\n" + commit).utf8)))
        let cacheLock = try NativeCacheLock(cache: cache, key: directory.lastPathComponent)
        defer { cacheLock.release() }
        var previousOwners: [String] = []
        if FileManager.default.fileExists(atPath: directory.path) {
            if (try? readObject(directory.appendingPathExtension("sha256"))) != nil {
                let metadata = try NativeGitCache.verify(directory)
                guard metadata["commit"] as? String == commit,
                    metadata["origin_identity"] as? String == digest(Data(url.utf8)),
                    metadata["submodules"] as? Bool != true
                else { throw Diagnostic("SP-CACHE-INTEGRITY", stage: "repo", "Repository snapshot origin changed") }
                return directory
            }
            // A legacy tree receipt cannot authenticate its revision. Verify its
            // files, then rebuild from the pinned registered checkout locally.
            previousOwners = try NativeGitCache.maintenanceMetadata(directory)["pod_names"] as? [String] ?? []
        }
        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = directory.deletingLastPathComponent().appendingPathComponent(".repo-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try command(
            "/usr/bin/git",
            ["clone", "--no-checkout", "--", root.appendingPathComponent(entry["name"] as! String).path, staging.path])
        try command("/usr/bin/git", ["checkout", "--detach", commit], directory: staging)
        try FileManager.default.removeItem(at: staging.appendingPathComponent(".git"))
        _ = try FileFingerprint.tree(staging, requireContainedLinks: true)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        try FileManager.default.moveItem(at: staging, to: directory)
        try NativeGitCache.write(
            directory,
            metadata: [
                "commit": commit, "origin_identity": digest(Data(url.utf8)), "submodules": false,
                "pod_names": previousOwners,
            ])
        return directory
    }

    private func repositoryKey(_ entry: [String: Any]) -> String {
        "repository-" + digest(Data((entry["name"] as? String ?? "").utf8))
    }
}
