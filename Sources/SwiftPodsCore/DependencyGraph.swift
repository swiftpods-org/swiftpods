import Foundation

enum DependencyGraph {
    static func why(_ query: String, report: [String: Any]) throws -> [String: Any] {
        let specs = report["specs"] as? [[String: Any]] ?? []
        let targets = report["targets"] as? [[String: Any]] ?? []
        func matches(_ name: String, _ requested: String) -> Bool {
            NativePodName.isWithin(name, requested)
        }
        guard specs.contains(where: { ($0["name"] as? String).map { matches($0, query) } == true }) else {
            throw Diagnostic(
                "SP-GRAPH-NOT-FOUND", stage: "graph", "Pod \(query) is not present in the last installation report")
        }
        var chains: [[String: Any]] = []
        var truncated = false
        var ambiguousLegacy = false
        for target in targets {
            let platform = target["platform"] as? [String: String]
            let selected = specs.filter { spec in
                guard let recorded = spec["platform"] as? [String: String] else { return true }
                return recorded == platform
            }
            var byName: [String: [String: Any]] = [:]
            for (name, records) in Dictionary(grouping: selected, by: { $0["name"] as? String ?? "" }) {
                // Legacy reports did not retain platform identity. Refuse to
                // invent an edge when their duplicate records disagree.
                let dependencies = try records.map { try jsonData($0["dependencies"] ?? []) }
                if Set(dependencies).count > 1 {
                    ambiguousLegacy = true
                    continue
                }
                byName[name] = records.first
            }
            func resolved(_ dependency: String) -> [String] {
                byName[dependency] == nil ? byName.keys.filter { matches($0, dependency) }.sorted() : [dependency]
            }
            func visit(_ name: String, path: [String], requirements: [String]) {
                guard chains.count < 1_000 else {
                    truncated = true
                    return
                }
                guard !path.contains(name), let spec = byName[name] else { return }
                let nodes = path + [name]
                if matches(name, query) {
                    chains.append([
                        "target": target["name"] ?? "unknown", "platform": target["platform"] ?? "unknown",
                        "nodes": nodes.compactMap { byName[$0] }, "requirements": requirements,
                    ])
                    return
                }
                for dependency in spec["dependencies"] as? [[String: String]] ?? [] {
                    for child in resolved(dependency["name"] ?? "") {
                        visit(child, path: nodes, requirements: requirements + [dependency["requirement"] ?? ">= 0"])
                    }
                }
            }
            let direct = target["dependencies"] as? [[String: String]] ?? []
            for dependency in direct {
                for root in resolved(dependency["name"] ?? "") {
                    visit(root, path: [], requirements: [dependency["requirement"] ?? ">= 0"])
                }
            }
        }
        var result = report
        result["query"] = query
        result["dependency_chains"] = chains
        result["chains_truncated"] = truncated
        result["chains_status"] =
            !ambiguousLegacy && targets.allSatisfy { $0["dependencies"] != nil }
            ? "recorded_direct_dependencies" : "legacy_report_requires_reinstall"
        return result
    }
}
