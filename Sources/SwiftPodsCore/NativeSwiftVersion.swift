import Foundation

enum NativeSwiftVersion {
    static func select(spec: NativeSpec, targets: [[String: Any]]) throws -> String? {
        let supported = nativeStrings(spec.data["swift_versions"] ?? spec.data["swift_version"])
        if supported.isEmpty { return targets.compactMap { $0["swift_version"] as? String }.first }
        let versions = try supported.map(PodVersion.init).sorted(by: >)
        let requirements = try targets.map { try PodRequirement(nativeStrings($0["swift_version_requirements"])) }
        if let version = versions.first(where: { version in requirements.allSatisfy { $0.accepts(version) } }) {
            return version.description
        }
        let constraints = targets.map {
            ($0["name"] as? String ?? "") + ": "
                + nativeStrings($0["swift_version_requirements"]).joined(separator: ", ")
        }.joined(separator: "; ")
        throw Diagnostic(
            "SP-SWIFT-VERSION-CONFLICT", stage: "analyze",
            "No supported Swift version for \(spec.name). Available: \(supported.joined(separator: ", ")). Consumers: \(constraints)",
            file: spec.name)
    }
}
