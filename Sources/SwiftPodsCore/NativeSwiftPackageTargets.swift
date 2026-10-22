import Foundation

/// Package products name groups of targets; only their selected targets define modules.
enum NativeSwiftPackageTargets {
    struct Entry {
        let package: NativeSwiftPackageGraph.Package
        let target: [String: Any]
    }

    static func list(
        _ products: [String], package: NativeSwiftPackageGraph.Package, graph: NativeSwiftPackageGraph, platform: String
    ) throws -> [Entry] {
        var result: [Entry] = []
        var visited = Set<String>()

        func visitProduct(_ name: String, package: NativeSwiftPackageGraph.Package) throws {
            let document = try graph.manifest(package)
            guard
                let product = (document["products"] as? [[String: Any]])?.first(where: { $0["name"] as? String == name }
                ),
                let targets = product["targets"] as? [String]
            else {
                throw Diagnostic(
                    "SP-SPM-PRODUCT", stage: "integrate", "Package product not found: " + name, file: package.location)
            }
            for target in targets { try visitTarget(target, package: package) }
        }

        func visitTarget(_ name: String, package: NativeSwiftPackageGraph.Package) throws {
            guard visited.insert(package.directory.path + ":" + name).inserted else { return }
            let targets = try graph.manifest(package)["targets"] as? [[String: Any]] ?? []
            guard let target = targets.first(where: { $0["name"] as? String == name }) else {
                throw Diagnostic(
                    "SP-SPM-TARGET", stage: "integrate", "Package target not found: " + name, file: package.location)
            }
            // Host implementation targets never become consumer compiler interfaces.
            guard !["macro", "plugin"].contains(target["type"] as? String ?? "regular") else { return }
            result.append(Entry(package: package, target: target))
            for dependency in target["dependencies"] as? [[String: Any]] ?? [] {
                guard let values = (dependency["target"] ?? dependency["byName"] ?? dependency["product"]) as? [Any],
                    let dependencyName = values.first as? String
                else {
                    throw Diagnostic(
                        "SP-SPM-DEPENDENCY", stage: "integrate", "Invalid package target dependency", file: name)
                }
                if let condition = values.last as? [String: Any],
                    let platforms = condition["platformNames"] as? [String],
                    !platforms.isEmpty && !platforms.contains(platform)
                {
                    continue
                }
                if let condition = values.last as? [String: Any],
                    condition.contains(where: {
                        $0.key != "platformNames" && !($0.value is NSNull)
                            && ($0.value as? [Any])?.isEmpty != true && ($0.value as? [String: Any])?.isEmpty != true
                    })
                {
                    throw Diagnostic(
                        "SP-SPM-CONDITION", stage: "integrate", "Unsupported package dependency condition", file: name)
                }
                if dependency["target"] != nil
                    || (dependency["byName"] != nil && targets.contains { $0["name"] as? String == dependencyName })
                {
                    try visitTarget(dependencyName, package: package)
                    continue
                }
                if dependency["product"] != nil, values.count > 2,
                    let aliases = values[2] as? [String: String], !aliases.isEmpty
                {
                    throw Diagnostic(
                        "SP-SPM-ALIASES", stage: "integrate",
                        "Module aliases cannot be exported as Objective-C compiler interfaces",
                        file: dependencyName)
                }
                let explicit = values.count > 1 ? values[1] as? String : nil
                var matches: [NativeSwiftPackageGraph.Package] = []
                for entry in try graph.dependencies(package) {
                    if let explicit,
                        ![entry.package.identity, entry.name ?? ""].contains(where: {
                            $0.lowercased() == explicit.lowercased()
                        })
                    {
                        continue
                    }
                    if (try graph.manifest(entry.package)["products"] as? [[String: Any]] ?? []).contains(where: {
                        $0["name"] as? String == dependencyName
                    }) {
                        matches.append(entry.package)
                    }
                }
                guard matches.count == 1, let resolved = matches.first else {
                    throw Diagnostic(
                        "SP-SPM-PRODUCT", stage: "integrate",
                        "Dependency product is missing or ambiguous: " + dependencyName,
                        file: package.location)
                }
                try visitProduct(dependencyName, package: resolved)
            }
        }

        for product in products { try visitProduct(product, package: package) }
        return result
    }
}
