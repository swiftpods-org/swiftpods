import Foundation

struct NativeValidation {
    let bundle: RuntimeBundle
    let environment: [String: String]
    let overrides: [String: String]

    struct Options {
        let paths: [String]
        let sources: String?
        let platforms: String?
        let swiftVersion: String?
        let flags: Set<String>

        init(_ arguments: [String], additionalFlags: Set<String> = []) throws {
            var args = arguments
            sources = try CommandOptions.take("--sources", from: &args)
            platforms = try CommandOptions.take("--platforms", from: &args)
            swiftVersion = try CommandOptions.take("--swift-version", from: &args)
            let parsed = Set(args.filter { CommandOptions.hasOptionPrefix($0) })
            let allowed = Set([
                "--quick", "--allow-warnings", "--no-clean", "--verbose", "--silent", "--private", "--use-libraries",
                "--use-modular-headers", "--skip-tests", "--fail-fast", "--no-ansi", "--ansi",
            ]).union(additionalFlags)
            guard parsed.isSubset(of: allowed) else {
                throw Diagnostic(
                    "SP-CLI-ARGUMENT", stage: "lint",
                    "Unknown lint option: " + parsed.subtracting(allowed).sorted().joined(separator: ", "))
            }
            flags = parsed
            paths = args.filter { !CommandOptions.hasOptionPrefix($0) }
        }
    }

    func run(action: String, arguments: [String], project: URL) throws -> [String: Any] {
        let options = try Options(arguments)
        let args = options.paths
        let sources = options.sources
        let platforms = options.platforms
        let swiftVersion = options.swiftVersion
        let flags = options.flags
        let paths: [URL]
        if args.isEmpty {
            paths = try FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil).filter {
                $0.lastPathComponent.hasSuffix(".podspec") || $0.lastPathComponent.hasSuffix(".podspec.json")
            }.sorted { $0.path < $1.path }
        } else {
            paths = args.map { URL(fileURLWithPath: $0, relativeTo: project).standardizedFileURL }
        }
        guard !paths.isEmpty else { throw Diagnostic("SP-SPEC-MISSING", stage: "lint", "No podspec found") }
        let dsl = try NativeDSL(bundle: bundle, environment: environment, directory: project, overrides: overrides)
        var reports: [[String: Any]] = []
        var errors: [[String: Any]] = []
        for path in paths {
            do {
                let errorCount = errors.count
                let data = try path.pathExtension == "json" ? readObject(path) : dsl.object("spec", ["path": path.path])
                let spec = try NativeSpec(data: data)
                try spec.validateProfile()
                var warnings = try Self.metadata(spec, privateSpec: flags.contains("--private"))
                try Self.validateWarnings(warnings, allow: flags.contains("--allow-warnings"), file: path)
                var built: [String] = []
                var interfaces: [String] = []
                var tested: [String] = []
                var artifacts: [String] = []
                if !flags.contains("--quick") {
                    let known = ["osx", "ios", "tvos", "watchos", "visionos"]
                    let declared = Set((data["platforms"] as? [String: Any] ?? [:]).keys).union(
                        known.filter { data[$0] != nil })
                    let selected =
                        platforms.map { $0.split(separator: ",").map(String.init) }
                        ?? (declared.isEmpty ? known : known.filter(declared.contains))
                    guard !selected.isEmpty, selected.allSatisfy(known.contains) else {
                        throw Diagnostic("SP-LINT-PLATFORM", stage: "lint", "Unknown or empty lint platforms")
                    }
                    let selections = try NativeLintSelection.plan(
                        spec, platforms: selected, skipTests: flags.contains("--skip-tests"))
                    for selection in selections {
                        let platform = selection.platform
                        do {
                            let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
                                "swiftpods-lint-" + UUID().uuidString)
                            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
                            if flags.contains("--no-clean") { artifacts.append(workspace.path) }
                            defer {
                                if !flags.contains("--no-clean") { try? FileManager.default.removeItem(at: workspace) }
                            }
                            let root = workspace.appendingPathComponent("Library")
                            if action == "lib" {
                                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                                // A local lint must not execute prepare_command against the user's checkout.
                                for entry in try FileManager.default.contentsOfDirectory(
                                    at: path.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                                where ![".git", ".build", "Pods", ".swiftpods", "dist"].contains(
                                    entry.lastPathComponent)
                                {
                                    try FileManager.default.copyItem(
                                        at: entry, to: root.appendingPathComponent(entry.lastPathComponent))
                                }
                                try jsonData(data).write(
                                    to: root.appendingPathComponent(spec.name + ".podspec.json"), options: .atomic)
                            }
                            let minimum = selection.deployment
                            try NativeLintConsumer.create(in: workspace, platform: platform, minimum: minimum)
                            let sourceSelection: String
                            if action == "lib" {
                                sourceSelection = ", :path => " + NativeRubyString.quote(root.path)
                            } else {
                                sourceSelection = ", :podspec => " + NativeRubyString.quote(path.path)
                            }
                            var declaration =
                                "platform :" + platform + ", " + NativeRubyString.quote(minimum)
                                + "\nproject 'Lint.xcodeproj'\n"
                            if !flags.contains("--use-libraries") { declaration += "use_frameworks!\n" }
                            if flags.contains("--use-modular-headers") { declaration += "use_modular_headers!\n" }
                            if let swiftVersion {
                                declaration +=
                                    "supports_swift_versions " + NativeRubyString.quote("= " + swiftVersion) + "\n"
                                declaration +=
                                    "post_install do |installer|\n installer.pods_project.targets.each do |target|\n target.build_configurations.each { |config| config.build_settings['SWIFT_VERSION'] = "
                                    + NativeRubyString.quote(swiftVersion) + " }\n end\nend\n"
                            }
                            for source in sources?.split(separator: ",").map(String.init) ?? [] {
                                declaration += "source " + NativeRubyString.quote(source) + "\n"
                            }
                            declaration +=
                                "target 'Lint' do\n pod " + NativeRubyString.quote(selection.name) + sourceSelection
                            if !selection.tests.isEmpty {
                                declaration +=
                                    ", :testspecs => ["
                                    + selection.tests.map {
                                        NativePodName.relativeName(of: $0, to: selection.name) ?? $0
                                    }.map(
                                        NativeRubyString.quote
                                    ).joined(
                                        separator: ", ") + "]"
                            }
                            declaration += "\nend\n"
                            try Data(declaration.utf8).write(to: workspace.appendingPathComponent("Podfile"))
                            let installed = NativeEngine(bundle: bundle).run(
                                arguments: ["install", "--project-directory", workspace.path],
                                environment: environment, machine: true, overrides: overrides)
                            guard installed.status == 0 else {
                                throw Diagnostic(
                                    "SP-LINT-INSTALL", stage: "lint", "Lint installation failed for " + platform,
                                    file: path.path)
                            }
                            let sdk = [
                                "osx": "macosx", "ios": "iphonesimulator", "tvos": "appletvsimulator",
                                "watchos": "watchsimulator", "visionos": "xrsimulator",
                            ][platform]!
                            let build = try ToolProcess.run(
                                "/usr/bin/xcrun",
                                [
                                    "xcodebuild", "-project",
                                    workspace.appendingPathComponent("Pods/Pods.xcodeproj").path, "-alltargets",
                                    "-parallelizeTargets",
                                    "-configuration", "Release", "-sdk", sdk, "build", "CODE_SIGNING_ALLOWED=NO",
                                    "GCC_TREAT_WARNINGS_AS_ERRORS="
                                        + (flags.contains("--allow-warnings") ? "NO" : "YES"),
                                    "SWIFT_TREAT_WARNINGS_AS_ERRORS="
                                        + (flags.contains("--allow-warnings") ? "NO" : "YES"),
                                    "SYMROOT=" + workspace.appendingPathComponent("products").path,
                                ], directory: workspace, environment: environment)
                            let buildWarnings = Self.warnings(in: build)
                            warnings += buildWarnings
                            let log = workspace.appendingPathComponent("build.log")
                            try (build.output + build.error).write(to: log)
                            guard build.status == 0 else {
                                throw Diagnostic(
                                    "SP-LINT-BUILD", stage: "lint",
                                    "Build failed for " + platform + ": "
                                        + Self.failureOutput(build),
                                    file: path.path)
                            }
                            try Self.validateWarnings(buildWarnings, allow: flags.contains("--allow-warnings"), file: path)
                            try NativeLintConsumer.writeProbe(in: workspace, spec: spec, platform: platform)
                            let consumer = try ToolProcess.run(
                                "/usr/bin/xcrun",
                                [
                                    "xcodebuild", "-project",
                                    workspace.appendingPathComponent("Lint.xcodeproj").path,
                                    "-target", "Lint", "-parallelizeTargets", "-configuration", "Release", "-sdk", sdk,
                                    "build",
                                    "CODE_SIGNING_ALLOWED=NO",
                                    "GCC_TREAT_WARNINGS_AS_ERRORS="
                                        + (flags.contains("--allow-warnings") ? "NO" : "YES"),
                                    "SWIFT_TREAT_WARNINGS_AS_ERRORS="
                                        + (flags.contains("--allow-warnings") ? "NO" : "YES"),
                                    "SYMROOT=" + workspace.appendingPathComponent("products").path,
                                ], directory: workspace, environment: environment)
                            try (consumer.output + consumer.error).write(
                                to: workspace.appendingPathComponent("consumer.log"))
                            let consumerWarnings = Self.warnings(in: consumer)
                            warnings += consumerWarnings
                            guard consumer.status == 0 else {
                                throw Diagnostic(
                                    "SP-LINT-CONSUMER", stage: "lint",
                                    "Public interface build failed for " + platform + ": "
                                        + Self.failureOutput(consumer),
                                    file: path.path)
                            }
                            try Self.validateWarnings(consumerWarnings, allow: flags.contains("--allow-warnings"), file: path)
                            if !built.contains(platform) { built.append(platform) }
                            interfaces.append(platform + ":" + selection.name)
                            if !flags.contains("--skip-tests") {
                                for full in selection.tests {
                                    let type = try spec.testType(full, platform: platform)
                                    let scheme =
                                        spec.name + "-" + type.label + "-"
                                        + NativePodName.components(full).dropFirst().joined(separator: "-")
                                    let destination = try testDestination(platform)
                                    let arguments = [
                                        "xcodebuild", "-project",
                                        workspace.appendingPathComponent("Pods/Pods.xcodeproj").path, "-scheme", scheme,
                                        "-configuration", "Debug", "-sdk", sdk, "-destination", destination, "test",
                                        "CODE_SIGNING_ALLOWED=" + (platform == "osx" ? "NO" : "YES"),
                                        "CODE_SIGN_IDENTITY=-",
                                        "GCC_TREAT_WARNINGS_AS_ERRORS="
                                            + (flags.contains("--allow-warnings") ? "NO" : "YES"),
                                        "SWIFT_TREAT_WARNINGS_AS_ERRORS="
                                            + (flags.contains("--allow-warnings") ? "NO" : "YES"),
                                        "SYMROOT=" + workspace.appendingPathComponent("products").path,
                                    ]
                                    let run = try ToolProcess.run(
                                        "/usr/bin/xcrun", arguments, directory: workspace, environment: environment)
                                    try (run.output + run.error).write(
                                        to: workspace.appendingPathComponent(scheme + ".test.log"))
                                    let testWarnings = Self.warnings(in: run)
                                    warnings += testWarnings
                                    guard run.status == 0 else {
                                        throw Diagnostic(
                                            "SP-LINT-TEST", stage: "lint",
                                            "Tests failed for " + scheme + ": "
                                                + Self.failureOutput(run),
                                            file: path.path)
                                    }
                                    try Self.validateWarnings(
                                        testWarnings, allow: flags.contains("--allow-warnings"), file: path)
                                    tested.append(platform + ":" + scheme)
                                }
                            }
                        } catch {
                            let diagnostic =
                                error as? Diagnostic
                                ?? Diagnostic(
                                    "SP-LINT-ERROR", stage: "lint", String(describing: error), file: path.path)
                            errors.append([
                                "code": diagnostic.code, "message": diagnostic.message, "file": path.path,
                                "platform": platform, "specification": selection.name,
                            ])
                            if flags.contains("--fail-fast") { break }
                        }
                    }
                }
                reports.append([
                    "name": spec.name, "version": spec.version.description, "path": path.path, "warnings": warnings,
                    "built_platforms": built, "tested_schemes": tested, "artifacts": artifacts,
                    "built_interfaces": interfaces,
                    "status": errors.count == errorCount ? "passed" : "failed",
                    "validation": flags.contains("--quick") ? "metadata" : "metadata-build-and-tests",
                ])
            } catch {
                let diagnostic =
                    error as? Diagnostic
                    ?? Diagnostic("SP-LINT-ERROR", stage: "lint", String(describing: error), file: path.path)
                errors.append(["code": diagnostic.code, "message": diagnostic.message, "file": path.path])
                reports.append(["path": path.path, "status": "failed"])
            }
            if flags.contains("--fail-fast") && !errors.isEmpty { break }
        }
        return ["status": errors.isEmpty ? "passed" : "failed", "specifications": reports, "errors": errors]
    }
    private static func warnings(in result: ToolOutput) -> [String] {
        String(decoding: result.output + result.error, as: UTF8.self).components(separatedBy: .newlines)
            .filter { $0.contains("warning:") }
    }

    private static func validateWarnings(_ warnings: [String], allow: Bool, file: URL) throws {
        guard !allow, !warnings.isEmpty else { return }
        throw Diagnostic(
            "SP-LINT-WARNINGS", stage: "lint", warnings.prefix(12).joined(separator: "\n"), file: file.path)
    }

    static func failureOutput(_ result: ToolOutput) -> String {
        let text = String(decoding: result.output + result.error, as: UTF8.self)
        let errors = text.components(separatedBy: .newlines).filter {
            $0.contains("error:") || $0.contains("Undefined symbols")
        }
        return errors.isEmpty
            ? String(text.suffix(6000)) : String(errors.prefix(12).joined(separator: "\n").prefix(6000))
    }

    private func testDestination(_ platform: String) throws -> String {
        if platform == "osx" { return "platform=macOS" }
        let names = ["ios": "iOS", "tvos": "tvOS", "watchos": "watchOS", "visionos": "xrOS"]
        guard let name = names[platform] else {
            throw Diagnostic("SP-LINT-DESTINATION", stage: "lint", "Unsupported test platform")
        }
        let result = try ToolProcess.run(
            "/usr/bin/xcrun", ["simctl", "list", "devices", "available", "-j"], environment: environment)
        guard result.status == 0, let data = try JSONSerialization.jsonObject(with: result.output) as? [String: Any],
            let runtimes = data["devices"] as? [String: [[String: Any]]]
        else { throw Diagnostic("SP-LINT-DESTINATION", stage: "lint", "Cannot enumerate test simulators") }
        let devices = runtimes.filter { $0.key.contains("." + name + "-") }.sorted { $0.key < $1.key }.flatMap(\.value)
            .filter { $0["isAvailable"] as? Bool == true }
        guard let device = devices.first, let id = device["udid"] as? String else {
            throw Diagnostic("SP-LINT-DESTINATION", stage: "lint", "No available " + name + " test simulator")
        }
        return "id=" + id
    }
    static func metadata(_ spec: NativeSpec, privateSpec: Bool = false) throws -> [String] {
        let data = spec.data
        for key in ["summary", "homepage", "source"] where data[key] == nil {
            throw Diagnostic("SP-LINT-METADATA", stage: "lint", "Missing required attribute: " + key, file: spec.name)
        }
        guard data["authors"] != nil || data["author"] != nil else {
            throw Diagnostic("SP-LINT-METADATA", stage: "lint", "Missing authors", file: spec.name)
        }
        guard let summary = data["summary"] as? String,
            !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let homepage = data["homepage"] as? String, let url = URL(string: homepage),
            ["http", "https"].contains(url.scheme ?? ""),
            let source = data["source"] as? [String: Any],
            ["git", "http", "svn", "hg"].filter({ source[$0] != nil }).count == 1
        else {
            throw Diagnostic("SP-LINT-METADATA", stage: "lint", "Invalid summary, homepage or source", file: spec.name)
        }
        var warnings: [String] = []
        if data["license"] == nil { warnings.append("Missing license") }
        if summary.count > 140 { warnings.append("Summary exceeds 140 characters") }
        if data["deprecated"] as? Bool == true { warnings.append("Specification is deprecated") }
        if !privateSpec, source["git"] != nil, source["tag"] == nil {
            warnings.append("Git sources should specify a tag")
        }
        if !privateSpec, let url = source["git"] as? String, url.hasPrefix("http://") {
            warnings.append("Git sources should use HTTPS")
        }
        return warnings
    }
}
