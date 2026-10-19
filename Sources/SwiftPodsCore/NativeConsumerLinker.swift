import Foundation

extension NativeXcode {
    func linkerSources(_ target: String, graph: NativePBX) -> [URL] {
        (graph.objects[target]?["buildPhases"] as? [String] ?? []).filter {
            graph.objects[$0]?["isa"] as? String == "PBXSourcesBuildPhase"
        }.flatMap { graph.objects[$0]?["files"] as? [String] ?? [] }.compactMap { build in
            guard let reference = graph.objects[build]?["fileRef"] as? String,
                let path = graph.objects[reference]?["path"] as? String
            else { return nil }
            return URL(fileURLWithPath: NativeBuildSetting.decodedLiteral(path))
        }
    }

    /// A static archive cannot resolve its system libraries or load categories
    /// until an executable, bundle or dynamic framework links it.
    func consumerLinkerFlags(
        _ roots: Set<String>, platform: String, sources: [URL], settings: [String: Any]
    ) throws -> [String] {
        var libraries = Set<String>()
        var frameworks = Set<String>()
        var weakFrameworks = Set<String>()
        var objc = false
        for root in roots.sorted() {
            guard let spec = resolution.specs[root], let variant = variantPlan?.variants[variantKey(root, platform)]
            else { continue }
            let sdks = vendorSDKs[variant.key] ?? []
            objc = objc || variant.mode != "dynamic" || sdks.contains { !$0.dynamic }
            guard variant.mode != "dynamic" else { continue }
            let attributes = try NativeVariantPlan.attributes(spec, names: variant.names, platform: platform)
            libraries.formUnion(nativeStrings(attributes["libraries"]))
            frameworks.formUnion(nativeStrings(attributes["frameworks"]))
            weakFrameworks.formUnion(nativeStrings(attributes["weak_frameworks"]))
        }
        let existing = Set(
            nativeStrings(settings["OTHER_LDFLAGS"]).joined(separator: " ").split(whereSeparator: \.isWhitespace).map(
                String.init))
        var flags = objc && !existing.contains("-ObjC") ? ["-ObjC"] : []
        flags += NativeBuildSettings.libraryFlags(
            libraries.sorted(), sources: sources, settings: settings, linkingWithClang: true
        ).filter { !existing.contains($0) }
        flags += frameworks.sorted().flatMap { ["-framework", NativeBuildSetting.quoted($0)] }
        flags += weakFrameworks.subtracting(frameworks).sorted().flatMap {
            ["-weak_framework", NativeBuildSetting.quoted($0)]
        }
        return flags
    }
}
