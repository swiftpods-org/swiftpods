import Foundation

/// A binary's filename identifies its link product, independently of the
/// Clang and Swift modules declared by its selected public interface.
enum NativeVendorModules {
    static func names(_ slice: NativeVendorSlice) throws -> Set<String> {
        let framework = slice.library.pathExtension == "framework"
        let modules = framework ? slice.library.appendingPathComponent("Modules") : nil
        let map = modules?.appendingPathComponent("module.modulemap")
            ?? slice.headers?.appendingPathComponent("module.modulemap")
        var names = Set<String>()
        if let map, FileManager.default.fileExists(atPath: map.path) {
            names.formUnion(
                try NativeClangModuleMap(String(contentsOf: map, encoding: .utf8)).modules.map {
                    $0.name.components(separatedBy: ".")[0]
                })
        }
        if let modules, FileManager.default.fileExists(atPath: modules.path) {
            for entry in try FileManager.default.contentsOfDirectory(at: modules, includingPropertiesForKeys: nil)
            where entry.pathExtension == "swiftmodule" {
                names.insert(entry.deletingPathExtension().lastPathComponent)
            }
        }
        return names
    }
}
