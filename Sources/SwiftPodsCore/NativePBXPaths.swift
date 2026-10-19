import Foundation

/// Validate path strings before Foundation turns NUL into a literal %00 name.
enum NativePBXPaths {
    static func validateObject(_ object: [String: Any], file: String?) throws {
        for key in ["path", "projectDirPath", "projectRoot"] {
            if let value = object[key] as? String, value.utf8.contains(0) {
                throw Diagnostic(
                    "SP-XCODE-PATH", stage: "analyze", "Project path fields cannot contain NUL", file: file)
            }
        }
    }

    static func validateGraph(_ objects: [String: [String: Any]], file: String?) throws {
        for object in objects.values { try validateObject(object, file: file) }
    }
}
