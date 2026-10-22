import Foundation

extension NativeXcode {
    /// Xcode selects a different source list for each architecture and destination.
    /// Emit conditional flags only when that changes a declared runtime dependency.
    func configuredLinkerFlags(
        _ configuration: [String: Any], target: String, graph: NativePBX, platform: String,
        settings: inout [String: Any],
        flags: ([String: Any], NativeBuildSettingScope, Bool?) throws -> [String]
    ) throws -> [String] {
        let name = graph.objects[target]?["name"] as? String
        func evaluate(_ overrides: [String: String] = [:]) throws -> (
            flags: [String], scope: NativeBuildSettingScope, values: [String: Any]
        ) {
            let scope = try NativeBuildSettings.resolvedScopes(
                configuration, graph: graph, targetName: name, sdkContext: linkerSDKContext, buildOverrides: overrides
            ).targetScope
            // Only explicit target flags participate in de-duplication. A base
            // file may still contain dependency flags from the previous install.
            var values = settings
            for key in [
                "LINK_WITH_STANDARD_LIBRARIES", "CLANG_CXX_LIBRARY", "LD", "LDPLUSPLUS", "GCC_INPUT_FILETYPE",
                "EXCLUDED_SOURCE_FILE_NAMES", "INCLUDED_SOURCE_FILE_NAMES", "SDKROOT", "IS_MACCATALYST",
                "EFFECTIVE_PLATFORM_NAME", "CURRENT_ARCH",
            ] {
                values[key] = try scope.expandedValue(key)
            }
            return (try flags(values, scope, nil), scope, values)
        }
        let base = try evaluate()
        // Most targets have no declared C++ runtime dependency at all.
        let explicit = try flags(base.values, base.scope, false)
        guard explicit.contains("-lc++") || explicit.contains("-lstdc++") else { return base.flags }

        let sdks = [
            "osx": ["macosx"], "ios": ["iphoneos", "iphonesimulator"],
            "tvos": ["appletvos", "appletvsimulator"], "watchos": ["watchos", "watchsimulator"],
            "visionos": ["xros", "xrsimulator"],
        ][platform] ?? []
        let catalyst = platform == "ios"
        let currentSDK = try base.scope.expandedValue("SDKROOT") ?? sdks.first ?? "macosx"
        let currentName = linkerSDKContext.name(currentSDK, relativeTo: graph.sourceRoot)
        var rows: [(catalyst: Bool, sdk: String, arch: String, flags: [String])] = []
        for (alias, isCatalyst) in sdks.map({ ($0, false) }) + (catalyst ? [("macosx", true)] : []) {
            let sdk = currentName.hasPrefix(alias) ? currentSDK : alias
            let sdkTarget = isCatalyst ? "iosmac" : alias
            for arch in linkerSDKContext.architectures(sdk, target: sdkTarget, relativeTo: graph.sourceRoot) {
                let evaluated = try evaluate([
                    "SDKROOT": sdk, "PLATFORM_NAME": alias, "CURRENT_ARCH": arch,
                    "IS_MACCATALYST": isCatalyst ? "YES" : "NO",
                    "EFFECTIVE_PLATFORM_NAME": isCatalyst ? "-maccatalyst" : alias == "macosx" ? "" : "-" + alias,
                ])
                rows.append((isCatalyst, alias, arch, evaluated.flags))
            }
        }
        guard rows.contains(where: { $0.flags != base.flags }) else { return base.flags }
        let variable = "SWIFTPODS_LINKER_FLAGS"
        if catalyst {
            settings[variable] = "$(" + variable + "_$(IS_MACCATALYST:default=NO))"
            settings[variable + "_NO"] = base.flags
            settings[variable + "_YES"] = base.flags
        } else {
            settings[variable] = base.flags
        }
        for row in rows where row.flags != base.flags {
            let key = variable + (catalyst ? (row.catalyst ? "_YES" : "_NO") : "")
                + "[sdk=" + row.sdk + "*][arch=" + row.arch + "]"
            settings[key] = row.flags
        }
        return ["$(" + variable + ")"]
    }
}
