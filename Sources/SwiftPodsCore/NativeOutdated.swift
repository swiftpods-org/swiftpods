import Foundation

/// A manifest can prevent an upgrade without making the installed version current.
enum NativeOutdated {
    static func pods(
        lock: NativeLock, resolution: NativeResolution, catalog: NativeSources, ignorePrerelease: Bool
    ) throws -> [[String: String]] {
        var result: [[String: String]] = []
        let names = Set(lock.versions.keys).union(resolution.specs.keys).sorted()
        for name in names where lock.externalSources[name] == nil {
            if let spec = resolution.specs[name], spec.repository.isEmpty { continue }
            let request = try resolution.requests.first { $0.root == name } ?? NativeDependency(["name": name])
            let versions = try catalog.candidates(request).map(\.version).filter {
                !ignorePrerelease || !$0.isPrerelease
            }
            guard let latest = versions.sorted(by: { $0.isPreferred(to: $1) }).first else { continue }
            if let installed = lock.versions[name], try latest <= PodVersion(installed) { continue }
            result.append([
                "name": name, "installed": lock.versions[name] ?? "absent",
                "available": resolution.specs[name]?.version.description ?? "(unused)",
                "latest": latest.description,
            ])
        }
        return result
    }
}
