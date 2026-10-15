import Foundation

/// Adapts package declarations to native Xcode package and product references.
struct NativeSwiftPackageIntegrator {
    let installedModules: Set<String>

    func integrate(_ packages: [[String: Any]], targetID: String, user: NativePBX) throws {
        guard let rootID = user.root["rootObject"] as? String else { return }
        for package in packages {
            guard let url = package["git"] as? String else {
                throw Diagnostic("SP-SPM-URL", stage: "integrate", "Swift packages require :git")
            }
            let keys = ["exact", "from", "range", "branch", "revision"].filter { package[$0] != nil }
            guard keys.count == 1 else {
                throw Diagnostic("SP-SPM-REQUIREMENT", stage: "integrate", "Specify one Swift package requirement")
            }
            var requirement: [String: Any]
            switch keys[0] {
            case "exact": requirement = ["kind": "exactVersion", "version": package["exact"]!]
            case "from": requirement = ["kind": "upToNextMajorVersion", "minimumVersion": package["from"]!]
            case "branch": requirement = ["kind": "branch", "branch": package["branch"]!]
            case "revision": requirement = ["kind": "revision", "revision": package["revision"]!]
            default:
                guard let range = package["range"] as? [String], range.count == 2 else {
                    throw Diagnostic("SP-SPM-REQUIREMENT", stage: "integrate", "Swift package range needs two versions")
                }
                requirement = ["kind": "versionRange", "minimumVersion": range[0], "maximumVersion": range[1]]
            }
            let reference: String
            if let existing = user.objects.first(where: {
                $0.value["isa"] as? String == "XCRemoteSwiftPackageReference"
                    && $0.value["repositoryURL"] as? String == url
            }) {
                guard try jsonData(existing.value["requirement"] ?? [:]) == jsonData(requirement) else {
                    throw Diagnostic(
                        "SP-SPM-CONFLICT", stage: "integrate", "Existing Swift package uses a different requirement",
                        file: url)
                }
                reference = existing.key
            } else {
                reference = user.add(
                    "swiftpods:package:" + url,
                    ["isa": "XCRemoteSwiftPackageReference", "repositoryURL": url, "requirement": requirement])
            }
            var refs = user.objects[rootID]?["packageReferences"] as? [String] ?? []
            if !refs.contains(reference) { refs.append(reference) }
            user.objects[rootID]?["packageReferences"] = refs
            for product in nativeStrings(package["products"]) {
                guard !installedModules.contains(product) else {
                    throw Diagnostic(
                        "SP-DUPLICATE-SDK", stage: "integrate",
                        "Module \(product) is declared as both pod and Swift package")
                }
                var products = user.objects[targetID]?["packageProductDependencies"] as? [String] ?? []
                let id =
                    products.first(where: {
                        user.objects[$0]?["package"] as? String == reference
                            && user.objects[$0]?["productName"] as? String == product
                    })
                    ?? user.add(
                        "swiftpods:packageproduct:\(reference):\(product)",
                        ["isa": "XCSwiftPackageProductDependency", "package": reference, "productName": product])
                if !products.contains(id) { products.append(id) }
                user.objects[targetID]?["packageProductDependencies"] = products
                if let phase = (user.objects[targetID]?["buildPhases"] as? [String])?.first(where: {
                    user.objects[$0]?["isa"] as? String == "PBXFrameworksBuildPhase"
                }) {
                    var files = user.objects[phase]?["files"] as? [String] ?? []
                    let build =
                        files.first(where: { user.objects[$0]?["productRef"] as? String == id })
                        ?? user.add("swiftpods:packagebuild:" + id, ["isa": "PBXBuildFile", "productRef": id])
                    if !files.contains(build) { files.append(build) }
                    user.objects[phase]?["files"] = files
                }
            }
        }
    }
}
