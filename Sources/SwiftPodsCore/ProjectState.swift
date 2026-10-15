import Darwin
import Foundation

/// Snapshots project files and the Pods tree. Ruby side effects outside this
/// scope and external services remain outside rollback.
public final class ProjectState {
    public let directory: URL
    private var lockFD: Int32 = -1
    private var trackedPaths: [String] = []
    private var includePodfile = false
    public init(directory: URL) { self.directory = directory }
    deinit {
        if lockFD >= 0 {
            flock(lockFD, LOCK_UN)
            close(lockFD)
        }
    }

    public func acquire(recovery: Bool = false) throws {
        let root = directory.appendingPathComponent(".swiftpods")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: root.path),
            attributes[.type] as? FileAttributeType == .typeSymbolicLink
        {
            throw Diagnostic("SP-STATE-PATH", stage: "prepare", ".swiftpods must not be a symlink")
        }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if lockFD < 0 {
            lockFD = open(root.appendingPathComponent("process.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard lockFD >= 0 else {
                throw Diagnostic("SP-STATE-LOCK", stage: "prepare", "Cannot open project process lock")
            }
            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
                close(lockFD)
                lockFD = -1
                throw Diagnostic(
                    "SP-STATE-BUSY", stage: "prepare", "Another SwiftPods mutation is running for this project")
            }
        }
        let stateURL = root.appendingPathComponent("state.json")
        if !recovery, exists(stateURL) {
            let existing = try readObject(stateURL)
            if ["running", "recovery_required"].contains(existing["status"] as? String ?? "") {
                throw Diagnostic(
                    "SP-STATE-RECOVERY", stage: "prepare",
                    "An earlier mutation did not complete. Run swiftpods recover before continuing.",
                    state: "recovery_required")
            }
        }
    }

    private func managedURL(_ path: String) -> URL {
        (path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)).standardizedFileURL
    }
    private func validExternal(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return path.hasPrefix("/") && url.path == path && url.resolvingSymlinksInPath().path == path
            && ((url.lastPathComponent == "project.pbxproj"
                && url.deletingLastPathComponent().pathExtension == "xcodeproj")
                || (url.lastPathComponent == "contents.xcworkspacedata"
                    && url.deletingLastPathComponent().pathExtension == "xcworkspace"))
    }
    public func registerProject(_ file: URL) throws {
        let canonical = file.standardizedFileURL.resolvingSymlinksInPath()
        guard !canonical.path.hasPrefix(directory.resolvingSymlinksInPath().path + "/") else { return }
        guard validExternal(canonical.path) else {
            throw Diagnostic("SP-STATE-PATH", stage: "prepare", "Invalid external project", file: canonical.path)
        }
        let stateURL = directory.appendingPathComponent(".swiftpods/state.json")
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return }
        var state = try readObject(stateURL)
        guard state["status"] as? String == "running" else { return }
        var entries = state["journal"] as? [[String: Any]] ?? []
        guard !entries.contains(where: { $0["path"] as? String == canonical.path }) else { return }
        let name = String(entries.count)
        let existed = exists(canonical)
        if existed {
            try FileManager.default.copyItem(
                at: canonical, to: directory.appendingPathComponent(".swiftpods/backup/" + name))
        }
        entries.append([
            "path": canonical.path, "backup": name, "existed": existed, "before_digest": try fingerprint(canonical),
        ])
        state["journal"] = entries
        state["external_paths"] = Set(nativeStrings(state["external_paths"]) + [canonical.path]).sorted()
        try write(state)
    }

    public func write(_ object: [String: Any], file: String = "state.json") throws {
        let destination = directory.appendingPathComponent(".swiftpods/" + file)
        try jsonData(object).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    public func begin(command: [String], profile: String) throws {
        includePodfile = command.first == "init"
        var state: [String: Any] = [
            "schema_version": 1, "fingerprint_version": 2, "producer": "SwiftPods", "status": "running",
            "command": command, "profile": profile, "started_at": ISO8601DateFormatter().string(from: Date()),
            "rollback_scope":
                "Pods, Podfile.lock and Xcode project/workspace files inside this project and explicitly selected external projects; other Ruby side effects and external services are not covered",
        ]
        if let data = try? Data(contentsOf: directory.appendingPathComponent("Podfile.lock")) {
            state["input_lock_digest"] = digest(data)
        }
        let backup = directory.appendingPathComponent(".swiftpods/backup")
        if FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.removeItem(at: backup) }
        try FileManager.default.createDirectory(
            at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let previous = (try? readObject(directory.appendingPathComponent(".swiftpods/state.json"))) ?? [:]
        let externals = nativeStrings(previous["external_paths"]).filter(validExternal)
        state["external_paths"] = externals
        trackedPaths = Array(Set(managedPaths() + externals)).sorted()
        var entries: [[String: Any]] = []
        for (index, relative) in trackedPaths.enumerated() {
            let path = managedURL(relative)
            let existed = exists(path)
            let name = String(index)
            if existed { try FileManager.default.copyItem(at: path, to: backup.appendingPathComponent(name)) }
            entries.append([
                "path": relative, "backup": name, "existed": existed, "before_digest": try fingerprint(path),
            ])
        }
        state["journal"] = entries
        try write(state)
    }

    @discardableResult public func finish(result: HostResult, command: [String], profile: String) throws -> String {
        try NativeCancellation.cleanup {
            var state = (try? readObject(directory.appendingPathComponent(".swiftpods/state.json"))) ?? [:]
            state.merge([
                "schema_version": 1, "producer": "SwiftPods", "profile": profile,
                "command": command, "status": result.status == 0 ? "complete" : "recovery_required",
                "exit_status": result.status, "finished_at": ISO8601DateFormatter().string(from: Date()),
            ]) { _, new in new }
            var entries = state["journal"] as? [[String: Any]] ?? []
            for relative in managedPaths() where !entries.contains(where: { $0["path"] as? String == relative }) {
                entries.append(["path": relative, "backup": "", "existed": false, "before_digest": "absent"])
            }
            if result.status == 0, let packages = result.events.last(where: { $0["kind"] as? String == "spm_state" }) {
                try write(packages, file: "spm.json")
            }
            if let report = result.events.last(where: { $0["kind"] as? String == "installation" }), result.status == 0 {
                var report = report
                report["schema_version"] = 1
                report["recorded_at"] = ISO8601DateFormatter().string(from: Date())
                let manifest =
                    (report["input_manifest"] as? String).map { URL(fileURLWithPath: $0) }
                    ?? directory.appendingPathComponent("Podfile")
                if let data = try? Data(contentsOf: manifest) { report["podfile_digest"] = digest(data) }
                if let data = try? Data(contentsOf: directory.appendingPathComponent("Podfile.lock")) {
                    report["lock_digest"] = digest(data)
                }
                try write(report, file: "installation.json")
                state["installation_report"] = "installation.json"
            }
            for index in entries.indices {
                let path = managedURL(entries[index]["path"] as! String)
                let after = try fingerprint(path)
                entries[index]["after_digest"] = after
                let conflicts = result.events.filter { $0["kind"] as? String == "external_conflict" }.compactMap {
                    $0["path"] as? String
                }
                let writes = result.events.filter { $0["kind"] as? String == "managed_write" }.compactMap {
                    $0["path"] as? String
                }
                let samePath: (String) -> Bool = {
                    URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath()
                        == path.standardizedFileURL.resolvingSymlinksInPath()
                }
                let projectFile = ["project.pbxproj", "contents.xcworkspacedata"].contains(path.lastPathComponent)
                if conflicts.contains(where: samePath)
                    || (projectFile && entries[index]["before_digest"] as? String != after
                        && !writes.contains(where: samePath))
                {
                    entries[index]["preserve_external"] = true
                }
            }
            state["journal"] = entries
            if result.status != 0
                && entries.allSatisfy({ $0["before_digest"] as? String == $0["after_digest"] as? String })
            {
                state["status"] = "failed_no_managed_changes"
            }
            try write(state)
            return state["status"] as? String ?? "unknown"
        }
    }

    public func recover() throws -> [String: Any] {
        try acquire(recovery: true)
        var state = try readObject(directory.appendingPathComponent(".swiftpods/state.json"))
        guard state["status"] as? String == "recovery_required" || state["status"] as? String == "running" else {
            throw Diagnostic("SP-RECOVER-NOT-NEEDED", stage: "recovery", "No interrupted installation is recorded")
        }
        let entries = state["journal"] as? [[String: Any]] ?? []
        let fingerprint: (URL) throws -> String =
            state["fingerprint_version"] as? Int == 2
            ? { try FileFingerprint.tree($0) } : { try self.legacyFingerprint($0) }
        guard !entries.isEmpty else {
            throw Diagnostic("SP-STATE-INVALID", stage: "recovery", "Missing recovery journal")
        }
        for entry in entries {
            guard let relative = entry["path"] as? String, !relative.isEmpty,
                relative.hasPrefix("/")
                    ? (validExternal(relative) && nativeStrings(state["external_paths"]).contains(relative))
                    : (!relative.split(separator: "/").contains(where: { $0 == ".." || $0 == "." })
                        && (!relative.hasPrefix(".swiftpods")
                            || [".swiftpods/installation.json", ".swiftpods/spm.json"].contains(relative))
                        && managedURL(relative).resolvingSymlinksInPath().path.hasPrefix(
                            directory.resolvingSymlinksInPath().path + "/")),
                let after = entry["after_digest"] as? String
            else {
                throw Diagnostic(
                    "SP-RECOVER-UNVERIFIED", stage: "recovery",
                    "The command ended before final fingerprints were recorded; automatic overwrite is unsafe. Inspect .swiftpods/backup and state.json.",
                    state: "recovery_required")
            }
            if entry["preserve_external"] as? Bool == true { continue }
            let current = try fingerprint(managedURL(relative))
            guard current == after || current == entry["before_digest"] as? String else {
                throw Diagnostic(
                    "SP-RECOVER-CONFLICT", stage: "recovery",
                    "File changed after the failed command; recovery will not overwrite it", file: relative,
                    state: "recovery_required")
            }
            if entry["existed"] as? Bool == true {
                guard let backup = entry["backup"] as? String, !backup.isEmpty, backup.allSatisfy(\.isNumber) else {
                    throw Diagnostic("SP-STATE-INVALID", stage: "recovery", "Invalid backup name")
                }
                if let expected = entry["before_digest"] as? String,
                    try fingerprint(directory.appendingPathComponent(".swiftpods/backup/" + backup)) != expected
                {
                    throw Diagnostic(
                        "SP-RECOVER-BACKUP", stage: "recovery", "Recovery backup is missing or changed", file: relative)
                }
            }
        }
        for entry in entries {
            if entry["preserve_external"] as? Bool == true { continue }
            let path = managedURL(entry["path"] as! String)
            // A previous recovery may have stopped after an atomic file restore.
            // Equal original bytes, types and modes are safe to retain on retry.
            if try fingerprint(path) == entry["before_digest"] as? String { continue }
            let backupName = entry["backup"] as? String ?? ""
            guard backupName.isEmpty || backupName.allSatisfy(\.isNumber) else {
                throw Diagnostic("SP-STATE-INVALID", stage: "recovery", "Invalid backup name")
            }
            if entry["existed"] as? Bool == true {
                let temporary = path.deletingLastPathComponent().appendingPathComponent(
                    ".swiftpods-restore-" + UUID().uuidString)
                let source = directory.appendingPathComponent(".swiftpods/backup/" + backupName)
                if let expected = entry["before_digest"] as? String, try fingerprint(source) != expected {
                    throw Diagnostic(
                        "SP-RECOVER-BACKUP", stage: "recovery", "Recovery backup is missing or changed",
                        file: source.path)
                }
                try FileManager.default.copyItem(at: source, to: temporary)
                if exists(path) {
                    guard renamex_np(temporary.path, path.path, UInt32(RENAME_SWAP)) == 0 else {
                        try? FileManager.default.removeItem(at: temporary)
                        throw Diagnostic(
                            "SP-RECOVER-WRITE", stage: "recovery", "Cannot atomically exchange the restored file",
                            file: path.path)
                    }
                    try FileManager.default.removeItem(at: temporary)
                } else {
                    guard rename(temporary.path, path.path) == 0 else {
                        try? FileManager.default.removeItem(at: temporary)
                        throw Diagnostic(
                            "SP-RECOVER-WRITE", stage: "recovery", "Cannot publish the restored file", file: path.path)
                    }
                }
            } else if exists(path) {
                try FileManager.default.removeItem(at: path)
            }
        }
        state["status"] = "recovered"
        state["recovered_at"] = ISO8601DateFormatter().string(from: Date())
        try write(state)
        return [
            "schema_version": 1, "status": "recovered",
            "restored_paths": entries.filter { $0["preserve_external"] as? Bool != true }.compactMap { $0["path"] },
            "preserved_external_paths": entries.filter { $0["preserve_external"] as? Bool == true }.compactMap {
                $0["path"]
            },
            "scope": state["rollback_scope"] ?? "Managed files only",
        ]
    }

    private func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private func managedPaths() -> [String] {
        var paths = Set(["Podfile.lock", "Pods", ".swiftpods/installation.json", ".swiftpods/spm.json"])
        if includePodfile { paths.insert("Podfile") }
        if let enumerator = FileManager.default.enumerator(atPath: directory.path) {
            while let relative = enumerator.nextObject() as? String {
                let url = managedURL(relative)
                let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
                if url.lastPathComponent.hasPrefix(".")
                    || ["Pods", "node_modules", "DerivedData"].contains(url.lastPathComponent)
                    || type == .typeSymbolicLink
                {
                    enumerator.skipDescendants()
                    continue
                }
                if url.pathExtension == "xcodeproj" {
                    paths.insert(relative + "/project.pbxproj")
                    enumerator.skipDescendants()
                } else if url.pathExtension == "xcworkspace" {
                    paths.insert(relative + "/contents.xcworkspacedata")
                    enumerator.skipDescendants()
                }
            }
        }
        return paths.sorted()
    }

    private func fingerprint(_ root: URL) throws -> String { try FileFingerprint.tree(root) }

    private func legacyFingerprint(_ root: URL) throws -> String {
        guard exists(root) else { return "absent" }
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            return "link:" + (try FileManager.default.destinationOfSymbolicLink(atPath: root.path))
        }
        if attributes[.type] as? FileAttributeType != .typeDirectory { return digest(try Data(contentsOf: root)) }
        var records: [String] = []
        if let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        {
            while let url = enumerator.nextObject() as? URL {
                let name = String(url.path.dropFirst(root.path.count + 1))
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    records.append(name + "=" + (try legacyFingerprint(url)))
                } else if values.isDirectory == true {
                    records.append(name + "/")
                } else {
                    records.append(name + "=" + (try legacyFingerprint(url)))
                }
            }
        }
        return digest(Data(records.sorted().joined(separator: "\n").utf8))
    }

    public func graph(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> [String: Any] {
        var report = try readObject(directory.appendingPathComponent(".swiftpods/installation.json"))
        if let packages = try? readObject(directory.appendingPathComponent(".swiftpods/spm.json")) {
            report["swiftpm"] = packages
        }
        var stale = false
        let manifest =
            (report["input_manifest"] as? String).map { URL(fileURLWithPath: $0) }
            ?? directory.appendingPathComponent("Podfile")
        for (file, key) in [
            (manifest, "podfile_digest"), (directory.appendingPathComponent("Podfile.lock"), "lock_digest"),
        ] {
            if let data = try? Data(contentsOf: file) {
                stale = stale || digest(data) != report[key] as? String
            } else {
                stale = true
            }
        }
        var changed: [String] = []
        let inputs = report["inputs"] as? [String: Any] ?? [:]
        for (file, expected) in inputs["files"] as? [String: String] ?? [:] {
            if (try? Data(contentsOf: URL(fileURLWithPath: file))).map(digest) != expected {
                changed.append(file)
                stale = true
            }
        }
        for (name, record) in inputs["environment"] as? [String: [String: Any]] ?? [:]
        where record["status"] as? String == "tracked" {
            let value = environment[name].map { "value:" + $0 } ?? "absent"
            if digest(Data(value.utf8)) != record["sha256"] as? String {
                changed.append("ENV[" + name + "]")
                stale = true
            }
        }
        report["freshness"] = stale ? "stale" : "tracked_inputs_match"
        report["changed_inputs"] = changed.sorted()
        report["freshness_scope"] =
            inputs["coverage"] ?? "Legacy report: Podfile and Podfile.lock only; reinstall to capture helpers and ENV"
        return report
    }
}
