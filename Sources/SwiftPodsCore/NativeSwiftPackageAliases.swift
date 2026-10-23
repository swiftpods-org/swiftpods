import Foundation

/// SwiftPM renames a dependency module throughout the resolved graph, including
/// consumers whose own product dependency does not declare that alias.
enum NativeSwiftPackageAliases {
    static func identity(_ name: String, package: NativeSwiftPackageGraph.Package) throws -> String {
        try digest(
            jsonData(["package": package.directory.standardizedFileURL.resolvingSymlinksInPath().path, "target": name]))
    }

    struct Plan {
        let names: [String: String]
        let traits: [String: Set<String>]
    }

    private struct Definition {
        let origin: String
        let consumer: String
        let product: String
        let roots: [String]
        let aliases: [String: String]
        let key: String
    }

    private struct Product {
        let identity: String
        let targets: [String]
    }

    private struct Module: Equatable {
        var name: String
        var previous: Set<String>
    }

    private struct Request: Hashable {
        let consumer: String
        let alias: String
    }

    static func resolve(_ graph: NativeSwiftPackageGraph, roots: [NativeSwiftPackageGraph.Root]? = nil) throws -> Plan {
        var packages: [String: NativeSwiftPackageGraph.Package] = [:]
        var documents: [String: [String: Any]] = [:]
        var dependencies: [String: [(name: String?, package: NativeSwiftPackageGraph.Package)]] = [:]
        func path(_ package: NativeSwiftPackageGraph.Package) -> String {
            package.directory.standardizedFileURL.resolvingSymlinksInPath().path
        }
        func discover(_ package: NativeSwiftPackageGraph.Package, required: Bool) throws {
            let key = path(package)
            guard packages[key] == nil else { return }
            let document: [String: Any]
            if required {
                document = try graph.manifest(package)
            } else {
                guard let value = try? graph.manifest(package) else { return }
                document = value
            }
            packages[key] = package
            documents[key] = document
            dependencies[key] = try graph.dependencies(package)
            for dependency in dependencies[key] ?? [] { try discover(dependency.package, required: false) }
        }
        for package in graph.packages { try discover(package, required: true) }

        var parents: [String: Set<String>] = [:]
        for (key, entries) in dependencies {
            for entry in entries where packages[path(entry.package)] != nil {
                parents[path(entry.package), default: []].insert(key)
            }
        }
        var traits = Dictionary(uniqueKeysWithValues: packages.keys.map { ($0, Set<String>()) })
        if let roots {
            func location(_ raw: String) -> String {
                let value = NativeSwiftPackageGraph.location(raw)
                return value.hasPrefix("/") ? URL(fileURLWithPath: value).resolvingSymlinksInPath().path : value
            }
            for (key, package) in packages {
                for root in roots where location(root.location) == location(package.location) {
                    traits[key, default: []].formUnion(root.traits)
                }
            }
        } else {
            for key in packages.keys where parents[key, default: []].isEmpty {
                traits[key, default: []].insert("default")
            }
        }
        func enabled(_ condition: [String: Any]?, in key: String) -> Bool {
            guard let names = condition?["traits"] as? [String], !names.isEmpty else { return true }
            return !traits[key, default: []].isDisjoint(with: names)
        }
        // Traits are additive. Include their transitive implications and the
        // union of requests from all parents before inspecting conditional edges.
        while true {
            let previous = traits
            for key in packages.keys.sorted() {
                for trait in documents[key]?["traits"] as? [[String: Any]] ?? [] {
                    if let name = trait["name"] as? String, traits[key, default: []].contains(name) {
                        traits[key, default: []].formUnion(trait["enabledTraits"] as? [String] ?? [])
                    }
                }
                for declaration in documents[key]?["dependencies"] as? [[String: Any]] ?? [] {
                    guard
                        let source = ((declaration["sourceControl"] ?? declaration["fileSystem"]) as? [[String: Any]])?
                            .first,
                        let identity = source["identity"] as? String,
                        let dependency = dependencies[key]?.first(where: { $0.package.identity == identity }),
                        packages[path(dependency.package)] != nil
                    else { continue }
                    let requests = source["traits"] as? [[String: Any]] ?? [["name": "default"]]
                    for request in requests where enabled(request["condition"] as? [String: Any], in: key) {
                        if let name = request["name"] as? String {
                            traits[path(dependency.package), default: []].insert(name)
                        }
                    }
                }
            }
            if previous == traits { break }
        }

        var originals: [String: String] = [:]
        var localEdges: [String: [String]] = [:]
        var productEdges: [String: [Product]] = [:]
        var publicProducts: [String: [Product]] = [:]
        var aliasParents: [String: Set<String>] = [:]
        var definitions: [Definition] = []
        func product(_ name: String, in package: NativeSwiftPackageGraph.Package) -> [String]? {
            (documents[path(package)]?["products"] as? [[String: Any]])?.first { $0["name"] as? String == name }?[
                "targets"] as? [String]
        }
        func productIdentity(_ name: String, package: NativeSwiftPackageGraph.Package) throws -> String {
            try digest(jsonData(["package": path(package), "product": name]))
        }
        func visit(_ name: String, in package: NativeSwiftPackageGraph.Package) throws {
            let key = try identity(name, package: package)
            guard originals[key] == nil,
                let target = (documents[path(package)]?["targets"] as? [[String: Any]])?.first(where: {
                    $0["name"] as? String == name
                }),
                target["type"] as? String != "test"
            else { return }
            originals[key] = name
            let targets = documents[path(package)]?["targets"] as? [[String: Any]] ?? []
            for dependency in target["dependencies"] as? [[String: Any]] ?? [] {
                guard let values = (dependency["target"] ?? dependency["byName"] ?? dependency["product"]) as? [Any],
                    let dependencyName = values.first as? String,
                    enabled(values.last as? [String: Any], in: path(package))
                else { continue }
                // Alias propagation is independent of destination platform.
                // Platform conditions still filter the public interface traversal.
                if dependency["target"] != nil
                    || (dependency["byName"] != nil && targets.contains { $0["name"] as? String == dependencyName })
                {
                    let child = try identity(dependencyName, package: package)
                    localEdges[key, default: []].append(child)
                    try visit(dependencyName, in: package)
                    continue
                }
                let explicit = values.count > 1 ? values[1] as? String : nil
                let matches = (dependencies[path(package)] ?? []).filter { entry in
                    (explicit == nil
                        || [entry.package.identity, entry.name ?? ""].contains {
                            $0.lowercased() == explicit!.lowercased()
                        })
                        && product(dependencyName, in: entry.package) != nil
                }
                // Unselected products may refer to a pruned dependency. The
                // selected interface traversal diagnoses unresolved dependencies.
                guard matches.count == 1, let resolved = matches.first?.package,
                    let children = product(dependencyName, in: resolved)
                else { continue }
                let childKeys = try children.map { try identity($0, package: resolved) }
                let childProduct = Product(
                    identity: try productIdentity(dependencyName, package: resolved), targets: childKeys)
                productEdges[key, default: []].append(childProduct)
                aliasParents[path(resolved), default: []].insert(path(package))
                for child in children { try visit(child, in: resolved) }
                if dependency["product"] != nil, values.count > 2,
                    let aliases = values[2] as? [String: String], !aliases.isEmpty
                {
                    definitions.append(
                        Definition(
                            origin: path(resolved), consumer: path(package), product: childProduct.identity,
                            roots: childKeys, aliases: aliases,
                            key: try digest(jsonData(["consumer": key, "product": dependencyName, "aliases": aliases])))
                    )
                }
            }
        }
        for key in packages.keys.sorted() {
            guard let package = packages[key] else { continue }
            for declaration in documents[key]?["products"] as? [[String: Any]] ?? [] {
                guard let name = declaration["name"] as? String, let targets = declaration["targets"] as? [String]
                else { continue }
                publicProducts[key, default: []].append(
                    Product(
                        identity: try productIdentity(name, package: package),
                        targets: try targets.map { try identity($0, package: package) }))
                for target in targets { try visit(target, in: package) }
            }
        }
        guard !definitions.isEmpty else { return Plan(names: [:], traits: traits) }
        var declared: [String: [String: String]] = [:]
        for definition in definitions {
            for (name, alias) in definition.aliases {
                if let previous = declared[definition.origin]?[name], previous != alias {
                    throw Diagnostic(
                        "SP-SPM-ALIASES", stage: "integrate", "Conflicting package module aliases", file: name)
                }
                declared[definition.origin, default: [:]][name] = alias
            }
        }
        // SwiftPM collects declarations from public products, then propagates
        // them through products reached from the dependency graph's roots.
        // A resolved package's unvisited product can declare an alias without
        // making its entire transitive interface participate in propagation.
        var activeProducts = Set<String>()
        var pendingTargets: [String] = []
        for (key, products) in publicProducts where aliasParents[key, default: []].isEmpty {
            for product in products {
                activeProducts.insert(product.identity)
                pendingTargets.append(contentsOf: product.targets)
            }
        }
        var activeTargets = Set<String>()
        while let key = pendingTargets.popLast() {
            guard activeTargets.insert(key).inserted else { continue }
            pendingTargets.append(contentsOf: localEdges[key] ?? [])
            for product in productEdges[key] ?? [] {
                activeProducts.insert(product.identity)
                pendingTargets.append(contentsOf: product.targets)
            }
        }
        var depths: [String: Int] = [:]
        func depth(_ key: String, visited: Set<String> = []) -> Int {
            if let cached = depths[key] { return cached }
            guard !visited.contains(key) else { return 0 }
            let seen = visited.union([key])
            let value = (aliasParents[key] ?? []).map { depth($0, visited: seen) + 1 }.max() ?? 0
            depths[key] = value
            return value
        }
        let ordered = definitions.filter { activeProducts.contains($0.product) }.sorted {
            let left = depth($0.consumer)
            let right = depth($1.consumer)
            return left == right ? $0.key < $1.key : left > right
        }
        var localClosures: [[String]: [String]] = [:]
        func localClosure(_ roots: [String]) -> [String] {
            if let cached = localClosures[roots] { return cached }
            var result: [String] = []
            var seen = Set<String>()
            // SwiftPM visits product dependencies of internal targets before
            // those declared directly by the product's root targets.
            for root in roots {
                var pending = localEdges[root] ?? []
                var index = 0
                while index < pending.count {
                    let key = pending[index]
                    index += 1
                    guard seen.insert(key).inserted else { continue }
                    result.append(key)
                    pending.append(contentsOf: localEdges[key] ?? [])
                }
            }
            for root in roots where seen.insert(root).inserted { result.append(root) }
            let targets = result.filter { originals[$0] != nil }
            localClosures[roots] = targets
            return targets
        }
        var modules = originals.mapValues {
            Module(name: NativeSwiftPackageC99.moduleName($0), previous: [$0, NativeSwiftPackageC99.moduleName($0)])
        }
        func matches(_ name: String, roots: [String]) -> Set<String> {
            var visited = Set<[String]>()
            func visit(_ roots: [String]) -> Set<String> {
                guard visited.insert(roots).inserted else { return [] }
                let local = localClosure(roots)
                let matched = local.filter { key in
                    guard let module = modules[key] else { return false }
                    return module.name == name || module.previous.contains(name)
                }
                // A product's own targets and their internal dependencies take
                // precedence over identically named modules in child products.
                guard matched.isEmpty else { return Set(matched) }
                for key in local {
                    for child in productEdges[key] ?? [] {
                        let matched = visit(child.targets)
                        // An alias is consumed by its first matching product.
                        if !matched.isEmpty { return matched }
                    }
                }
                return []
            }
            return visit(roots)
        }
        func chain(_ name: String, aliases: [String: String]) throws -> [String] {
            var result = [name]
            var current = name
            var seen = Set<String>()
            while let next = aliases[current], next != current {
                guard seen.insert(current).inserted else {
                    throw Diagnostic("SP-SPM-ALIASES", stage: "integrate", "Cyclic package module aliases", file: name)
                }
                result.append(next)
                current = next
            }
            return result
        }
        var ancestors: [String: Set<String>] = [:]
        func consumers(of package: String) -> Set<String> {
            if let cached = ancestors[package] { return cached }
            var pending = Array(aliasParents[package] ?? [])
            var result = Set<String>()
            while let key = pending.popLast() {
                guard result.insert(key).inserted else { continue }
                pending.append(contentsOf: aliasParents[key] ?? [])
            }
            ancestors[package] = result
            return result
        }
        func validate(_ requests: [String: Set<Request>]) throws {
            for key in requests.keys.sorted() {
                let declarations = requests[key]!
                // Only an actual, more-dependent rename overrides a request.
                // A shared ancestor without a rename cannot choose between
                // conflicting aliases from otherwise independent consumers.
                let maximal = declarations.filter { request in
                    !declarations.contains {
                        $0.consumer != request.consumer && consumers(of: request.consumer).contains($0.consumer)
                    }
                }
                guard !maximal.isEmpty, Set(maximal.map(\.alias)).count == 1 else {
                    throw Diagnostic(
                        "SP-SPM-ALIASES", stage: "integrate",
                        "Conflicting aliases for the same resolved package module",
                        file: originals[key])
                }
            }
        }
        for _ in 0...(definitions.count + 1) {
            let previous = modules
            var requests: [String: Set<Request>] = [:]
            for definition in ordered {
                var candidates: [String: Set<String>] = [:]
                for name in definition.aliases.keys.sorted() {
                    let targets = matches(name, roots: definition.roots)
                    guard !targets.isEmpty else { continue }
                    let alias = try chain(name, aliases: definition.aliases).last!
                    for key in targets {
                        candidates[key, default: []].insert(name)
                        requests[key, default: []].insert(Request(consumer: definition.consumer, alias: alias))
                    }
                }
                for key in candidates.keys.sorted() {
                    guard var module = modules[key], let original = originals[key] else { continue }
                    let names =
                        [original, NativeSwiftPackageC99.moduleName(original), module.name] + module.previous.sorted()
                    guard let renamed = names.first(where: { candidates[key]!.contains($0) }) else { continue }
                    let aliases = try chain(renamed, aliases: definition.aliases)
                    module.previous.formUnion(aliases)
                    module.name = aliases.last!
                    modules[key] = module
                }
            }
            if modules == previous {
                try validate(requests)
                return Plan(names: modules.mapValues(\.name), traits: traits)
            }
        }
        throw Diagnostic("SP-SPM-ALIASES", stage: "integrate", "Package module aliases do not converge")
    }
}
