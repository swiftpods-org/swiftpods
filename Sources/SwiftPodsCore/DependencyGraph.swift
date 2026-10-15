import Foundation

enum DependencyGraph {
    static func why(_ query: String, report: [String: Any]) throws -> [String: Any] {
        let specs = report["specs"] as? [[String: Any]] ?? []
        let targets = report["targets"] as? [[String: Any]] ?? []
        let byName = Dictionary(specs.compactMap { spec -> (String, [String: Any])? in
            guard let name = spec["name"] as? String else { return nil }; return (name, spec)
        }, uniquingKeysWith: { first, _ in first })
        func matches(_ name: String, _ requested: String) -> Bool { name == requested || name.hasPrefix(requested + "/") }
        func resolved(_ dependency: String) -> [String] {
            byName[dependency] == nil ? byName.keys.filter { matches($0, dependency) }.sorted() : [dependency]
        }
        guard byName.keys.contains(where: { matches($0, query) }) else {
            throw Diagnostic("SP-GRAPH-NOT-FOUND", stage: "graph", "Pod \(query) is not present in the last installation report")
        }
        var chains: [[String: Any]] = []
        var truncated = false
        func visit(_ name: String, target: [String: Any], path: [String], requirements: [String]) {
            guard chains.count < 1_000 else { truncated = true; return }
            guard !path.contains(name), let spec = byName[name] else { return }
            let nodes = path + [name]
            if matches(name, query) {
                chains.append(["target": target["name"] ?? "unknown", "platform": target["platform"] ?? "unknown",
                               "nodes": nodes.compactMap { byName[$0] }, "requirements": requirements])
                return
            }
            for dependency in spec["dependencies"] as? [[String: String]] ?? [] {
                for child in resolved(dependency["name"] ?? "") {
                    visit(child, target: target, path: nodes, requirements: requirements + [dependency["requirement"] ?? ">= 0"])
                }
            }
        }
        for target in targets {
            let direct = target["dependencies"] as? [[String: String]] ?? []
            for dependency in direct {
                for root in resolved(dependency["name"] ?? "") {
                    visit(root, target: target, path: [], requirements: [dependency["requirement"] ?? ">= 0"])
                }
            }
        }
        var result = report
        result["query"] = query; result["dependency_chains"] = chains
        result["chains_truncated"] = truncated
        result["chains_status"] = targets.allSatisfy { $0["dependencies"] != nil } ? "recorded_direct_dependencies" : "legacy_report_requires_reinstall"
        return result
    }
}
