import Foundation

enum NativeBuildSetting {
    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    static func path(_ value: String) -> String {
        value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || value.contains("\"") || value.contains("\\")
            ? quoted(value) : value
    }
}

extension NativeXcode {
    func publicHeaderDirectory(_ platform: String) -> String {
        "Pods/Headers/Public" + (platformNames.count > 1 ? "/" + platform : "")
    }
    func publicHeaderSetting(_ platform: String) -> String {
        "$(PODS_ROOT)" + publicHeaderDirectory(platform).dropFirst(4)
    }

    func nativeDependencies(_ target: [String: Any], search: Bool = false) -> [[String: Any]] {
        target[search ? "search_dependencies" : "dependencies"] as? [[String: Any]] ?? []
    }
    func dependencyEnabled(_ dependency: NativeDependency, configuration: String) -> Bool {
        guard dependency.options["configurations"] != nil else { return true }
        return nativeStrings(dependency.options["configurations"]).contains {
            $0.caseInsensitiveCompare(configuration) == .orderedSame
        }
    }
    func conditionalEmbeds(
        _ roots: Set<String>, configured: [String: Set<String>], platform: String, target: String, user: NativePBX
    ) throws {
        let key = "swiftpods:conditional-embed:" + target
        var phases = user.objects[target]?["buildPhases"] as? [String] ?? []
        phases.removeAll { $0 == NativePBX.identifier(key) }
        user.objects.removeValue(forKey: NativePBX.identifier(key))
        var inputs: [String] = []
        var outputs: [String] = []
        var commands: [String] = []
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        for product in products
        where productRoots[product] != nil && matchesProduct(product, roots: roots, platform: platform) {
            guard let producer = graph.objects.values.first(where: { $0["productReference"] as? String == product }),
                let list = producer["buildConfigurationList"] as? String,
                let config = (graph.objects[list]?["buildConfigurations"] as? [String])?.first,
                (graph.objects[config]?["buildSettings"] as? [String: Any])?["MACH_O_TYPE"] as? String == "mh_dylib",
                let name = graph.objects[product]?["path"] as? String
            else { continue }
            let enabled = configured.filter { $0.value.contains(productRoots[product] ?? "") }.keys.sorted()
            guard !enabled.isEmpty else { continue }
            let input = productBuildPath(product)
            let source = ["BUILT_PRODUCTS_DIR", "BUILD_DIR", "CONFIGURATION", "EFFECTIVE_PLATFORM_NAME"].reduce(input) {
                $0.replacingOccurrences(of: "$(" + $1 + ")", with: "${" + $1 + ":-}")
            }
            inputs.append(input)
            outputs.append("$(TARGET_BUILD_DIR)/$(FRAMEWORKS_FOLDER_PATH)/" + name)
            commands.append(
                "case \"${CONFIGURATION}\" in\n" + enabled.map(quote).joined(separator: "|") + ")\n  /usr/bin/ditto \""
                    + source + "\" \"${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/" + name
                    + "\"\n  if [ \"${CODE_SIGNING_ALLOWED:-NO}\" != NO ] && [ -n \"${EXPANDED_CODE_SIGN_IDENTITY:-}\" ]; then /usr/bin/codesign --force --sign \"${EXPANDED_CODE_SIGN_IDENTITY}\" --preserve-metadata=identifier,entitlements \"${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/"
                    + name + "\"; fi\n  ;;\n*) /bin/rm -rf \"${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/" + name
                    + "\" ;;\nesac")
        }
        if !commands.isEmpty {
            phases.append(
                user.add(
                    key,
                    [
                        "isa": "PBXShellScriptBuildPhase", "name": "[SwiftPods] Embed Conditional Frameworks",
                        "buildActionMask": "2147483647", "runOnlyForDeploymentPostprocessing": "0", "files": [],
                        "shellPath": "/bin/sh", "inputPaths": inputs, "outputPaths": outputs,
                        "shellScript": "set -eu\nmkdir -p \"${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}\"\n"
                            + commands.joined(separator: "\n") + "\n",
                    ]))
        }
        user.objects[target]?["buildPhases"] = phases
    }
}
