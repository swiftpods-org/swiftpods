import Foundation

enum NativeSwiftPackageModules {
    static func names(
        _ product: String, package: NativeSwiftPackageGraph.Package, graph: NativeSwiftPackageGraph,
        destination: NativeSwiftPackageCompileSettings.Destination
    ) throws -> Set<String> {
        var result = Set<String>()
        func addMap(_ file: URL, fallback: String) throws {
            if FileManager.default.fileExists(atPath: file.path) {
                let contents = try String(contentsOf: file, encoding: .utf8)
                result.formUnion(
                    try NativeClangModuleMap(contents).modules.map { $0.name.components(separatedBy: ".")[0] })
            } else {
                result.insert(fallback)
            }
        }
        for entry in try NativeSwiftPackageTargets.list(
            [product], package: package, graph: graph, platform: destination.manifestPlatform, allowAliases: true)
        {
            let target = entry.target
            let name = entry.moduleName
            let kind = target["type"] as? String ?? "regular"
            if kind == "binary" {
                let sdk = try graph.binary(target, package: entry.package)
                guard
                    let slice = sdk.slices.first(where: {
                        $0.platform == destination.platform && $0.variant == destination.variant
                            && $0.architectures.contains(destination.architecture)
                    })
                else { continue }
                if slice.library.pathExtension == "framework" {
                    try addMap(
                        slice.library.appendingPathComponent("Modules/module.modulemap"),
                        fallback: slice.library.deletingPathExtension().lastPathComponent)
                } else if let headers = slice.headers {
                    try addMap(headers.appendingPathComponent("module.modulemap"), fallback: name)
                }
                continue
            }
            let directory = try graph.targetDirectory(target, package: entry.package)
            let headers = directory.appendingPathComponent(
                target["publicHeadersPath"] as? String ?? (kind == "system" ? "." : "include"))
            try addMap(headers.appendingPathComponent("module.modulemap"), fallback: name)
        }
        return result
    }
}
