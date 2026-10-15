import Foundation

struct NativeValidation {
    let bundle: RuntimeBundle
    let environment: [String: String]
    let overrides: [String: String]

    func run(action: String, arguments: [String], project: URL) throws -> [String: Any] {
        var args = arguments
        let sources = try CommandOptions.take("--sources", from: &args)
        let platforms = try CommandOptions.take("--platforms", from: &args)
        let swiftVersion = try CommandOptions.take("--swift-version", from: &args)
        let flags = Set(args.filter { $0.hasPrefix("-") })
        let allowed = Set(["--quick", "--allow-warnings", "--no-clean", "--verbose", "--silent", "--private", "--use-libraries", "--use-modular-headers", "--skip-tests", "--fail-fast", "--no-ansi", "--ansi"])
        guard flags.isSubset(of: allowed) else { throw Diagnostic("SP-CLI-ARGUMENT", stage: "lint", "Unknown lint option: " + flags.subtracting(allowed).sorted().joined(separator: ", ")) }
        args.removeAll { $0.hasPrefix("-") }
        let paths: [URL]
        if args.isEmpty {
            paths = try FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasSuffix(".podspec") || $0.lastPathComponent.hasSuffix(".podspec.json") }.sorted { $0.path < $1.path }
        } else { paths = args.map { URL(fileURLWithPath: $0, relativeTo: project).standardizedFileURL } }
        guard !paths.isEmpty else { throw Diagnostic("SP-SPEC-MISSING", stage: "lint", "No podspec found") }
        let dsl = try NativeDSL(bundle: bundle, environment: environment, directory: project, overrides: overrides)
        var reports: [[String: Any]] = [], errors: [[String: Any]] = []
        for path in paths {
          do {
            let errorCount = errors.count
            let data = try path.pathExtension == "json" ? readObject(path) : dsl.object("spec", ["path": path.path])
            let spec = try NativeSpec(data: data)
            var warnings = try Self.metadata(spec, privateSpec: flags.contains("--private"))
            if !flags.contains("--allow-warnings"), !warnings.isEmpty { throw Diagnostic("SP-LINT-WARNINGS", stage: "lint", warnings.joined(separator: "; "), file: path.path) }
            var built: [String] = [], tested: [String] = [], artifacts: [String] = []
            if !flags.contains("--quick") {
                let known = ["osx", "ios", "tvos", "watchos", "visionos"]
                let declared = Set((data["platforms"] as? [String: Any] ?? [:]).keys).union(known.filter { data[$0] != nil })
                let selected = platforms.map { $0.split(separator: ",").map(String.init) } ?? (declared.isEmpty ? known : known.filter(declared.contains))
                guard !selected.isEmpty, selected.allSatisfy(known.contains) else { throw Diagnostic("SP-LINT-PLATFORM", stage: "lint", "Unknown or empty lint platforms") }
                for platform in selected {
                  do {
                    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("swiftpods-lint-" + UUID().uuidString)
                    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
                    if flags.contains("--no-clean") { artifacts.append(workspace.path) }
                    defer { if !flags.contains("--no-clean") { try? FileManager.default.removeItem(at: workspace) } }
                    let root = workspace.appendingPathComponent("Library")
                    if action == "lib" {
                        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                        // A local lint must not execute prepare_command against the user's checkout.
                        for entry in try FileManager.default.contentsOfDirectory(at: path.deletingLastPathComponent(), includingPropertiesForKeys: nil) where ![".git", ".build", "Pods", ".swiftpods", "dist"].contains(entry.lastPathComponent) {
                            try FileManager.default.copyItem(at: entry, to: root.appendingPathComponent(entry.lastPathComponent))
                        }
                        try jsonData(data).write(to: root.appendingPathComponent(spec.name + ".podspec.json"), options: .atomic)
                    }
                    let fallback = ["osx": "13.0", "ios": "15.0", "tvos": "15.0", "watchos": "8.0", "visionos": "1.0"][platform]!
                    let minimum = (data["platforms"] as? [String: Any])?[platform] as? String ?? (data[platform] as? [String: String])?["deployment_target"] ?? fallback
                    let selection: String
                    if action == "lib" { selection = ", :path => " + NativeLock.quote(root.path) }
                    else { selection = ", :podspec => " + NativeLock.quote(path.path) }
                    var declaration = "platform :" + platform + ", " + NativeLock.quote(minimum) + "\n"
                    if !flags.contains("--use-libraries") { declaration += "use_frameworks!\n" }
                    if flags.contains("--use-modular-headers") { declaration += "use_modular_headers!\n" }
                    if let swiftVersion {
                        declaration += "supports_swift_versions " + NativeLock.quote("= " + swiftVersion) + "\n"
                        declaration += "post_install do |installer|\n installer.pods_project.targets.each do |target|\n target.build_configurations.each { |config| config.build_settings['SWIFT_VERSION'] = " + NativeLock.quote(swiftVersion) + " }\n end\nend\n"
                    }
                    for source in sources?.split(separator: ",").map(String.init) ?? [] { declaration += "source " + NativeLock.quote(source) + "\n" }
                    declaration += "target 'Lint' do\n pod " + NativeLock.quote(spec.name) + selection
                    if !flags.contains("--skip-tests"), let tests = data["testspecs"] as? [[String: Any]], !tests.isEmpty { declaration += ", :testspecs => [" + tests.compactMap { $0["name"] as? String }.map(NativeLock.quote).joined(separator: ", ") + "]" }
                    declaration += "\nend\n"
                    try Data(declaration.utf8).write(to: workspace.appendingPathComponent("Podfile"))
                    let installed = NativeEngine(bundle: bundle).run(arguments: ["install", "--no-integrate", "--project-directory", workspace.path], environment: environment, machine: true, overrides: overrides)
                    guard installed.status == 0 else { throw Diagnostic("SP-LINT-INSTALL", stage: "lint", "Lint installation failed for " + platform, file: path.path) }
                    let sdk = ["osx": "macosx", "ios": "iphonesimulator", "tvos": "appletvsimulator", "watchos": "watchsimulator", "visionos": "xrsimulator"][platform]!
                    let build = try ToolProcess.run("/usr/bin/xcrun", ["xcodebuild", "-project", workspace.appendingPathComponent("Pods/Pods.xcodeproj").path, "-alltargets", "-configuration", "Release", "-sdk", sdk, "build", "CODE_SIGNING_ALLOWED=NO", "GCC_TREAT_WARNINGS_AS_ERRORS=" + (flags.contains("--allow-warnings") ? "NO" : "YES"), "SWIFT_TREAT_WARNINGS_AS_ERRORS=" + (flags.contains("--allow-warnings") ? "NO" : "YES"), "SYMROOT=" + workspace.appendingPathComponent("products").path], directory: workspace, environment: environment)
                    warnings += String(decoding: build.output + build.error, as: UTF8.self).components(separatedBy: .newlines).filter { $0.contains("warning:") }
                    let log = workspace.appendingPathComponent("build.log")
                    try (build.output + build.error).write(to: log)
                    guard build.status == 0 else { throw Diagnostic("SP-LINT-BUILD", stage: "lint", "Build failed for " + platform + ": " + String(decoding: build.output + build.error, as: UTF8.self).suffix(6000), file: path.path) }
                    built.append(platform)
                    if !flags.contains("--skip-tests") {
                        for test in data["testspecs"] as? [[String: Any]] ?? [] {
                            guard let name = test["name"] as? String else { continue }
                            let full = spec.name + "/" + name
                            let attrs = try spec.supplementaryAttributes(full, platform: platform)
                            if let supported = attrs["platforms"] as? [String: Any], !supported.isEmpty, supported[platform] == nil { continue }
                            let type = try spec.testType(full, platform: platform)
                            let scheme = spec.name + "-" + type.label + "-" + name.replacingOccurrences(of: "/", with: "-")
                            let destination = try testDestination(platform)
                            let arguments = ["xcodebuild", "-project", workspace.appendingPathComponent("Pods/Pods.xcodeproj").path, "-scheme", scheme, "-configuration", "Debug", "-sdk", sdk, "-destination", destination, "test", "CODE_SIGNING_ALLOWED=" + (platform == "osx" ? "NO" : "YES"), "CODE_SIGN_IDENTITY=-", "GCC_TREAT_WARNINGS_AS_ERRORS=" + (flags.contains("--allow-warnings") ? "NO" : "YES"), "SWIFT_TREAT_WARNINGS_AS_ERRORS=" + (flags.contains("--allow-warnings") ? "NO" : "YES"), "SYMROOT=" + workspace.appendingPathComponent("products").path]
                            let run = try ToolProcess.run("/usr/bin/xcrun", arguments, directory: workspace, environment: environment)
                            try (run.output + run.error).write(to: workspace.appendingPathComponent(scheme + ".test.log"))
                            guard run.status == 0 else { throw Diagnostic("SP-LINT-TEST", stage: "lint", "Tests failed for " + scheme + ": " + String(decoding: run.output + run.error, as: UTF8.self).suffix(6000), file: path.path) }
                            tested.append(platform + ":" + scheme)
                        }
                    }
                  } catch {
                    let diagnostic = error as? Diagnostic ?? Diagnostic("SP-LINT-ERROR", stage: "lint", String(describing: error), file: path.path)
                    errors.append(["code": diagnostic.code, "message": diagnostic.message, "file": path.path, "platform": platform])
                    if flags.contains("--fail-fast") { break }
                  }
                }
            }
            reports.append(["name": spec.name, "version": spec.version.description, "path": path.path, "warnings": warnings, "built_platforms": built, "tested_schemes": tested, "artifacts": artifacts, "status": errors.count == errorCount ? "passed" : "failed", "validation": flags.contains("--quick") ? "metadata" : "metadata-build-and-tests"])
          } catch {
            let diagnostic = error as? Diagnostic ?? Diagnostic("SP-LINT-ERROR", stage: "lint", String(describing: error), file: path.path)
            errors.append(["code": diagnostic.code, "message": diagnostic.message, "file": path.path])
            reports.append(["path": path.path, "status": "failed"])
          }
          if flags.contains("--fail-fast") && !errors.isEmpty { break }
        }
        return ["status": errors.isEmpty ? "passed" : "failed", "specifications": reports, "errors": errors]
    }
    private func testDestination(_ platform: String) throws -> String {
        if platform == "osx" { return "platform=macOS" }
        let names = ["ios": "iOS", "tvos": "tvOS", "watchos": "watchOS", "visionos": "xrOS"]
        guard let name = names[platform] else { throw Diagnostic("SP-LINT-DESTINATION", stage: "lint", "Unsupported test platform") }
        let result = try ToolProcess.run("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "-j"], environment: environment)
        guard result.status == 0, let data = try JSONSerialization.jsonObject(with: result.output) as? [String: Any], let runtimes = data["devices"] as? [String: [[String: Any]]] else { throw Diagnostic("SP-LINT-DESTINATION", stage: "lint", "Cannot enumerate test simulators") }
        let devices = runtimes.filter { $0.key.contains("." + name + "-") }.sorted { $0.key < $1.key }.flatMap(\.value).filter { $0["isAvailable"] as? Bool == true }
        guard let device = devices.first, let id = device["udid"] as? String else { throw Diagnostic("SP-LINT-DESTINATION", stage: "lint", "No available " + name + " test simulator") }
        return "id=" + id
    }
    static func metadata(_ spec: NativeSpec, privateSpec: Bool = false) throws -> [String] {
        let data = spec.data
        for key in ["summary", "homepage", "source"] where data[key] == nil { throw Diagnostic("SP-LINT-METADATA", stage: "lint", "Missing required attribute: " + key, file: spec.name) }
        guard data["authors"] != nil || data["author"] != nil else { throw Diagnostic("SP-LINT-METADATA", stage: "lint", "Missing authors", file: spec.name) }
        guard let summary = data["summary"] as? String, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let homepage = data["homepage"] as? String, let url = URL(string: homepage), ["http", "https"].contains(url.scheme ?? ""),
              let source = data["source"] as? [String: Any], ["git", "http", "svn", "hg"].filter({ source[$0] != nil }).count == 1 else { throw Diagnostic("SP-LINT-METADATA", stage: "lint", "Invalid summary, homepage or source", file: spec.name) }
        var warnings: [String] = []
        if data["license"] == nil { warnings.append("Missing license") }
        if summary.count > 140 { warnings.append("Summary exceeds 140 characters") }
        if data["deprecated"] as? Bool == true { warnings.append("Specification is deprecated") }
        if !privateSpec, source["git"] != nil, source["tag"] == nil { warnings.append("Git sources should specify a tag") }
        if !privateSpec, let url = source["git"] as? String, url.hasPrefix("http://") { warnings.append("Git sources should use HTTPS") }
        return warnings
    }
}
