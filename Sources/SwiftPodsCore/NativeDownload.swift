import Foundation

extension NativeSources {
    func download(_ location: String, pod: String? = nil, headers: [String: String] = [:]) throws -> URL {
        guard let url = URL(string: location), ["http", "https"].contains(url.scheme ?? "") else {
            throw Diagnostic("SP-SOURCE-URL", stage: "download", "Expected an HTTP(S) source URL")
        }
        var origin: [String: Any] = [
            "url": Redactor(environment: ProcessInfo.processInfo.environment).scrub(location),
            "request_identity": digest(Data(location.utf8)), "kind": "native-download",
        ]
        if !headers.isEmpty { origin["headers_identity"] = try digest(jsonData(headers)) }
        let legacy = origin
        if let pod { origin["pod"] = pod }
        // Release the content-store lock before network I/O.
        let cached: [String: Any] = try {
            let store = try ContentStore(cacheRoot: cache)
            if pod != nil, try store.get(origin: origin)["status"] as? String == "miss",
                let path = try store.get(origin: legacy)["path"] as? String
            {
                _ = try store.put(file: URL(fileURLWithPath: path), origin: origin)
            }
            return try store.get(origin: origin)
        }()
        if !refresh || offline, let path = cached["path"] as? String { return URL(fileURLWithPath: path) }
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
        let store = try ContentStore(cacheRoot: cache)
        _ = try store.put(file: temporary, origin: origin)
        return URL(fileURLWithPath: try store.get(origin: origin)["path"] as! String)
    }
}
