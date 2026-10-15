import Foundation

struct EnvironmentProfile {
    let root: URL
    let metadata: [String: Any]
    var overrides: [String: String] {
        ["SWIFTPODS_PROFILE_GEMFILE": metadata["input_gemfile"] as! String,
         "BUNDLE_GEMFILE": metadata["input_gemfile"] as! String,
         "BUNDLE_PATH": root.appendingPathComponent("gems").path,
         "BUNDLE_APP_CONFIG": root.appendingPathComponent("config").path,
         "BUNDLE_FROZEN": "true", "BUNDLE_DISABLE_SHARED_GEMS": "true"]
    }
    static func validName(_ name: String) -> Bool { name.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._-]{0,79}\z"#, options: .regularExpression) != nil }
    static func signature(_ bundle: RuntimeBundle, environment: [String: String]) throws -> String {
        let ruby = try ExternalRuby.locate(manifest: bundle.manifest, environment: environment, bundleRoot: bundle.root)
        return digest(try jsonData(["runtime": bundle.manifest["runtime"] ?? [:], "engine": "swift", "ruby": ruby.metadata]))
    }
    static func load(name: String, project: URL, bundle: RuntimeBundle, environment: [String: String]) throws -> EnvironmentProfile {
        guard validName(name) else { throw Diagnostic("SP-ENV-NAME", stage: "environment", "Invalid environment name") }
        let root = project.appendingPathComponent(".swiftpods/environments/" + name).standardizedFileURL
        guard root.resolvingSymlinksInPath().path.hasPrefix(project.resolvingSymlinksInPath().path + "/.swiftpods/") else { throw Diagnostic("SP-ENV-PATH", stage: "environment", "Environment path escapes private state") }
        let metadata = try readObject(root.appendingPathComponent("profile.json"))
        guard metadata["baseline_signature"] as? String == (try signature(bundle, environment: environment)),
              let gemfile = metadata["input_gemfile"] as? String,
              (try? Data(contentsOf: URL(fileURLWithPath: gemfile))).map(digest) == metadata["input_gemfile_digest"] as? String,
              (try? Data(contentsOf: URL(fileURLWithPath: gemfile + ".lock"))).map(digest) == metadata["input_lock_digest"] as? String,
              try FileFingerprint.tree(root.appendingPathComponent("gems"), requireContainedLinks: true) == metadata["gems_digest"] as? String else {
            throw Diagnostic("SP-ENV-INTEGRITY", stage: "environment", "Imported environment changed or uses another Ruby; import it again")
        }
        return EnvironmentProfile(root: root, metadata: metadata)
    }
    static func importProfile(name: String, gemfile: URL, project: URL, bundle: RuntimeBundle, environment: [String: String], local: Bool) throws -> [String: Any] {
        guard validName(name) else { throw Diagnostic("SP-ENV-NAME", stage: "environment", "Invalid environment name") }
        let parent = project.appendingPathComponent(".swiftpods/environments")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let root = parent.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: root.path), root.resolvingSymlinksInPath().path.hasPrefix(project.resolvingSymlinksInPath().path + "/.swiftpods/") else { throw Diagnostic("SP-ENV-EXISTS", stage: "environment", "Environment exists or escapes private state") }
        let input = try Data(contentsOf: gemfile), lock = try Data(contentsOf: URL(fileURLWithPath: gemfile.path + ".lock"))
        let ruby = try ExternalRuby.locate(manifest: bundle.manifest, environment: environment, bundleRoot: bundle.root)
        let code = "require 'bundler'; require 'json'; lock=Bundler::LockfileParser.new(File.read(ARGV.fetch(0))); abort('SP-ENV-ENGINE: imported gems must not depend on an external installation engine') if lock.specs.any? { |s| %w[cocoapods cocoapods-core].include?(s.name) }; puts lock.specs.map { |s| {name:s.name,version:s.version.to_s} }.to_json"
        let inspected = try ToolProcess.run(ruby.executable.path, ["-e", code, gemfile.path + ".lock"], environment: ExternalRuby.cleanEnvironment(environment))
        guard inspected.status == 0, let gems = try JSONSerialization.jsonObject(with: inspected.output) as? [[String: String]] else { throw Diagnostic("SP-ENV-IMPORT", stage: "environment", String(decoding: inspected.error, as: UTF8.self)) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: root) } }
        let profile = EnvironmentProfile(root: root, metadata: ["input_gemfile": gemfile.path])
        let env = ExternalRuby.cleanEnvironment(environment).merging(profile.overrides) { _, new in new }
        let installed = try ToolProcess.run(ruby.executable.path, ["-S", "bundle", "install", "--gemfile", gemfile.path] + (local ? ["--local"] : []), directory: gemfile.deletingLastPathComponent(), environment: env)
        guard installed.status == 0 else { throw Diagnostic("SP-ENV-IMPORT", stage: "environment", String(decoding: installed.error, as: UTF8.self)) }
        guard try Data(contentsOf: gemfile) == input, try Data(contentsOf: URL(fileURLWithPath: gemfile.path + ".lock")) == lock else { throw Diagnostic("SP-ENV-INPUT-CHANGED", stage: "environment", "Input Gemfile or lock changed during import") }
        let metadata: [String: Any] = ["schema_version": 1, "name": name, "engine": "swift", "baseline_signature": try signature(bundle, environment: environment), "input_gemfile": gemfile.path, "input_gemfile_digest": digest(input), "input_lock_digest": digest(lock), "gems": gems, "plugins": gems.filter { $0["name"]?.hasPrefix("cocoapods-") == true }, "gems_digest": try FileFingerprint.tree(root.appendingPathComponent("gems"), requireContainedLinks: true)]
        try jsonData(metadata).write(to: root.appendingPathComponent("profile.json"), options: .atomic)
        published = true
        return ["schema_version": 1, "status": "imported", "profile": name, "gems": gems]
    }
}
