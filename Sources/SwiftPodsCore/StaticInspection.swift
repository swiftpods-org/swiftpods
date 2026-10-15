import Foundation

public struct StaticInspection {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func report(bundle: RuntimeBundle?) -> [String: Any] {
        let manager = FileManager.default
        let podfile = directory.appendingPathComponent("Podfile")
        var checks: [[String: Any]] = []
        func check(_ name: String, _ status: String, _ message: String) {
            checks.append(["name": name, "status": status, "message": message])
        }
        check("podfile", manager.fileExists(atPath: podfile.path) ? "passed" : "failed", podfile.path)
        check("ruby_evaluation", "unknown", "Static inspection never executes Podfile, podspec, Gemfile or plugins")
        for name in ["Gemfile", "Gemfile.lock", ".ruby-version"]
        where manager.fileExists(atPath: directory.appendingPathComponent(name).path) {
            check(
                "project_environment", "unknown",
                "\(name) exists; the managed environment will be used. Explicit environment import is required for additional gems."
            )
        }
        let lock = directory.appendingPathComponent("Podfile.lock")
        let installed = directory.appendingPathComponent("Pods/Manifest.lock")
        if let locked = try? Data(contentsOf: lock) {
            check("podfile_lock", "passed", "Lock exists; selected dependencies are owned by Podfile.lock")
            if let manifest = try? Data(contentsOf: installed) {
                check(
                    "installed_lock", locked == manifest ? "passed" : "failed",
                    locked == manifest
                        ? "Manifest.lock matches Podfile.lock" : "Manifest.lock differs from Podfile.lock")
            } else {
                check("installed_lock", "unknown", "Pods/Manifest.lock is missing")
            }
        } else {
            check("podfile_lock", "unknown", "No existing Podfile.lock")
        }
        if let bundle {
            do {
                try bundle.verify()
                check(
                    "managed_runtime", "passed",
                    "Native engine adapter verified; external Ruby requires a separate runtime verify")
            } catch { check("managed_runtime", "failed", String(describing: error)) }
        } else {
            check("managed_runtime", "failed", "Managed runtime bundle is missing")
        }
        for name in ["resolver", "hooks", "plugins", "xcode_build", "resources", "binary_slices", "duplicate_sdks"] {
            check(name, "unknown", "Requires execution and/or build validation")
        }
        return [
            "schema_version": 1, "mode": "static", "project": directory.path,
            "checks": checks, "status": checks.contains { $0["status"] as? String == "failed" } ? "failed" : "unknown",
        ]
    }
}
