import Foundation

/// Compiler-only maps use the same immutable public headers as HEADER_SEARCH_PATHS.
/// Xcode's generated Clang maps can point at a different SourcePackages checkout.
final class NativeSwiftPackageModuleMaps {
    let directory: URL
    private(set) var files: [String: Data] = [:]

    init(directory: URL) { self.directory = directory }

    func generated(name: String, headers: URL, identity: String) throws -> URL {
        let module = Self.moduleName(name)
        let entries = try FileManager.default.contentsOfDirectory(at: headers, includingPropertiesForKeys: [.isDirectoryKey])
        let directories = try entries.filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
        let top = headers.appendingPathComponent(module + ".h")
        let nested = headers.appendingPathComponent(module + "/" + module + ".h")
        let umbrella: URL
        let directive: String
        if FileManager.default.fileExists(atPath: top.path) {
            guard directories.isEmpty else {
                throw Diagnostic("SP-SPM-MODULEMAP", stage: "integrate", "Umbrella header has sibling directories", file: top.path)
            }
            umbrella = top
            directive = "umbrella header"
        } else if FileManager.default.fileExists(atPath: nested.path) {
            guard directories.count == 1, !entries.contains(where: { $0.pathExtension == "h" }) else {
                throw Diagnostic("SP-SPM-MODULEMAP", stage: "integrate", "Nested umbrella has sibling headers or directories", file: nested.path)
            }
            umbrella = nested
            directive = "umbrella header"
        } else {
            umbrella = headers
            directive = "umbrella"
        }
        let filename = digest(Data(identity.utf8)) + ".modulemap"
        let path = directory.appendingPathComponent(filename)
        let relative = NativePath.relativePath(of: umbrella, to: directory)
        files[filename] = Data(("module " + module + " {\n  " + directive + " " + NativeBuildSetting.quoted(relative) + "\n  export *\n}\n").utf8)
        return path
    }

    static func moduleName(_ name: String) -> String {
        NativeSwiftPackageC99.moduleName(name)
    }

    func save() throws {
        let receipt = directory.appendingPathComponent("module-maps.json")
        let previous = (try? readObject(receipt))?["files"] as? [String: String] ?? [:]
        for (filename, hash) in previous {
            guard filename.range(of: #"\A[0-9a-f]{64}\.modulemap\z"#, options: .regularExpression) != nil else {
                throw Diagnostic("SP-SPM-MODULEMAP", stage: "integrate", "Invalid generated module map receipt", file: receipt.path)
            }
            let path = directory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: path.path), try FileFingerprint.file(path) != hash {
                throw Diagnostic("SP-SPM-CONFLICT", stage: "integrate", "Generated package module map was edited outside SwiftPods", file: path.path)
            }
            if files[filename] == nil { try? FileManager.default.removeItem(at: path) }
        }
        guard !files.isEmpty else {
            if FileManager.default.fileExists(atPath: receipt.path) { try FileManager.default.removeItem(at: receipt) }
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (filename, data) in files {
            let path = directory.appendingPathComponent(filename)
            guard previous[filename] != nil || !FileManager.default.fileExists(atPath: path.path) else {
                throw Diagnostic("SP-SPM-CONFLICT", stage: "integrate", "Package module map path already exists", file: path.path)
            }
            try data.writeIfChanged(to: path, options: .atomic)
        }
        try jsonData(["files": files.mapValues { digest($0) }]).writeIfChanged(to: receipt, options: .atomic)
    }
}
