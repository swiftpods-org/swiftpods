import Foundation

extension NativeSources {
    func install(_ input: NativeSpec) throws -> NativeSpec {
        var spec = input
        if spec.local {
            try prepare(spec)
            return spec
        }
        let destination = project.appendingPathComponent("Pods/" + spec.name)
        let receipt = project.appendingPathComponent("Pods/Target Support Files/" + spec.name + "/source-state.json")
        if installationOptions["incremental_installation"] as? Bool == true, !cleanInstall, !shouldUpdate(spec.name),
            let previous = try? readObject(receipt), previous["identity"] as? String == (try sourceIdentity(spec)),
            previous["fingerprint"] as? String == (try FileFingerprint.tree(destination, requireContainedLinks: true))
        {
            spec.directory = destination
            spec.checkout = previous["checkout"] as? [String: String] ?? [:]
            return spec
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        if let directory = spec.directory {
            try FileManager.default.copyItem(at: directory, to: destination)
            let external = sourceOptions(spec.name)
            let source = external.isEmpty ? (spec.data["source"] as? [String: Any] ?? [:]) : external
            spec.checkout = try sourceCheckoutIdentity(spec.name, source: source, directory: directory)
        } else {
            let source = spec.data["source"] as? [String: Any] ?? [:]
            if let git = source["git"] as? String {
                let directory =
                    try prefetchedSources[spec.name]
                    ?? checkout(
                        git, selector: pinnedSelector(spec.name, source: source), fresh: shouldUpdate(spec.name),
                        submodules: source["submodules"] as? Bool == true)
                try FileManager.default.copyItem(at: directory, to: destination)
                spec.checkout = try checkoutIdentity(spec.name, source: source, directory: directory)
            } else if let http = source["http"] as? String {
                let archive =
                    try prefetchedSources[spec.name]
                    ?? download(http, pod: spec.name, headers: source["headers"] as? [String: String] ?? [:])
                try NativeArchive.extract(archive, source: source, destination: destination, pod: spec.name)
            } else if source["svn"] != nil || source["hg"] != nil {
                let directory = try sourceSnapshot(source, pod: spec.name)
                try FileManager.default.copyItem(at: directory, to: destination)
                spec.checkout = try sourceCheckoutIdentity(spec.name, source: source, directory: directory)
            } else {
                throw Diagnostic(
                    "SP-SOURCE-UNSUPPORTED", stage: "download",
                    "\(spec.name) requires a supported :git, :http, :svn or :hg source")
            }
        }
        spec.directory = destination
        try prepareCached(spec)
        return spec
    }
    func prepare(_ spec: NativeSpec) throws {
        if let script = spec.data["prepare_command"] as? String, !script.isEmpty {
            guard !hardened else {
                throw Diagnostic("SP-HARDENED-SCRIPT", stage: "policy", "prepare_command is forbidden", file: spec.name)
            }
            try command("/bin/sh", ["-c", script], directory: spec.directory)
        }
    }
}
