import Foundation
import CryptoKit

public func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

public struct RuntimeBundle {
    public let root: URL
    public let manifest: [String: Any]

    public init(root: URL) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        manifest = try readObject(self.root.appendingPathComponent("compatibility.json"))
        guard manifest["schema_version"] as? Int == 1, manifest["files"] is [String: [String: String]] else {
            throw Diagnostic("SP-RUNTIME-PROFILE", stage: "runtime", "Unsupported or incomplete compatibility manifest")
        }
    }

    public static func locate(environment: [String: String], executable: URL) throws -> RuntimeBundle {
        if let explicit = environment["SWIFTPODS_BUNDLE"] { return try RuntimeBundle(root: URL(fileURLWithPath: explicit)) }
        var directory = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            for candidate in [directory, directory.appendingPathComponent(".runtime")] {
                if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("compatibility.json").path) {
                    return try RuntimeBundle(root: candidate)
                }
            }
            directory.deleteLastPathComponent()
        }
        throw Diagnostic("SP-RUNTIME-MISSING", stage: "runtime", "SwiftPods DSL adapter bundle not found. Run python3 scripts/bootstrap.py in a source checkout, or install SwiftPods with Homebrew.")
    }

    public func verify() throws {
        let signer = try ManifestSignature.launcherCertificate()
        if signer != nil || manifest["status"] as? String == "release" {
            guard let signer, let signature = try? Data(contentsOf: root.appendingPathComponent("compatibility.cms")) else {
                throw Diagnostic("SP-RUNTIME-SIGNATURE", stage: "runtime", "Signed distributions require a CMS manifest signed by the launcher identity")
            }
            try ManifestSignature.verify(signature, content: Data(contentsOf: root.appendingPathComponent("compatibility.json")), certificate: signer)
        }
        let files = manifest["files"] as! [String: [String: String]]
        guard let runtime = manifest["runtime"] as? [String: Any], runtime["mode"] as? String == "external",
              manifest["native_ruby_libraries"] is [String], manifest["minimum_macos"] is String,
              let host = manifest["build_host"] as? [String: String] else {
            throw Diagnostic("SP-RUNTIME-PROFILE", stage: "runtime", "Missing runtime or architecture metadata")
        }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        guard host["architecture"] == architecture else {
            throw Diagnostic("SP-RUNTIME-ARCH", stage: "runtime", "Bundle architecture does not match this launcher")
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let currentOS = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        if let minimum = manifest["minimum_macos"] as? String,
           currentOS.compare(minimum, options: .numeric) == .orderedAscending {
            throw Diagnostic("SP-RUNTIME-OS", stage: "runtime", "Distribution requires macOS \(minimum) or newer; current host is \(currentOS)")
        }
        guard !files.keys.contains(where: { $0.hasPrefix("runtime/") }) else {
            throw Diagnostic("SP-RUNTIME-PROFILE", stage: "runtime", "SwiftPods distributions must not include a Ruby runtime")
        }
        guard manifest["engine"] as? String == "swift", !files.keys.contains(where: { $0.hasPrefix("vendor/") || $0.hasPrefix("gems/") || $0 == "host/host.rb" }) else {
            throw Diagnostic("SP-RUNTIME-ENGINE", stage: "runtime", "This launcher requires the native Swift engine distribution")
        }
        for required in ["host/dsl.rb"] {
            guard files[required] != nil else { throw Diagnostic("SP-RUNTIME-PROFILE", stage: "runtime", "Manifest omits required file: \(required)") }
        }
        for (relative, record) in files {
            let path = root.appendingPathComponent(relative).standardizedFileURL
            guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains(".."),
                  path.path.hasPrefix(root.path + "/"),
                  path.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
                throw Diagnostic("SP-RUNTIME-INTEGRITY", stage: "runtime", "Bundle path escapes its root", file: relative)
            }
            if let link = record["symlink"] {
                guard (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) == link else {
                    throw Diagnostic("SP-RUNTIME-INTEGRITY", stage: "runtime", "Bundle symlink changed", file: relative)
                }
            } else {
                guard let expected = record["sha256"], let data = try? Data(contentsOf: path), digest(data) == expected else {
                    throw Diagnostic("SP-RUNTIME-INTEGRITY", stage: "runtime", "Bundle file is missing or changed", file: relative)
                }
            }
        }
        if let enumerator = FileManager.default.enumerator(atPath: root.path) {
            while let relative = enumerator.nextObject() as? String {
                let path = root.appendingPathComponent(relative)
                let type = try FileManager.default.attributesOfItem(atPath: path.path)[.type] as? FileAttributeType
                if type == .typeSymbolicLink { enumerator.skipDescendants() }
                if type != .typeDirectory {
                    guard ["compatibility.json", "compatibility.cms"].contains(relative) || files[relative] != nil else {
                        throw Diagnostic("SP-RUNTIME-INTEGRITY", stage: "runtime", "Bundle contains an unlisted file", file: relative)
                    }
                }
            }
        }
    }

    public func environment(from original: [String: String]) -> [String: String] {
        var env = ExternalRuby.cleanEnvironment(original)
        env["SWIFTPODS_BUNDLE"] = root.path
        env["SWIFTPODS_EXECUTABLE"] = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().path
        env["SWIFTPODS_CACHE_ROOT"] = original["SWIFTPODS_CACHE_ROOT"] ?? original["CP_CACHE_DIR"] ?? URL(fileURLWithPath: original["HOME"] ?? NSHomeDirectory())
            .appendingPathComponent("Library/Caches/SwiftPods/" + (manifest["id"] as? String ?? "baseline")).path
        env["PATH"] = original["PATH"] ?? "/usr/bin:/bin"
        return env
    }
}
