import Foundation

extension NativeXcode {
    func hasConsumerDynamicProducts(_ roots: Set<String>, platform: String) -> Bool {
        products.contains { matchesProduct($0, roots: roots, platform: platform) && isDynamicProduct($0) }
            || roots.contains { (vendorSDKs[variantKey($0, platform)] ?? []).contains { $0.dynamic } }
    }

    func isDynamicLibrary(_ root: String, platform: String) -> Bool {
        let key = variantKey(root, platform)
        return libraryTargets[key]
            .flatMap { graph.objects[$0]?["productReference"] as? String }
            .map(isDynamicProduct) ?? (variantPlan?.variants[key]?.mode == "dynamic")
    }

    /// Static SDKs already linked into a dynamic dependency must not be linked again.
    func consumerVendorSDKs(_ roots: Set<String>, platform: String) throws -> [NativeVendorSDK] {
        var absorbed = Set<URL>()
        for root in roots.sorted() where isDynamicLibrary(root, platform: platform) {
            guard let variant = variantPlan?.variants[variantKey(root, platform)] else { continue }
            let dependencies = try dependencyRoots(variant.actualRequests).union([root])
            for dependency in dependencies {
                for sdk in vendorSDKs[variantKey(dependency, platform)] ?? [] where !sdk.dynamic {
                    absorbed.insert(sdk.url)
                }
            }
        }
        var seen = Set<URL>()
        return roots.sorted().flatMap { vendorSDKs[variantKey($0, platform)] ?? [] }.filter {
            !absorbed.contains($0.url) && seen.insert($0.url).inserted
        }
    }

    func consumerProductLinkerFlags(_ roots: Set<String>, platform: String) throws -> [String] {
        var flags: [String] = []
        for product in products
        where productRoots[product] != nil && matchesProduct(product, roots: roots, platform: platform) {
            let path = consumerProductPath(product)
            if path.relative.hasSuffix(".framework") {
                if productVariants[product].flatMap({ variantPlan?.variants[$0]?.scoped }) == true {
                    // A framework name alone is ambiguous when several variants share its module name.
                    let binary = URL(fileURLWithPath: path.relative).deletingPathExtension().lastPathComponent
                    flags.append(NativeBuildSetting.quoted(path.setting + "/" + binary))
                    continue
                }
                flags += [
                    "-framework",
                    NativeBuildSetting.quoted(
                        URL(fileURLWithPath: path.relative).deletingPathExtension().lastPathComponent),
                ]
            } else {
                flags.append(NativeBuildSetting.quoted(path.setting))
            }
        }
        for sdk in try consumerVendorSDKs(roots, platform: platform) {
            if sdk.isFramework {
                flags += ["-framework", NativeBuildSetting.quoted(String(sdk.productName.dropLast(10)))]
            } else {
                flags.append(NativeBuildSetting.quoted(consumerSDKPath(sdk).setting))
            }
        }
        return flags
    }

    func linkerHasCXXSources(
        _ target: String, graph: NativePBX, settings: [String: Any] = [:], scope: NativeBuildSettingScope? = nil
    ) -> Bool {
        let builds = (graph.objects[target]?["buildPhases"] as? [String] ?? []).filter {
            graph.objects[$0]?["isa"] as? String == "PBXSourcesBuildPhase"
        }.flatMap { graph.objects[$0]?["files"] as? [String] ?? [] }
        return builds.contains { build in
            let filters = nativeStrings(graph.objects[build]?["platformFilters"])
                + nativeStrings(graph.objects[build]?["platformFilter"])
            if !filters.isEmpty {
                let sdk = settings["SDKROOT"] as? String ?? "macosx"
                let platform: String
                if settings["IS_MACCATALYST"] as? String == "YES"
                    || settings["EFFECTIVE_PLATFORM_NAME"] as? String == "-maccatalyst"
                {
                    platform = "maccatalyst"
                } else {
                    let name = linkerSDKContext.name(sdk, relativeTo: graph.sourceRoot)
                    platform =
                        name.hasPrefix("iphone") ? "ios" : name.hasPrefix("macosx") ? "macos"
                        : name.hasPrefix("appletv") ? "tvos" : name.hasPrefix("watch") ? "watchos"
                        : name.hasPrefix("xr") ? "xros" : name
                }
                guard filters.contains(platform) else { return false }
            }
            guard let reference = graph.objects[build]?["fileRef"] as? String,
                let source = graph.objects[reference], let path = source["path"] as? String
            else { return false }
            guard NativeBuildSettings.isCXXSource(
                URL(fileURLWithPath: NativeBuildSetting.decodedLiteral(path)),
                fileType: source["explicitFileType"] as? String ?? source["lastKnownFileType"] as? String,
                inputFileType: settings["GCC_INPUT_FILETYPE"] as? String)
            else { return false }
            let resolved =
                (try? NativeBuildSettings.file(
                    reference, graph: graph, configuration: settings["CONFIGURATION"] as? String ?? "",
                    targetName: graph.objects[target]?["name"] as? String,
                    scope: scope ?? NativeBuildSettingScope(settings)))
                ?? graph.sourceRoot.appendingPathComponent(NativeBuildSetting.decodedLiteral(path))
            return !NativeBuildSettings.sourceIsExcluded(resolved, relativeTo: graph.sourceRoot, settings: settings)
        }
    }

    /// A static archive cannot resolve its system libraries or load categories
    /// until an executable, bundle or dynamic framework links it.
    func consumerLinkerFlags(
        _ roots: Set<String>, platform: String, sources: [URL], settings: [String: Any], hasCXXSources: Bool? = nil
    ) throws -> [String] {
        var libraries = Set<String>()
        var frameworks = Set<String>()
        var weakFrameworks = Set<String>()
        var objc = false
        for root in roots.sorted() {
            guard let spec = resolution.specs[root], let variant = variantPlan?.variants[variantKey(root, platform)]
            else { continue }
            let sdks = vendorSDKs[variant.key] ?? []
            // Binary-only pods produce an archive even when use_frameworks!
            // requests dynamic linkage. Follow the generated product's type.
            let dynamic = isDynamicLibrary(root, platform: platform)
            objc = objc || !dynamic || sdks.contains { !$0.dynamic }
            guard !dynamic else { continue }
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
            libraries.sorted(), sources: sources, settings: settings, linkingWithClang: true,
            hasCXXSources: hasCXXSources
        ).filter { !existing.contains($0) }
        flags += frameworks.sorted().flatMap { ["-framework", NativeBuildSetting.quoted($0)] }
        flags += weakFrameworks.subtracting(frameworks).sorted().flatMap {
            ["-weak_framework", NativeBuildSetting.quoted($0)]
        }
        return flags
    }
}
