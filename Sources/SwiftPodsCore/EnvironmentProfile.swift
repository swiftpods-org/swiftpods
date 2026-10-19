import Darwin
import Foundation

struct EnvironmentProfile {
    let root: URL
    let metadata: [String: Any]
    var overrides: [String: String] {
        [
            "SWIFTPODS_PROFILE_GEMFILE": metadata["input_gemfile"] as! String,
            "BUNDLE_GEMFILE": metadata["input_gemfile"] as! String,
            "BUNDLE_PATH": root.appendingPathComponent("gems").path,
            "BUNDLE_APP_CONFIG": root.appendingPathComponent("config").path,
            "BUNDLE_FROZEN": "true", "BUNDLE_DISABLE_SHARED_GEMS": "true",
        ]
    }
    static func validName(_ name: String) -> Bool {
        name.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._-]{0,79}\z"#, options: .regularExpression) != nil
    }
    static func defaultName(gemfile: URL) throws -> String {
        "import-" + String(digest(try importInput(gemfile)).prefix(12))
    }
    static func signature(_ bundle: RuntimeBundle, environment: [String: String]) throws -> String {
        let ruby = try ExternalRuby.locate(manifest: bundle.manifest, environment: environment, bundleRoot: bundle.root)
        return digest(
            try jsonData(["runtime": bundle.manifest["runtime"] ?? [:], "engine": "swift", "ruby": ruby.metadata]))
    }
    static func load(name: String, project: URL, bundle: RuntimeBundle, environment: [String: String]) throws
        -> EnvironmentProfile
    {
        let root = try profileRoot(name: name, project: project)
        let metadata = try readObject(root.appendingPathComponent("profile.json"))
        guard metadata["baseline_signature"] as? String == (try signature(bundle, environment: environment)),
            let gemfile = metadata["input_gemfile"] as? String,
            (try? Data(contentsOf: URL(fileURLWithPath: gemfile))).map(digest) == metadata["input_gemfile_digest"]
                as? String,
            (try? Data(contentsOf: URL(fileURLWithPath: gemfile + ".lock"))).map(digest) == metadata[
                "input_lock_digest"] as? String,
            try FileFingerprint.tree(root.appendingPathComponent("gems"), requireContainedLinks: true) == metadata[
                "gems_digest"] as? String
        else {
            throw Diagnostic(
                "SP-ENV-INTEGRITY", stage: "environment",
                "Imported environment changed or uses another Ruby; import it again")
        }
        return EnvironmentProfile(root: root, metadata: metadata)
    }
    static func importProfile(
        name: String, gemfile: URL, project: URL, bundle: RuntimeBundle, environment: [String: String], local: Bool
    ) throws -> [String: Any] {
        let root = try profileRoot(name: name, project: project)
        let parent = root.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: root.path) else {
            throw Diagnostic("SP-ENV-EXISTS", stage: "environment", "Environment already exists")
        }
        let input = try importInput(gemfile)
        let lock = try importInput(URL(fileURLWithPath: gemfile.path + ".lock"))
        let ruby = try ExternalRuby.locate(manifest: bundle.manifest, environment: environment, bundleRoot: bundle.root)
        let code =
            "require 'bundler'; require 'json'; lock=Bundler::LockfileParser.new(File.read(ARGV.fetch(0))); abort('SP-ENV-ENGINE: imported gems must not depend on an external installation engine') if lock.specs.any? { |s| %w[cocoapods cocoapods-core].include?(s.name) }; puts lock.specs.map { |s| {name:s.name,version:s.version.to_s} }.to_json"
        let inspected = try ToolProcess.run(
            ruby.executable.path, ["-e", code, gemfile.path + ".lock"],
            environment: ExternalRuby.cleanEnvironment(environment))
        guard inspected.status == 0,
            let gems = try JSONSerialization.jsonObject(with: inspected.output) as? [[String: String]]
        else {
            throw Diagnostic("SP-ENV-IMPORT", stage: "environment", String(decoding: inspected.error, as: UTF8.self))
        }
        _ = try profileRoot(name: name, project: project)
        var createdParents: [URL] = []
        var createdRoot = false
        var published = false
        defer {
            if !published {
                if createdRoot { try? FileManager.default.removeItem(at: root) }
                for directory in createdParents.reversed()
                where (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
                    try? FileManager.default.removeItem(at: directory)
                }
            }
        }
        for directory in [parent.deletingLastPathComponent(), parent] {
            if try createDirectory(directory, exclusive: false) { createdParents.append(directory) }
        }
        _ = try createDirectory(root, exclusive: true)
        createdRoot = true
        let profile = EnvironmentProfile(root: root, metadata: ["input_gemfile": gemfile.path])
        let env = ExternalRuby.cleanEnvironment(environment).merging(profile.overrides) { _, new in new }
        let installed = try ToolProcess.run(
            ruby.executable.path, ["-S", "bundle", "install", "--gemfile", gemfile.path] + (local ? ["--local"] : []),
            directory: gemfile.deletingLastPathComponent(), environment: env)
        guard installed.status == 0 else {
            throw Diagnostic("SP-ENV-IMPORT", stage: "environment", String(decoding: installed.error, as: UTF8.self))
        }
        guard try Data(contentsOf: gemfile) == input,
            try Data(contentsOf: URL(fileURLWithPath: gemfile.path + ".lock")) == lock
        else {
            throw Diagnostic(
                "SP-ENV-INPUT-CHANGED", stage: "environment", "Input Gemfile or lock changed during import")
        }
        let metadata: [String: Any] = [
            "schema_version": 1, "name": name, "engine": "swift",
            "baseline_signature": try signature(bundle, environment: environment), "input_gemfile": gemfile.path,
            "input_gemfile_digest": digest(input), "input_lock_digest": digest(lock), "gems": gems,
            "plugins": gems.filter { $0["name"]?.hasPrefix("cocoapods-") == true },
            "gems_digest": try FileFingerprint.tree(root.appendingPathComponent("gems"), requireContainedLinks: true),
        ]
        try jsonData(metadata).write(to: root.appendingPathComponent("profile.json"), options: .atomic)
        published = true
        return ["schema_version": 1, "status": "imported", "profile": name, "gems": gems]
    }

    private static func profileRoot(name: String, project: URL) throws -> URL {
        guard validName(name) else { throw Diagnostic("SP-ENV-NAME", stage: "environment", "Invalid environment name") }
        let state = project.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent(".swiftpods")
        let parent = state.appendingPathComponent("environments")
        let root = parent.appendingPathComponent(name)
        for directory in [state, parent, root] {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path) {
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw Diagnostic(
                        "SP-ENV-PATH", stage: "environment", "Environment state must use directories without symlinks",
                        file: directory.path)
                }
            }
        }
        return root
    }

    private static func importInput(_ path: URL) throws -> Data {
        guard path.isFileURL, !path.path.utf8.contains(0),
            let attributes = try? FileManager.default.attributesOfItem(atPath: path.resolvingSymlinksInPath().path),
            attributes[.type] as? FileAttributeType == .typeRegular
        else {
            throw Diagnostic(
                "SP-ENV-INPUT", stage: "environment", "Expected a readable Gemfile and lock file", file: path.path)
        }
        do {
            return try Data(contentsOf: path)
        } catch {
            throw Diagnostic("SP-ENV-INPUT", stage: "environment", "Cannot read environment input", file: path.path)
        }
    }

    private static func createDirectory(_ path: URL, exclusive: Bool) throws -> Bool {
        if mkdir(path.path, 0o700) == 0 { return true }
        let error = errno
        if error == EEXIST {
            guard !exclusive else {
                throw Diagnostic("SP-ENV-EXISTS", stage: "environment", "Environment already exists", file: path.path)
            }
            guard
                try FileManager.default.attributesOfItem(atPath: path.path)[.type] as? FileAttributeType
                    == .typeDirectory
            else {
                throw Diagnostic(
                    "SP-ENV-PATH", stage: "environment", "Environment state must use directories without symlinks",
                    file: path.path)
            }
            return false
        }
        throw Diagnostic("SP-ENV-WRITE", stage: "environment", String(cString: strerror(error)), file: path.path)
    }
}
