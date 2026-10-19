import Foundation

/// One command resolves SDK aliases in its selected developer environment.
/// Cache tool lookups, while reading bundle metadata afresh for each evaluation.
final class NativeSDKContext {
    typealias Locator = (String, [String: String]) -> URL?
    private let environment: [String: String]
    private let locate: Locator
    private let providedSettingTypes: NativeBuildSettingTypes?
    private lazy var selectedSettingTypes = NativeBuildSettingTypes(environment: environment)
    var settingTypes: NativeBuildSettingTypes {
        if let providedSettingTypes { return providedSettingTypes }
        return environment["DEVELOPER_DIR"] == ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            ? .current : selectedSettingTypes
    }
    private var locations: [String: URL] = [:]
    private var unavailable = Set<String>()

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment, locate: Locator? = nil,
        settingTypes: NativeBuildSettingTypes? = nil
    ) {
        providedSettingTypes = settingTypes
        self.environment = environment
        self.locate = locate ?? Self.directory
    }

    func name(_ value: String, relativeTo sourceRoot: URL? = nil) -> String {
        if let resolved = canonicalName(value, relativeTo: sourceRoot) { return resolved }
        guard !value.contains("$"), !value.utf8.contains(0), !value.contains("\""), !value.contains("'") else {
            return ""
        }
        let name = NativeBuildSettings.sdkName(value)
        return Self.validName(name) ? name : ""
    }

    func canonicalName(_ value: String, relativeTo sourceRoot: URL? = nil) -> String? {
        guard !value.utf8.contains(0) else { return nil }
        if value.utf8.first == 47 {
            return Self.bundleName(URL(fileURLWithPath: value, isDirectory: true))
        }
        let relative = sourceRoot.map {
            URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: $0.path, isDirectory: true))
                .standardizedFileURL
        }
        // SDKROOT paths belong to the selected project's source root, not the CLI cwd.
        if value.unicodeScalars.contains("/") || value.lowercased().hasSuffix(".sdk"),
            let relative, let name = Self.bundleName(relative)
        {
            return name
        }
        // An evaluated literal path may contain macro-looking filesystem characters.
        guard !value.contains("$("), !value.contains("${") else { return nil }
        // Quotes remain literal characters and must not select a basename on failure.
        guard Self.validName(value) else { return relative.flatMap(Self.bundleName) }
        let directory: URL?
        if let cached = locations[value] {
            directory = cached
        } else if !unavailable.contains(value), let found = locate(value, environment) {
            locations[value] = found
            directory = found
        } else {
            unavailable.insert(value)
            directory = nil
        }
        return directory.flatMap(Self.bundleName) ?? relative.flatMap(Self.bundleName)
    }

    private static func bundleName(_ directory: URL) -> String? {
        for filename in ["SDKSettings.json", "SDKSettings.plist"] {
            let file = directory.appendingPathComponent(filename)
            guard let data = try? Data(contentsOf: file) else { continue }
            let object: Any?
            if filename.hasSuffix(".json") {
                object = try? JSONSerialization.jsonObject(with: data)
            } else {
                object = try? PropertyListSerialization.propertyList(from: data, format: nil)
            }
            guard let object, (try? NativeDictionaryKeys.validate(object, file: file.path, stage: "analyze")) != nil,
                let settings = object as? [String: Any], let canonical = settings["CanonicalName"] as? String,
                Self.validName(canonical)
            else { continue }
            return canonical.lowercased()
        }
        return nil
    }

    private static func validName(_ value: String) -> Bool {
        value.range(of: #"\A[A-Za-z][A-Za-z0-9._-]*\z"#, options: .regularExpression) != nil
    }

    private static func directory(_ name: String, environment: [String: String]) -> URL? {
        guard
            let result = try? ToolProcess.run(
                "/usr/bin/xcrun", ["--sdk", name, "--show-sdk-path"], environment: environment), result.status == 0,
            let output = String(data: result.output, encoding: .utf8)
        else { return nil }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.utf8.first == 47, !path.utf8.contains(0) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
