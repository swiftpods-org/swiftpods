import Foundation

/// Adapts package declarations to native Xcode package and product references.
final class NativeSwiftPackageIntegrator {
    private var owned: [String: [String: Any]] = [:]
    private var targetProducts: [String: [String]] = [:]
    private var targetDependencies: [String: [String]] = [:]
    private var phaseFiles: [String: [String]] = [:]
    private var requirements: [String: Data] = [:]
    private var declaredReferences = Set<String>()

    static func validate(_ user: NativePBX, record: [String: Any]) throws {
        for (id, before) in record["objects"] as? [String: [String: Any]] ?? [:] {
            guard let current = user.objects[id] else { continue }
            // Ownership compares persisted PBX values, including hook scalar coercion.
            guard NativePBX.serialize(current) == NativePBX.serialize(before) else {
                throw Diagnostic(
                    "SP-SPM-CONFLICT", stage: "integrate", "Managed Swift package object was edited outside SwiftPods",
                    file: user.url.path)
            }
        }
    }

    func prepare(_ user: NativePBX, record: [String: Any]?) throws {
        let previous = record ?? legacyOwnership(user)
        try Self.validate(user, record: previous)
        targetProducts = [:]
        targetDependencies = [:]
        phaseFiles = [:]
        requirements = [:]
        declaredReferences = []
        owned = (previous["objects"] as? [String: [String: Any]] ?? [:]).filter { user.objects[$0.key] != nil }
        for (target, products) in previous["targets"] as? [String: [String]] ?? [:] where user.objects[target] != nil {
            let current = user.objects[target]?["packageProductDependencies"] as? [String] ?? []
            user.objects[target]?["packageProductDependencies"] = current.filter { !products.contains($0) }
        }
        for (phase, files) in previous["phases"] as? [String: [String]] ?? [:] where user.objects[phase] != nil {
            let current = user.objects[phase]?["files"] as? [String] ?? []
            user.objects[phase]?["files"] = current.filter { !files.contains($0) }
        }
        for (target, dependencies) in previous["dependencies"] as? [String: [String]] ?? [:]
        where user.objects[target] != nil {
            let current = user.objects[target]?["dependencies"] as? [String] ?? []
            user.objects[target]?["dependencies"] = current.filter { !dependencies.contains($0) }
        }
    }

    func finish(_ user: NativePBX) -> [String: Any] {
        // A managed reference can also be used by a user-owned product or target.
        // Remove it only once every real user is gone; container lists are not users.
        var removed = true
        while removed {
            removed = false
            for id in Array(owned.keys) {
                guard !declaredReferences.contains(id) else { continue }
                let used = user.objects.values.contains { object in
                    object.contains { key, value in
                        !["children", "packageReferences"].contains(key)
                            && ((value as? String) == id || (value as? [String])?.contains(id) == true)
                    }
                }
                guard !used else { continue }
                user.objects.removeValue(forKey: id)
                owned.removeValue(forKey: id)
                for parent in Array(user.objects.keys) {
                    for key in ["children", "packageReferences"] {
                        if let values = user.objects[parent]?[key] as? [String] {
                            user.objects[parent]?[key] = values.filter { $0 != id }
                        }
                    }
                }
                removed = true
            }
        }
        return ["objects": owned, "targets": targetProducts, "phases": phaseFiles, "dependencies": targetDependencies]
    }

    private func legacyOwnership(_ user: NativePBX) -> [String: Any] {
        var objects: [String: [String: Any]] = [:]
        for (id, object) in user.objects {
            if let url = object["repositoryURL"] as? String, id == NativePBX.identifier("swiftpods:package:" + url) {
                objects[id] = object
            }
            if let package = object["package"] as? String, let product = object["productName"] as? String,
                id == NativePBX.identifier("swiftpods:packageproduct:\(package):\(product)")
            {
                objects[id] = object
            }
            if let product = object["productRef"] as? String,
                id == NativePBX.identifier("swiftpods:packagebuild:" + product)
            {
                objects[id] = object
            }
        }
        var targets: [String: [String]] = [:]
        var dependencies: [String: [String]] = [:]
        var phases: [String: [String]] = [:]
        for (id, object) in user.objects {
            if let products = object["packageProductDependencies"] as? [String] {
                targets[id] = products.filter { objects[$0] != nil }
            }
            if let files = object["files"] as? [String] { phases[id] = files.filter { objects[$0] != nil } }
            for dependency in object["dependencies"] as? [String] ?? [] {
                guard let value = user.objects[dependency], value["isa"] as? String == "PBXTargetDependency",
                    let product = value["productRef"] as? String, objects[product] != nil,
                    dependency == NativePBX.identifier("swiftpods:packagedependency:\(id):\(product)")
                else { continue }
                objects[dependency] = value
                dependencies[id, default: []].append(dependency)
            }
        }
        return ["objects": objects, "targets": targets, "phases": phases, "dependencies": dependencies]
    }

    func integrate(_ packages: [[String: Any]], targetID: String, user: NativePBX, installedModules: Set<String>) throws
    {
        let declarations = try packages.map { try NativeSwiftPackageDeclaration($0) }
        guard let rootID = user.root["rootObject"] as? String else { return }
        for package in declarations {
            let url = package.url
            let requirement = package.requirement
            let requested = try jsonData(requirement)
            if let previous = requirements[url], previous != requested {
                throw Diagnostic(
                    "SP-SPM-CONFLICT", stage: "integrate",
                    "Consumer targets declare conflicting Swift package requirements", file: url)
            }
            requirements[url] = requested
            let reference: String
            if let existing = user.objects.first(where: {
                $0.value["isa"] as? String == "XCRemoteSwiftPackageReference"
                    && $0.value["repositoryURL"] as? String == url
            }) {
                guard try owned[existing.key] != nil || jsonData(existing.value["requirement"] ?? [:]) == requested
                else {
                    throw Diagnostic(
                        "SP-SPM-CONFLICT", stage: "integrate", "Existing Swift package uses a different requirement",
                        file: url)
                }
                reference = existing.key
                if owned[reference] != nil {
                    user.objects[reference]?["requirement"] = requirement
                    owned[reference] = user.objects[reference]
                }
            } else {
                reference = user.add(
                    "swiftpods:package:" + url,
                    ["isa": "XCRemoteSwiftPackageReference", "repositoryURL": url, "requirement": requirement])
                owned[reference] = user.objects[reference]
            }
            var refs = user.objects[rootID]?["packageReferences"] as? [String] ?? []
            if !refs.contains(reference) { refs.append(reference) }
            user.objects[rootID]?["packageReferences"] = refs
            declaredReferences.insert(reference)
            for product in package.products {
                guard !installedModules.contains(product) else {
                    throw Diagnostic(
                        "SP-DUPLICATE-SDK", stage: "integrate",
                        "Module \(product) is declared as both pod and Swift package")
                }
                var products = user.objects[targetID]?["packageProductDependencies"] as? [String] ?? []
                let existingProduct = products.first(where: {
                    user.objects[$0]?["package"] as? String == reference
                        && user.objects[$0]?["productName"] as? String == product
                })
                let id =
                    existingProduct
                    ?? user.add(
                        "swiftpods:packageproduct:\(reference):\(product)",
                        ["isa": "XCSwiftPackageProductDependency", "package": reference, "productName": product])
                if existingProduct == nil { owned[id] = user.objects[id] }
                if !package.link {
                    // Build the SDK before this consumer without merging it into a static archive.
                    var dependencies = user.objects[targetID]?["dependencies"] as? [String] ?? []
                    let existing = dependencies.first { user.objects[$0]?["productRef"] as? String == id }
                    let dependency =
                        existing
                        ?? user.add(
                            "swiftpods:packagedependency:\(targetID):\(id)",
                            ["isa": "PBXTargetDependency", "productRef": id])
                    if existing == nil {
                        owned[dependency] = user.objects[dependency]
                        dependencies.append(dependency)
                        targetDependencies[targetID, default: []].append(dependency)
                    }
                    user.objects[targetID]?["dependencies"] = dependencies
                    continue
                }
                if !products.contains(id) {
                    products.append(id)
                    targetProducts[targetID, default: []].append(id)
                }
                user.objects[targetID]?["packageProductDependencies"] = products
                if let phase = (user.objects[targetID]?["buildPhases"] as? [String])?.first(where: {
                    user.objects[$0]?["isa"] as? String == "PBXFrameworksBuildPhase"
                }) {
                    var files = user.objects[phase]?["files"] as? [String] ?? []
                    let existingBuild = files.first(where: { user.objects[$0]?["productRef"] as? String == id })
                    let build =
                        existingBuild
                        ?? user.add("swiftpods:packagebuild:" + id, ["isa": "PBXBuildFile", "productRef": id])
                    if existingBuild == nil { owned[build] = user.objects[build] }
                    if !files.contains(build) {
                        files.append(build)
                        phaseFiles[phase, default: []].append(build)
                    }
                    user.objects[phase]?["files"] = files
                }
            }
        }
    }
}
