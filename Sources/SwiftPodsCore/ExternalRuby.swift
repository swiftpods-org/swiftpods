import Foundation

struct ExternalRuby {
    let executable: URL
    let metadata: [String: String]

    static func cleanEnvironment(_ original: [String: String]) -> [String: String] {
        original.filter { !$0.key.hasPrefix("BUNDLE_") && !$0.key.hasPrefix("GEM_") &&
            !["RUBYOPT", "RUBYLIB", "RUBYPATH", "RUBYHOME", "RUBYGEMS_GEMDEPS"].contains($0.key) }
    }

    static func locate(manifest: [String: Any], environment: [String: String], bundleRoot: URL) throws -> ExternalRuby {
        guard let policy = manifest["runtime"] as? [String: Any], policy["mode"] as? String == "external",
              let minimum = policy["minimum_version"] as? String,
              let maximum = policy["maximum_version_exclusive"] as? String,
              let abi = policy["abi"] as? String else {
            throw Diagnostic("SP-RUNTIME-PROFILE", stage: "runtime", "An external Ruby compatibility policy is required")
        }
        let candidates: [String]
        if let explicit = environment["SWIFTPODS_RUBY"] {
            guard explicit.hasPrefix("/") else {
                throw Diagnostic("SP-RUBY-PATH", stage: "runtime", "SWIFTPODS_RUBY must be an absolute executable path")
            }
            candidates = [explicit]
        } else {
            candidates = ["/opt/homebrew/opt/ruby@3.4/bin/ruby", "/usr/local/opt/ruby@3.4/bin/ruby"] +
                (environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.map { String($0) + "/ruby" }
        }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw Diagnostic("SP-RUBY-MISSING", stage: "runtime", "Install ruby@3.4 with Homebrew, or set SWIFTPODS_RUBY to a compatible Ruby executable")
        }
        let executable = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard !executable.path.hasPrefix(bundleRoot.resolvingSymlinksInPath().path + "/") else {
            throw Diagnostic("SP-RUBY-PATH", stage: "runtime", "Ruby must be installed separately from the SwiftPods distribution")
        }
        let probe = "require 'json'; require 'rbconfig'; puts({engine: RUBY_ENGINE, version: RUBY_VERSION, abi: RbConfig::CONFIG.fetch('ruby_version'), architecture: RbConfig::CONFIG.fetch('host_cpu'), platform: RUBY_PLATFORM, library: (RbConfig::CONFIG['ENABLE_SHARED'] == 'yes' ? File.join(RbConfig::CONFIG.fetch('libdir'), RbConfig::CONFIG.fetch('LIBRUBY_SO')) : '')}.to_json)"
        let result: ToolOutput
        do { result = try ToolProcess.run(executable.path, ["-e", probe], directory: bundleRoot,
                                         environment: cleanEnvironment(environment)) }
        catch { throw Diagnostic("SP-RUBY-SPAWN", stage: "runtime", "Cannot launch external Ruby", file: executable.path) }
        guard result.status == 0,
              var metadata = (try? JSONSerialization.jsonObject(with: result.output)) as? [String: String] else {
            throw Diagnostic("SP-RUBY-PROBE", stage: "runtime", "External Ruby failed its compatibility probe", file: executable.path)
        }
        guard metadata["engine"] == "ruby", metadata["abi"] == abi,
              let version = metadata["version"], version.range(of: #"\A[0-9]+\.[0-9]+\.[0-9]+\z"#, options: .regularExpression) != nil,
              version.compare(minimum, options: .numeric) != .orderedAscending,
              version.compare(maximum, options: .numeric) == .orderedAscending else {
            throw Diagnostic("SP-RUBY-VERSION", stage: "runtime", "Requires CRuby >= \(minimum), < \(maximum), ABI \(abi); selected \(metadata["engine"] ?? "unknown") \(metadata["version"] ?? "unknown"). Set SWIFTPODS_RUBY explicitly to select another installation", file: executable.path)
        }
        guard metadata["architecture"] == (manifest["build_host"] as? [String: String])?["architecture"] else {
            throw Diagnostic("SP-RUBY-ARCH", stage: "runtime", "Ruby architecture must match the SwiftPods distribution", file: executable.path)
        }
        for library in manifest["native_ruby_libraries"] as? [String] ?? [] {
            guard let selected = metadata["library"], !selected.isEmpty,
                  URL(fileURLWithPath: selected).resolvingSymlinksInPath() == URL(fileURLWithPath: library).resolvingSymlinksInPath() else {
                throw Diagnostic("SP-RUBY-LINKAGE", stage: "runtime", "Native gems require the external Ruby library at \(library). Select its Ruby installation or rebuild the core/gems bundle for your interpreter", file: executable.path)
            }
        }
        metadata["path"] = executable.path
        return ExternalRuby(executable: executable, metadata: metadata)
    }
}
