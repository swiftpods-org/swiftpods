import CryptoKit
import Foundation

/// Observable scope names from the compatibility profile, implemented in Swift.
enum NativeVariantLabels {
    static func labels(_ variants: [NativePodVariant], spec: NativeSpec, deduplicate: Bool) throws -> [String: String] {
        if variants.count == 1 { return [variants[0].key: spec.name] }
        let defaults = nativeStrings(spec.data["default_subspecs"] ?? spec.data["default_subspec"])
        let children = spec.data["subspecs"] as? [[String: Any]] ?? []
        let defaultSpecs = Set(
            [spec.name]
                + (defaults.isEmpty
                    ? children.compactMap { ($0["name"] as? String).map { spec.name + "/" + $0 } }
                    : defaults.filter { $0 != "none" }.map { spec.name + "/" + $0 }))
        let selections = Dictionary(grouping: variants, by: { $0.names.joined(separator: "\n") }).values.map {
            Set($0[0].names)
        }
        let common = selections.dropFirst().reduce(selections.first ?? []) { $0.intersection($1) }
        let omitCommon = !common.isEmpty && common.isStrictSuperset(of: defaultSpecs)
        func specSuffix(_ variant: NativePodVariant) -> String {
            var names = Set(variant.names)
            let omitDefault = !defaultSpecs.isEmpty && defaultSpecs.isSubset(of: names)
            if omitDefault { names.subtract(defaultSpecs) }
            if omitCommon { names.subtract(common) }
            var suffixes = names.map {
                $0 == spec.name
                    ? ".root"
                    : (NativePodName.relativeName(of: $0, to: spec.name) ?? $0).replacingOccurrences(of: "/", with: "_")
            }.sorted()
            if suffixes.isEmpty { return omitCommon ? ".common" : "" }
            if omitCommon {
                suffixes.insert(".common", at: 0)
            } else if omitDefault {
                suffixes.insert(".default", at: 0)
            }
            return suffixes.reduce("") { $0 + ($0.isEmpty || $1.hasPrefix(".") ? "" : "-") + $1 }
        }
        let display = ["osx": "macOS", "ios": "iOS", "tvos": "tvOS", "watchos": "watchOS", "visionos": "visionOS"]
        var minima: [String: String] = [:]
        for variant in variants {
            let attributes = try NativeVariantPlan.attributes(spec, names: variant.names, platform: variant.platform)
            let requirement =
                attributes["deployment_target"] as? String ?? (attributes["platforms"] as? [String: Any])?[
                    variant.platform] as? String ?? "0"
            minima[variant.key] =
                max(try PodVersion(requirement), try PodVersion(variant.consumerDeployment)).description
        }
        func grouped(
            _ group: [NativePodVariant], key: (NativePodVariant) -> String, suffix: (NativePodVariant) -> String,
            next: ([NativePodVariant]) -> [String: String]
        ) -> [String: String] {
            let groups = Dictionary(grouping: group, by: key)
            var result: [String: String] = [:]
            for value in groups.values {
                for (id, tail) in next(value) {
                    let head = groups.count > 1 ? suffix(value.first { $0.key == id }!) : ""
                    result[id] = [head, tail].filter { !$0.isEmpty }.joined(separator: "-")
                }
            }
            return result
        }
        func swift(_ group: [NativePodVariant]) -> [String: String] {
            grouped(
                group, key: { $0.swiftVersion ?? "" }, suffix: { $0.swiftVersion.map { "Swift" + $0 } ?? "" },
                next: { Dictionary(uniqueKeysWithValues: $0.map { ($0.key, "") }) })
        }
        func platform(_ group: [NativePodVariant]) -> [String: String] {
            let names = Dictionary(grouping: group, by: \.platform)
            let versioned = !names.values.allSatisfy { $0.count == 1 }
            return grouped(
                group, key: { $0.platform + (versioned ? minima[$0.key]! : "") },
                suffix: { (display[$0.platform] ?? $0.platform) + (versioned ? minima[$0.key]! : "") }, next: swift)
        }
        func linkage(_ group: [NativePodVariant]) -> [String: String] {
            grouped(
                group, key: { $0.mode == "dynamic" ? "dynamic" : "static" },
                suffix: { $0.mode == "dynamic" ? "dynamic" : "static" }, next: platform)
        }
        func packaging(_ group: [NativePodVariant]) -> [String: String] {
            grouped(
                group, key: { $0.mode == "library" ? "library" : "framework" },
                suffix: { $0.mode == "library" ? "library" : "framework" }, next: linkage)
        }
        let scopes = grouped(variants, key: { $0.names.joined(separator: "\n") }, suffix: specSuffix, next: packaging)
        return Dictionary(
            uniqueKeysWithValues: variants.map { variant in
                var suffix = scopes[variant.key] ?? ""
                if !deduplicate {
                    suffix = ([suffix] + variant.consumerTargets).filter { !$0.isEmpty }.joined(separator: "-")
                }
                if suffix.count >= 50 {
                    suffix =
                        Insecure.MD5.hash(data: Data(suffix.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8)
                        .description
                }
                return (variant.key, spec.name + (suffix.isEmpty ? "" : "-" + suffix))
            })
    }
}
