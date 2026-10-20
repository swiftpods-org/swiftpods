import Foundation

struct ExternalRuby {
    let executable: URL
    let metadata: [String: String]

    static func cleanEnvironment(_ original: [String: String]) -> [String: String] {
        original.filter {
            !$0.key.hasPrefix("BUNDLE_") && !$0.key.hasPrefix("BUNDLER_") && !$0.key.hasPrefix("GEM_")
                && !["RUBYOPT", "RUBYLIB", "RUBYPATH", "RUBYHOME", "RUBYGEMS_GEMDEPS"].contains($0.key)
        }
    }

    static func normalizedArchitecture(_ architecture: String) -> String {
        switch architecture {
        case "aarch64", "arm64e": return "arm64"
        case "amd64", "x64": return "x86_64"
        default: return architecture
        }
    }

    static func locate(manifest: [String: Any], environment: [String: String], bundleRoot: URL) throws -> ExternalRuby {
        let requirements = try Requirements(manifest: manifest)
        let candidates: [String]
        let explicit = environment["SWIFTPODS_RUBY"]
        if let explicit {
            guard explicit.hasPrefix("/") else {
                throw Diagnostic("SP-RUBY-PATH", stage: "runtime", "SWIFTPODS_RUBY must be an absolute executable path")
            }
            candidates = [explicit]
        } else {
            let searchPaths = (environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }
            let pathCandidates = searchPaths.map {
                String($0) + "/ruby"
            }
            candidates =
                pathCandidates + [
                    "/usr/bin/ruby", "/opt/homebrew/opt/ruby/bin/ruby", "/usr/local/opt/ruby/bin/ruby",
                    "/opt/homebrew/opt/ruby@3.4/bin/ruby", "/usr/local/opt/ruby@3.4/bin/ruby",
                ]
        }
        var visited = Set<String>()
        var firstFailure: Diagnostic?
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let executable = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard visited.insert(executable.path).inserted else { continue }
            guard !NativePath.isDescendant(executable, of: bundleRoot.resolvingSymlinksInPath()) else {
                throw Diagnostic(
                    "SP-RUBY-PATH", stage: "runtime",
                    "Ruby must be installed separately from the SwiftPods distribution")
            }
            do {
                return try inspect(
                    executable, requirements: requirements, manifest: manifest,
                    environment: environment, bundleRoot: bundleRoot)
            } catch let error as Diagnostic {
                if explicit != nil { throw error }
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
        throw Diagnostic(
            "SP-RUBY-MISSING", stage: "runtime",
            "Install Ruby \(requirements.minimum) or newer, or set SWIFTPODS_RUBY to a compatible Ruby executable")
    }

    private static func inspect(
        _ executable: URL, requirements: Requirements, manifest: [String: Any],
        environment: [String: String], bundleRoot: URL
    ) throws -> ExternalRuby {
        let probe =
            "require 'json'; require 'rbconfig'; puts({engine: RUBY_ENGINE, version: RUBY_VERSION, abi: RbConfig::CONFIG.fetch('ruby_version'), architecture: RbConfig::CONFIG.fetch('host_cpu'), platform: RUBY_PLATFORM, library: (RbConfig::CONFIG['ENABLE_SHARED'] == 'yes' ? File.join(RbConfig::CONFIG.fetch('libdir'), RbConfig::CONFIG.fetch('LIBRUBY_SO')) : '')}.to_json)"
        let result: ToolOutput
        do {
            result = try ToolProcess.run(
                executable.path, ["-e", probe], directory: bundleRoot,
                environment: cleanEnvironment(environment))
        } catch {
            throw Diagnostic("SP-RUBY-SPAWN", stage: "runtime", "Cannot launch external Ruby", file: executable.path)
        }
        guard result.status == 0,
            var metadata = (try? JSONSerialization.jsonObject(with: result.output)) as? [String: String]
        else {
            throw Diagnostic(
                "SP-RUBY-PROBE", stage: "runtime", "External Ruby failed its compatibility probe", file: executable.path
            )
        }
        guard requirements.accepts(metadata) else {
            throw Diagnostic(
                "SP-RUBY-VERSION", stage: "runtime",
                "Requires \(requirements.description); selected \(metadata["engine"] ?? "unknown") \(metadata["version"] ?? "unknown"). Set SWIFTPODS_RUBY explicitly to select another installation",
                file: executable.path)
        }
        let architecture = normalizedArchitecture(metadata["architecture"] ?? "")
        guard architecture == (manifest["build_host"] as? [String: String])?["architecture"] else {
            throw Diagnostic(
                "SP-RUBY-ARCH", stage: "runtime", "Ruby architecture must match the SwiftPods distribution",
                file: executable.path)
        }
        for library in manifest["native_ruby_libraries"] as? [String] ?? [] {
            guard let selected = metadata["library"], !selected.isEmpty,
                URL(fileURLWithPath: selected).resolvingSymlinksInPath()
                    == URL(fileURLWithPath: library).resolvingSymlinksInPath()
            else {
                throw Diagnostic(
                    "SP-RUBY-LINKAGE", stage: "runtime",
                    "Native gems require the external Ruby library at \(library). Select its Ruby installation or rebuild the core/gems bundle for your interpreter",
                    file: executable.path)
            }
        }
        metadata["architecture"] = architecture
        metadata["path"] = executable.path
        return ExternalRuby(executable: executable, metadata: metadata)
    }

    private struct Requirements {
        let minimum: String
        let maximum: String?
        let abi: String?

        init(manifest: [String: Any]) throws {
            guard let policy = manifest["runtime"] as? [String: Any], policy["mode"] as? String == "external",
                let minimum = policy["minimum_version"] as? String,
                policy["maximum_version_exclusive"] == nil || policy["maximum_version_exclusive"] is String,
                policy["abi"] == nil || policy["abi"] is String
            else {
                throw Diagnostic(
                    "SP-RUNTIME-PROFILE", stage: "runtime", "An external Ruby compatibility policy is required")
            }
            self.minimum = minimum
            maximum = policy["maximum_version_exclusive"] as? String
            abi = policy["abi"] as? String
        }

        var description: String {
            var value = "CRuby >= " + minimum
            if let maximum { value += ", < " + maximum }
            if let abi { value += ", ABI " + abi }
            return value
        }

        func accepts(_ metadata: [String: String]) -> Bool {
            guard metadata["engine"] == "ruby", let version = metadata["version"],
                version.range(of: #"\A[0-9]+\.[0-9]+\.[0-9]+\z"#, options: .regularExpression) != nil,
                version.compare(minimum, options: .numeric) != .orderedAscending
            else { return false }
            if let maximum, version.compare(maximum, options: .numeric) != .orderedAscending { return false }
            if let abi, metadata["abi"] != abi { return false }
            return true
        }
    }
}
