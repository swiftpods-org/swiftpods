import Foundation

/// Filesystem paths and OS command strings cannot represent embedded NUL bytes.
enum NativeSpecPaths {
    private static let fileAttributes: Set<String> = [
        "source_files", "exclude_files", "resources", "preserve_paths", "public_header_files",
        "private_header_files", "project_header_files", "vendored_frameworks", "vendored_libraries",
        "header_dir", "header_mappings_dir", "prefix_header_file", "module_map", "readme", "requires_arc",
    ]
    static func validatePath(_ value: String, stage: String = "resolve", file: String? = nil) throws {
        guard !value.utf8.contains(0) else {
            throw Diagnostic("SP-SPEC-PATH", stage: stage, "Paths and file patterns cannot contain NUL", file: file)
        }
    }

    static func validate(_ key: String, value: Any, file: String?) throws {
        func strings(_ value: Any) throws {
            for item in value as? [Any] ?? [value] {
                if let text = item as? String { try validatePath(text, file: file) }
            }
        }
        if fileAttributes.contains(key) { try strings(value) }
        if key == "resource_bundles" {
            for (name, patterns) in value as? [String: Any] ?? [:] {
                try validatePath(name, file: file)
                try strings(patterns)
            }
        }
        if key == "license", let path = (value as? [String: Any])?["file"] as? String {
            try validatePath(path, file: file)
        }
        if key == "prepare_command", let script = value as? String, script.utf8.contains(0) {
            throw Diagnostic("SP-SPEC-SCRIPT", stage: "resolve", "prepare_command cannot contain NUL", file: file)
        }
    }
}
