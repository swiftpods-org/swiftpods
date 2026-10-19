import Foundation

/// Declaration types belong to the selected developer installation, not to the
/// spelling or value of a user-defined variable.
struct NativeBuildSettingTypes {
    static let current = NativeBuildSettingTypes(environment: ProcessInfo.processInfo.environment)

    private static let scalarKinds: Set<String> = [
        "bool", "Bool", "boolean", "Boolean", "string", "String", "path", "Path", "enum", "Enumeration",
        "CodeSignIdentity", "CodeSignStyle", "CompilerVersion", "DevelopmentTeam", "ProvisioningProfile",
        "ProvisioningProfileSpecifier",
    ]
    private static let listKinds: Set<String> = [
        "stringlist", "StringList", "pathlist", "PathList", "pathOrderedSet", "PathOrderedSet", "OpenCLArchitectures",
    ]
    private static let coreScalars: Set<String> = [
        "SDKROOT", "SRCROOT", "SOURCE_ROOT", "PROJECT_DIR", "PROJECT_NAME", "PROJECT_FILE_PATH", "TARGET_NAME",
        "CONFIGURATION", "TOOLCHAIN_DIR", "SWIFT_VERSION", "MACOSX_DEPLOYMENT_TARGET", "IPHONEOS_DEPLOYMENT_TARGET",
        "TVOS_DEPLOYMENT_TARGET", "WATCHOS_DEPLOYMENT_TARGET", "XROS_DEPLOYMENT_TARGET",
    ]
    private let scalars: Set<String>
    private let invalid: [String: String]
    private let conflicts: [String: String]

    init(specifications: [URL]) {
        var scalars = Self.coreScalars
        var lists = Set<String>()
        var origins: [String: String] = [:]
        var inferred = Set<String>()
        var invalid: [String: String] = [:]
        for file in specifications.sorted(by: { $0.path < $1.path }) {
            guard let data = try? Data(contentsOf: file),
                let value = try? PropertyListSerialization.propertyList(from: data, format: nil)
            else { continue }
            let domains = (value as? [[String: Any]]) ?? (value as? [String: Any]).map { [$0] } ?? []
            for domain in domains {
                for field in ["Options", "Properties"] {
                    for option in domain[field] as? [[String: Any]] ?? [] {
                        guard let name = option["Name"] as? String, !name.isEmpty else { continue }
                        guard let kind = option["Type"] as? String else {
                            if option["Type"] == nil { inferred.insert(name) } else { invalid[name] = file.path }
                            continue
                        }
                        if Self.scalarKinds.contains(kind) {
                            scalars.insert(name)
                        } else if Self.listKinds.contains(kind) {
                            lists.insert(name)
                        } else {
                            invalid[name] = file.path
                            continue
                        }
                        origins[name] = file.path
                    }
                }
            }
        }
        // An untyped option inherits an existing declaration, or defaults to a
        // string. It does not turn an already declared list into a string.
        scalars.formUnion(inferred.subtracting(lists))
        self.invalid = invalid
        self.scalars = scalars
        conflicts = Dictionary(uniqueKeysWithValues: scalars.intersection(lists).map { ($0, origins[$0] ?? $0) })
    }

    init(environment: [String: String]) {
        let developer: URL?
        if let result = try? ToolProcess.run("/usr/bin/xcrun", ["--find", "xcodebuild"], environment: environment),
            result.status == 0, let output = String(data: result.output, encoding: .utf8)
        {
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let tool = URL(fileURLWithPath: path).standardizedFileURL
            // Do not mistake /usr/bin/xcodebuild's command-line-tools stub for Xcode.
            developer =
                path.utf8.first == 47 && !path.utf8.contains(0) && tool.path != "/usr/bin/xcodebuild"
                    && tool.path.hasSuffix("/usr/bin/xcodebuild")
                ? tool.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() : nil
        } else {
            developer = nil
        }
        self.init(developerDirectory: developer)
    }

    init(developerDirectory: URL?) {
        guard let developerDirectory else {
            self.init(specifications: [])
            return
        }
        let contents = developerDirectory.deletingLastPathComponent()
        var roots = [
            contents.appendingPathComponent("SharedFrameworks/XCBuild.framework/Versions/A/PlugIns"),
            developerDirectory.appendingPathComponent("Library/Xcode/Specifications"),
        ]
        let platforms = developerDirectory.appendingPathComponent("Platforms")
        for platform in (try? FileManager.default.contentsOfDirectory(at: platforms, includingPropertiesForKeys: nil))
            ?? []
        where platform.pathExtension == "platform" {
            roots.append(platform.appendingPathComponent("Developer/Library/Xcode/Specifications"))
        }
        var files = Set<URL>()
        for root in roots {
            guard
                let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
            else { continue }
            for case let file as URL in entries where file.pathExtension == "xcspec" {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                files.insert(file)
            }
        }
        self.init(specifications: Array(files))
    }

    func isScalar(_ name: String) throws -> Bool {
        if let file = invalid[name] {
            throw Diagnostic(
                "SP-XCODE-SETTING-TYPE", stage: "analyze", "Unsupported declaration type for " + name, file: file)
        }
        if let file = conflicts[name] {
            throw Diagnostic(
                "SP-XCODE-SETTING-TYPE", stage: "analyze", "Conflicting string and list declarations for " + name,
                file: file)
        }
        return scalars.contains(name)
    }
}
