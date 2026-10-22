import Foundation

struct NativeResolution {
    let specs: [String: NativeSpec]
    let requests: [NativeDependency]
}

struct NativeResolver {
    var candidates: (NativeDependency) throws -> [NativeSpec]
    var materialize: (NativeSpec) throws -> NativeSpec = { $0 }
    var locked: [String: String] = [:]
    var update = Set<String>()
    func resolve(_ dependencies: [NativeDependency]) throws -> NativeResolution {
        var failure: Error?
        var conflicts = Set<String>()
        func cycle(in requests: [NativeDependency], platform: String) -> [String]? {
            var edges: [String: Set<String>] = [:]
            for request in requests where request.platform == platform {
                if let parent = request.chain.last { edges[parent, default: []].insert(request.name) }
            }
            var visited = Set<String>()
            var active = Set<String>()
            var path: [String] = []
            func visit(_ name: String) -> [String]? {
                if active.contains(name), let start = path.firstIndex(of: name) {
                    return Array(path[start...]) + [name]
                }
                guard visited.insert(name).inserted else { return nil }
                active.insert(name)
                path.append(name)
                defer {
                    active.remove(name)
                    path.removeLast()
                }
                for child in edges[name, default: []].sorted() {
                    if let result = visit(child) { return result }
                }
                return nil
            }
            for name in edges.keys.sorted() {
                if let result = visit(name) { return result }
            }
            return nil
        }
        func search(
            _ queue: [NativeDependency], selected: [String: NativeSpec], expanded: Set<String>,
            requests: [NativeDependency]
        ) throws -> NativeResolution? {
            try NativeCancellation.check()
            guard !queue.isEmpty else {
                // Each platform builds its own graph, even when versions are shared.
                for platform in Set(requests.map(\.platform)).sorted() {
                    if let cycle = cycle(in: requests, platform: platform) {
                        failure = Diagnostic(
                            "SP-RESOLVE-CONFLICT", stage: "resolve",
                            "Circular dependency: " + cycle.joined(separator: " -> "), dependencyChain: cycle)
                        return nil
                    }
                }
                for (root, spec) in selected where spec.version.isPrerelease {
                    if !update.contains(root), let version = try locked[root].map(PodVersion.init),
                        version.isPrerelease && version == spec.version
                    {
                        continue
                    }
                    let allowed = requests.contains { request in
                        request.root == root
                            && (request.external
                                || (try? PodRequirement(request.requirements).allowsPrerelease) == true)
                    }
                    if !allowed { return nil }
                }
                return NativeResolution(specs: selected, requests: requests)
            }
            // The profile activates existing, external, prerelease and previously
            // conflicting requirements first, then the most constrained set.
            var ordered: [(index: Int, request: NativeDependency, score: [Int])] = []
            for (index, candidate) in queue.enumerated() {
                let requirement = try PodRequirement(candidate.requirements)
                let pin = update.contains(candidate.root) ? nil : try locked[candidate.root].map(PodVersion.init)
                let possible = try (selected[candidate.root].map { [$0] } ?? candidates(candidate)).filter { spec in
                    requirement.accepts(spec.version) && (pin == nil || spec.version == pin)
                        && dependencies.filter { $0.root == candidate.root }.allSatisfy {
                            (try? PodRequirement($0.requirements).accepts(spec.version)) == true
                        }
                }.count
                ordered.append(
                    (
                        index, candidate,
                        [
                            requests.contains { $0.name == candidate.name } ? 0 : 1, candidate.external ? 0 : 1,
                            requirement.allowsPrerelease ? 0 : 1, conflicts.contains(candidate.name) ? 0 : 1, possible,
                            index,
                        ]
                    ))
            }
            ordered.sort { $0.score.lexicographicallyPrecedes($1.score) }
            let first = ordered[0]
            let request = first.request
            var remainder = queue
            remainder.remove(at: first.index)
            let requirement = try PodRequirement(request.requirements)
            let choices: [NativeSpec]
            if let existing = selected[request.root] {
                choices = [existing]
            } else {
                let found = try candidates(request)
                choices = found.sorted {
                    let pin = update.contains(request.root) ? nil : locked[request.root]
                    if ($0.version.description == pin) != ($1.version.description == pin) {
                        return $0.version.description == pin
                    }
                    return $0.version.isPreferred(to: $1.version)
                }
            }
            let pin = update.contains(request.root) ? nil : try locked[request.root].map(PodVersion.init)
            for spec in choices where requirement.accepts(spec.version) && (pin == nil || spec.version == pin) {
                try NativeCancellation.check()
                let spec = try materialize(spec)
                var chosen = selected
                chosen[request.root] = spec
                let key = request.name + ":" + request.platform + ":" + request.deployment
                if expanded.contains(key) {
                    if let value = try search(
                        remainder, selected: chosen, expanded: expanded, requests: requests + [request])
                    {
                        return value
                    }
                    continue
                }
                do {
                    try spec.validateSupplementary(request)
                    let more = try spec.dependencies(for: request).map { dependency -> NativeDependency in
                        var child = dependency
                        child.chain = request.chain + [request.name]
                        return child
                    }
                    if let value = try search(
                        more + remainder, selected: chosen, expanded: expanded.union([key]),
                        requests: requests + [request])
                    {
                        return value
                    }
                } catch let error as Diagnostic where ["SP-SPEC-SUBSPEC", "SP-PLATFORM-CONFLICT"].contains(error.code) {
                    failure = error
                }
            }
            conflicts.insert(request.name)
            if (failure as? Diagnostic)?.dependencyChain.count ?? 0 <= request.chain.count {
                failure = Diagnostic(
                    "SP-RESOLVE-CONFLICT", stage: "resolve",
                    "No compatible version for \(request.name) (\(request.requirements.joined(separator: ", ")))"
                        + (pin.map { "; locked at " + $0.description } ?? ""),
                    dependencyChain: request.chain + [request.name])
            }
            return nil
        }
        if let result = try search(dependencies, selected: [:], expanded: [], requests: []) {
            for spec in result.specs.values.sorted(by: { $0.name < $1.name }) { try spec.validateProfile() }
            return result
        }
        throw failure
            ?? Diagnostic("SP-RESOLVE-CONFLICT", stage: "resolve", "Dependency constraints cannot be satisfied")
    }
}
