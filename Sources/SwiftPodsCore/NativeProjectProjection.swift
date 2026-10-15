import Foundation

/// Builds a self-contained project from the canonical generation graph.
/// Remote target IDs in container proxies identify objects in other projects.
enum NativeProjectProjection {
    static func reachable(_ objects: [String: [String: Any]], from seeds: [String], restrictedTargets: Set<String>? = nil) -> Set<String> {
        var found = Set<String>(), queue = seeds
        func references(_ value: Any) -> [String] {
            if let id = value as? String { return objects[id] == nil ? [] : [id] }
            if let values = value as? [Any] { return values.flatMap(references) }
            if let values = value as? [String: Any] { return values.filter { !["remoteGlobalIDString", "TestTargetID"].contains($0.key) }.values.flatMap(references) }
            return []
        }
        while let id = queue.popLast() {
            guard let object = objects[id], found.insert(id).inserted else { continue }
            if let restrictedTargets, ["PBXNativeTarget", "PBXAggregateTarget"].contains(object["isa"] as? String ?? ""), !restrictedTargets.contains(id) { found.remove(id); continue }
            queue += references(object)
        }
        return found
    }

    static func make(source: NativePBX, url: URL, targets: [String], owner: String?, owners: [String: String], projectForPod: (String) -> URL, allPods: [String]) throws -> NativePBX {
        guard let originalRoot = source.root["rootObject"] as? String, var project = source.objects[originalRoot] else { throw Diagnostic("SP-XCODE-PROJECT", stage: "integrate", "Generated project root is unavailable") }
        let result = try NativePBX(url)
        result.root = source.root
        let sourceConfigurations = (project["buildConfigurationList"] as? String).map { [$0] } ?? []
        let local = reachable(source.objects, from: targets + sourceConfigurations, restrictedTargets: Set(targets))
        result.objects = local.reduce(into: [:]) { $0[$1] = source.objects[$1] }
        let label = owner ?? "Pods"
        let root = owner.map { NativePBX.identifier("project-root:" + $0 + ":" + originalRoot) } ?? originalRoot
        var navigation: [String] = []
        func portal(_ pod: String) -> String {
            result.add("pod-project:" + pod, ["isa": "PBXFileReference", "path": projectForPod(pod).path, "sourceTree": "<absolute>", "lastKnownFileType": "wrapper.pb-project"])
        }
        for target in targets {
            for dependency in result.objects[target]?["dependencies"] as? [String] ?? [] {
                guard let remote = result.objects[dependency]?["target"] as? String, let pod = owners[remote], pod != owner else { continue }
                let reference = portal(pod), name = source.objects[remote]?["name"] as? String ?? pod
                let proxy = result.add("pod-project-proxy:" + remote, ["isa": "PBXContainerItemProxy", "containerPortal": reference, "proxyType": "1", "remoteGlobalIDString": remote, "remoteInfo": name])
                result.objects[dependency]?.removeValue(forKey: "target")
                result.objects[dependency]?["targetProxy"] = proxy; result.objects[dependency]?["name"] = name
            }
        }
        if owner == nil { navigation = allPods.map(portal) }
        if let owner, let list = project["buildConfigurationList"] as? String, var configurations = result.objects[list] {
            let entries = (configurations["buildConfigurations"] as? [String] ?? []).compactMap { id -> String? in
                guard let value = source.objects[id] else { return nil }
                return result.add("project-configuration:" + owner + ":" + id, value)
            }
            configurations["buildConfigurations"] = entries
            project["buildConfigurationList"] = result.add("project-configurations:" + owner, configurations)
        }
        var attributes = project["attributes"] as? [String: Any] ?? [:]
        if let associations = attributes["TargetAttributes"] as? [String: Any] { attributes["TargetAttributes"] = associations.filter { targets.contains($0.key) } }
        attributes["SwiftPodsProject"] = label; project["attributes"] = attributes
        let targetProducts = targets.compactMap { source.objects[$0]?["productReference"] as? String }
        let configuration = project["buildConfigurationList"] as? String
        let required = reachable(result.objects, from: targets + navigation + (configuration.map { [$0] } ?? []))
        let localizedChildren = Set(required.flatMap { result.objects[$0]?["isa"] as? String == "PBXVariantGroup" ? result.objects[$0]?["children"] as? [String] ?? [] : [] })
        let visible = Set(required.filter { id in
            ["PBXFileReference", "PBXVariantGroup"].contains(result.objects[id]?["isa"] as? String ?? "") && !targetProducts.contains(id) && !localizedChildren.contains(id)
        })
        var placed = Set<String>()
        func copyGroup(_ id: String) -> String? {
            guard var value = source.objects[id] else { return nil }
            if visible.contains(id) { placed.insert(id); return id }
            guard value["isa"] as? String == "PBXGroup", id != project["productRefGroup"] as? String else { return nil }
            let children = (value["children"] as? [String] ?? []).compactMap(copyGroup)
            guard !children.isEmpty else { return nil }
            value["children"] = children; result.objects[id] = value; return id
        }
        let originalChildren = (project["mainGroup"] as? String).flatMap { source.objects[$0]?["children"] as? [String] } ?? []
        let visibleGroups = originalChildren.compactMap(copyGroup)
        let products = result.add("project-products:" + label, ["isa": "PBXGroup", "name": "Products", "sourceTree": "<group>", "children": targetProducts])
        let group = result.add("project-group:" + label, ["isa": "PBXGroup", "sourceTree": "<group>", "children": visibleGroups + visible.subtracting(placed).sorted() + [products]])
        project["targets"] = targets; project["mainGroup"] = group; project["productRefGroup"] = products
        result.objects[root] = project; result.root["rootObject"] = root
        let included = reachable(result.objects, from: [root])
        result.objects = result.objects.filter { included.contains($0.key) }
        return result
    }
}
