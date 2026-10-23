import Foundation

/// Inspect only the destination's public interface; Xcode resolves the actual SDK slice.
struct NativeLintVendorInterface {
    let clang: [NativeClangModuleMap.Language: String]
    let swift: String
    var cxx: Bool { clang.keys.contains(where: \.cxx) }

    init(selection: NativeLibraryFiles, platform: String) throws {
        var clangImports: [NativeClangModuleMap.Language: Set<String>] = [:]
        var swiftImports = Set<String>()
        let paths = try Set(selection.paths("vendored_frameworks") + selection.paths("vendored_libraries"))
        let variant = platform == "osx" ? "device" : "simulator"
        for path in paths.sorted(by: { $0.path < $1.path }) {
            let sdk = try NativeVendorSDK(path)
            for slice in sdk.slices
            where (slice.platform == platform || slice.platform == "unknown")
                && (slice.variant == variant || slice.variant == "unknown")
            {
                let modules = slice.library.appendingPathComponent("Modules").resolvingSymlinksInPath()
                if sdk.isFramework {
                    for module in (try? FileManager.default.contentsOfDirectory(
                        at: modules, includingPropertiesForKeys: nil)) ?? []
                    where module.pathExtension == "swiftmodule" {
                        swiftImports.insert("import " + module.deletingPathExtension().lastPathComponent + "\n")
                    }
                }
                let headers = (sdk.isFramework ? slice.library.appendingPathComponent("Headers") : slice.headers)?
                    .resolvingSymlinksInPath()
                let files = headers.flatMap {
                    FileManager.default.enumerator(at: $0, includingPropertiesForKeys: [.isRegularFileKey])
                }?.allObjects.compactMap { $0 as? URL }.filter {
                    NativeFileSelection.headers.contains($0.pathExtension)
                        && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                } ?? []
                let cxx = files.contains { ["hh", "hpp", "hxx", "ipp", "tpp"].contains($0.pathExtension) }
                let map = sdk.isFramework
                    ? modules.appendingPathComponent("module.modulemap") : headers?.appendingPathComponent("module.modulemap")
                if let map, FileManager.default.fileExists(atPath: map.path) {
                    let modules = try NativeClangModuleMap(String(contentsOf: map, encoding: .utf8)).modules
                    for module in modules {
                        clangImports[module.language(cxx: cxx), default: []].insert(module.importDirective)
                    }
                    if !modules.isEmpty { continue }
                }
                guard let headers else { continue }
                let umbrella = files.first { $0.lastPathComponent == slice.library.deletingPathExtension().lastPathComponent + ".h" }
                for file in umbrella.map({ [$0] }) ?? files {
                    let prefix = sdk.isFramework ? slice.library.deletingPathExtension().lastPathComponent + "/" : ""
                    let contents = "#import <" + prefix + NativePath.relativePath(of: file, to: headers) + ">\n"
                    clangImports[cxx ? .mm : .m, default: []].insert(contents)
                }
            }
        }
        clang = clangImports.mapValues { $0.sorted().joined() }
        swift = swiftImports.sorted().joined()
    }
}
