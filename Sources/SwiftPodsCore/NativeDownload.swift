import Foundation

extension NativeSources {
    func download(
        _ location: String, pod: String? = nil, headers: [String: String] = [:], checksums: [String: String] = [:]
    ) throws -> URL {
        guard let url = URL(string: location), ["http", "https"].contains(url.scheme ?? "") else {
            throw Diagnostic("SP-SOURCE-URL", stage: "download", "Expected an HTTP(S) source URL")
        }
        var origin: [String: Any] = [
            "url": Redactor(environment: ProcessInfo.processInfo.environment).scrub(location),
            "request_identity": digest(Data(location.utf8)), "kind": "native-download",
        ]
        if !headers.isEmpty { origin["headers_identity"] = try digest(jsonData(headers)) }
        let legacy = origin
        if !checksums.isEmpty { origin["checksums"] = checksums.mapValues { $0.lowercased() } }
        if let pod { origin["pod"] = pod }
        // Release the content-store lock before network I/O.
        let cached: [String: Any] = try {
            let store = try ContentStore(cacheRoot: cache)
            if try store.get(origin: origin)["status"] as? String == "miss" {
                var owned = legacy
                if let pod { owned["pod"] = pod }
                for previous in [owned, legacy] {
                    guard let path = try store.get(origin: previous)["path"] as? String else { continue }
                    let file = URL(fileURLWithPath: path)
                    let content = try Data(contentsOf: file)
                    guard (try? NativeArchive.verifyChecksums(content, source: checksums, pod: pod ?? location)) != nil
                    else { continue }
                    _ = try store.put(file: file, origin: origin)
                    break
                }
            }
            return try store.get(origin: origin)
        }()
        let refresh = pod.map(shouldUpdate) ?? refreshRepositories
        if !refresh || offline, let path = cached["path"] as? String {
            return URL(fileURLWithPath: path)
        }
        guard !offline else {
            throw Diagnostic("SP-OFFLINE-MISSING", stage: "download", "Source is not cached: \(location)")
        }
        let temporary = cache.appendingPathComponent(".download-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let result = try ToolProcess.run(
            "/usr/bin/curl",
            [
                "--fail", "--silent", "--show-error", "--location", "--proto", "=http,https", "--proto-redir",
                "=http,https", "--connect-timeout", "20", "--max-time", "120", "--output", temporary.path,
            ] + headers.sorted(by: { $0.key < $1.key }).flatMap { ["--header", $0.key + ": " + $0.value] } + [
                "--", location,
            ])
        guard result.status == 0 else {
            throw Diagnostic("SP-DOWNLOAD", stage: "download", String(decoding: result.error, as: UTF8.self))
        }
        try NativeArchive.verifyChecksums(Data(contentsOf: temporary), source: checksums, pod: pod ?? location)
        let store = try ContentStore(cacheRoot: cache)
        _ = try store.put(file: temporary, origin: origin)
        return URL(fileURLWithPath: try store.get(origin: origin)["path"] as! String)
    }

    func downloadArchive(_ source: [String: Any], pod: String) throws -> URL {
        guard let location = source["http"] as? String else {
            throw Diagnostic("SP-SOURCE-URL", stage: "download", "Missing HTTP archive URL", file: pod)
        }
        return try download(
            location, pod: pod, headers: source["headers"] as? [String: String] ?? [:],
            checksums: source.filter { ["sha1", "sha256"].contains($0.key) }.compactMapValues { $0 as? String })
    }
}
