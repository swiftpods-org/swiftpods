import Foundation

enum NativeConsumerResourceOutputs {
    /// Match the outputs of Xcode's resource compilers, retaining localization directories.
    static func paths(_ inputs: [URL]) throws -> [String] {
        var directories: [URL] = []
        var result = Set<String>()
        for input in Set(try NativeResources.expandedPaths(inputs)).sorted(by: { $0.path < $1.path }) {
            if directories.contains(where: { NativePath.isDescendant(input, of: $0) }) { continue }
            let directory = (try input.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
            if input.pathExtension == "lproj", directory { continue }
            if directory { directories.append(input) }
            if input.pathExtension == "xcstrings" {
                let output = URL(fileURLWithPath: "/SwiftPodsResourceOutputs")
                let process = try ToolProcess.run(
                    "/usr/bin/xcrun",
                    [
                        "xcstringstool", "compile", input.path, "--output-directory", output.path, "--dry-run",
                    ])
                guard process.status == 0, let text = String(data: process.output, encoding: .utf8) else {
                    throw Diagnostic(
                        "SP-XCODE-RESOURCE", stage: "integrate", "Cannot enumerate string catalog outputs",
                        file: input.path)
                }
                for line in text.split(whereSeparator: \.isNewline) {
                    let path = URL(fileURLWithPath: String(line))
                    guard let components = NativePath.relativeComponents(of: path, to: output), !components.isEmpty
                    else {
                        throw Diagnostic(
                            "SP-XCODE-RESOURCE", stage: "integrate", "String catalog output escapes its directory",
                            file: input.path)
                    }
                    result.insert(components.joined(separator: "/"))
                }
                continue
            }
            let extensions = [
                "xib": "nib", "storyboard": "storyboardc", "xcdatamodel": "mom",
                "xcdatamodeld": "momd", "xcmappingmodel": "cdm", "mlmodel": "mlmodelc", "mlpackage": "mlmodelc",
            ]
            let name =
                extensions[input.pathExtension].map { input.deletingPathExtension().lastPathComponent + "." + $0 }
                ?? input.lastPathComponent
            let locale = input.deletingLastPathComponent()
            result.insert(locale.pathExtension == "lproj" ? locale.lastPathComponent + "/" + name : name)
        }
        return result.sorted()
    }
}
