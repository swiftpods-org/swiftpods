import Foundation

enum NativeMaintenance {
    static func run(_ arguments: [String], cache: URL) throws -> [String: Any] {
        let lease = try NativeCacheLease(cache: cache, exclusive: true)
        defer { withExtendedLifetime(lease) {} }
        var args = arguments
        let command = args.removeFirst()
        let action = args.isEmpty ? "list" : args.removeFirst()
        if command == "repo" {
            let repositories = NativeRepositories(cache: cache)
            switch action {
            case "list":
                guard args.isEmpty else { throw Diagnostic("SP-CLI-ARGUMENT", stage: "repo", "Use repo list") }
                return ["repositories": try repositories.records()]
            case "add", "add-cdn":
                guard (2...3).contains(args.count) else {
                    throw Diagnostic("SP-CLI-ARGUMENT", stage: "repo", "Use repo add NAME URL [BRANCH]")
                }
                return [
                    "repository": try repositories.add(
                        name: args[0], url: args[1], branch: args.count == 3 ? args[2] : nil, cdn: action == "add-cdn")
                ]
            case "update":
                guard args.count <= 1 else {
                    throw Diagnostic("SP-CLI-ARGUMENT", stage: "repo", "Use repo update [NAME]")
                }
                return ["repositories": try repositories.update(args.first)]
            case "remove":
                guard args.count == 1 else {
                    throw Diagnostic("SP-CLI-ARGUMENT", stage: "repo", "Use repo remove NAME")
                }
                try repositories.remove(args[0])
                return ["removed": args[0]]
            default: throw Diagnostic("SP-CLI-ARGUMENT", stage: "repo", "Use repo list/add/add-cdn/update/remove")
            }
        }
        guard command == "cache", ["list", "clean"].contains(action),
            args.filter({ !CommandOptions.hasOptionPrefix($0) }).count <= 1,
            args.filter({ CommandOptions.hasOptionPrefix($0) }).allSatisfy({ ["--all", "--short"].contains($0) })
        else { throw Diagnostic("SP-CLI-ARGUMENT", stage: "cache", "Use cache list [POD] or cache clean POD/--all") }
        let query = args.first { !CommandOptions.hasOptionPrefix($0) }
        if action == "clean" {
            guard query != nil || args.contains("--all") else {
                throw Diagnostic("SP-CLI-ARGUMENT", stage: "cache", "Choose a pod or use --all explicitly")
            }
            return ["removed": try NativeCacheCleanup.run(cache: cache, pod: query)]
        }
        let store = try ContentStore(cacheRoot: cache)
        let podspecCache = NativePodspecCache(cache: cache)
        let podspecEntries = try podspecCache.entries().filter {
            query == nil || $0["name"] as? String == query
        }
        let prepared = cache.appendingPathComponent("prepared")
        var preparedEntries: [[String: Any]] = []
        for directory
            in (try? FileManager.default.contentsOfDirectory(
                at: prepared, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        where directory.lastPathComponent.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil {
            let receipt = try readObject(directory.appendingPathExtension("json"))
            guard let name = receipt["name"] as? String, let version = receipt["version"] as? String,
                receipt["fingerprint"] as? String == (try FileFingerprint.tree(directory, requireContainedLinks: true))
            else {
                throw Diagnostic(
                    "SP-CACHE-INTEGRITY", stage: "cache", "Prepared source cache changed", file: directory.path)
            }
            if query == nil || name == query {
                preparedEntries.append([
                    "id": directory.lastPathComponent, "kind": "prepared-source", "name": name, "version": version,
                    "pods": [name],
                ])
            }
        }
        let git = cache.appendingPathComponent("git")
        let snapshots = cache.appendingPathComponent("snapshots")
        var snapshotEntries: [[String: Any]] = []
        for directory
            in (try? FileManager.default.contentsOfDirectory(
                at: snapshots, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        where (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            && directory.lastPathComponent.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil
        {
            let metadata = try NativeSnapshotCache.maintenanceMetadata(directory)
            let names = metadata["pod_names"] as? [String] ?? []
            if query == nil || names.contains(query!) {
                snapshotEntries.append([
                    "id": directory.lastPathComponent, "kind": "source-snapshot", "pods": names,
                    "checkout": metadata["checkout"] ?? [:],
                ])
            }
        }
        let directories =
            (try? FileManager.default.contentsOfDirectory(at: git, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var gitEntries: [[String: Any]] = []
        var gitIdentities: [String: String] = [:]
        var gitOwners: [String: Set<String>] = [:]
        for directory in directories
        where (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            && directory.lastPathComponent.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil
        {
            guard FileManager.default.fileExists(atPath: directory.appendingPathExtension("sha256").path) else {
                continue
            }
            let metadata = try NativeGitCache.maintenanceMetadata(directory)
            if let identity = try NativeGitCache.ownershipIdentity(metadata) {
                gitIdentities[directory.lastPathComponent] = identity
                gitOwners[identity, default: []].formUnion(metadata["pod_names"] as? [String] ?? [])
            }
            gitEntries.append([
                "id": directory.lastPathComponent, "kind": "git", "revision": metadata["commit"] ?? "unknown",
                "pods": metadata["pod_names"] ?? [],
            ])
        }
        // Older installations registered the pod on only one copy of a checkout.
        // Recover ownership across verified copies before filtering or deleting.
        gitEntries = gitEntries.compactMap { entry in
            var entry = entry
            if let id = entry["id"] as? String, let identity = gitIdentities[id] {
                entry["pods"] = gitOwners[identity, default: []].sorted()
            }
            if let query, !(entry["pods"] as? [String] ?? []).contains(query) { return nil }
            return entry
        }
        let archives = try store.list().filter {
            query == nil || ($0["origin"] as? [String: Any])?["pod"] as? String == query
        }
        return ["entries": archives + gitEntries + preparedEntries + snapshotEntries + podspecEntries]
    }
}
