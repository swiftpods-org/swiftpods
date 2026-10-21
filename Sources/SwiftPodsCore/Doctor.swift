import Foundation

struct Doctor {
    let directory: URL
    let platform: String?
    let variant: String?
    let architecture: String?
    let application: URL?
    let deploymentTarget: String?

    func report(bundle: RuntimeBundle?) -> [String: Any] {
        var report = StaticInspection(directory: directory).report(bundle: bundle)
        var checks = report["checks"] as? [[String: Any]] ?? []
        var binaries: [[String: Any]] = []
        var packages: [[String: Any]] = []
        var projects: [[String: Any]] = []
        func check(_ name: String, _ status: String, _ message: String, file: URL? = nil) {
            var row: [String: Any] = ["name": name, "status": status, "message": message, "stage": "doctor"]
            if status == "failed" {
                row["code"] = "SP-DOCTOR-" + name.uppercased().replacingOccurrences(of: "_", with: "-")
            }
            if let file { row["file"] = file.path }
            checks.append(row)
        }
        func plist(_ path: URL) throws -> [String: Any] {
            guard
                let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: path), format: nil)
                    as? [String: Any]
            else {
                throw Diagnostic("SP-DOCTOR-PLIST", stage: "doctor", "Invalid property list", file: path.path)
            }
            return value
        }
        func contained(_ relative: String, in root: URL) throws -> URL {
            let file = root.appendingPathComponent(relative).standardizedFileURL
            guard !relative.isEmpty, relative.utf8.first != 47,
                !(relative as NSString).pathComponents.contains(".."),
                NativePath.isDescendant(file.resolvingSymlinksInPath(), of: root.resolvingSymlinksInPath())
            else {
                throw Diagnostic(
                    "SP-DOCTOR-PATH", stage: "doctor", "Product path escapes its declared container", file: relative)
            }
            return file
        }
        func binaryURL(_ path: URL) throws -> URL {
            guard path.pathExtension == "framework" else { return path }
            let infoPaths = [
                path.appendingPathComponent("Info.plist"), path.appendingPathComponent("Resources/Info.plist"),
            ]
            let name =
                infoPaths.compactMap { try? plist($0)["CFBundleExecutable"] as? String }.first
                ?? path.deletingPathExtension().lastPathComponent
            return try contained(name, in: path)
        }
        func minimumOS(_ slices: [BinarySlice], file: URL) {
            guard let deploymentTarget else { return }
            let requested = deploymentTarget.split(separator: ".").compactMap { Int($0) }
            for slice in slices
            where (platform == nil || slice.platform == platform) && (variant == nil || slice.variant == variant)
                && (architecture == nil || slice.architecture == architecture)
            {
                let minimum = slice.minimumOS.split(separator: ".").compactMap { Int($0) }
                guard !minimum.isEmpty else {
                    check("deployment_target", "unknown", "Binary minimum OS is unknown", file: file)
                    continue
                }
                let left = minimum + Array(repeating: 0, count: max(0, 3 - minimum.count))
                let right = requested + Array(repeating: 0, count: max(0, 3 - requested.count))
                if right.lexicographicallyPrecedes(left) {
                    check(
                        "deployment_target", "failed",
                        "Binary requires \(slice.minimumOS), above requested \(deploymentTarget)", file: file)
                }
            }
        }
        func inspectBinary(_ path: URL, embedded: Bool = false) {
            do {
                let executable = try binaryURL(path)
                guard FileManager.default.fileExists(atPath: executable.path) else {
                    check("binary_product", "failed", "Framework/library executable is missing", file: executable)
                    return
                }
                let slices = try BinaryInspection.inspect(executable)
                minimumOS(slices, file: executable)
                binaries.append(["path": path.path, "slices": slices.map(\.json)])
                guard !slices.isEmpty else {
                    check(
                        "binary_metadata", "unknown",
                        "No supported Mach-O metadata; build/toolchain validation is still required", file: executable)
                    return
                }
                if let platform {
                    let available = slices.filter {
                        $0.platform == platform && (variant == nil || $0.variant == variant)
                            && (architecture == nil || $0.architecture == architecture)
                    }
                    check(
                        "binary_slice", available.isEmpty ? "failed" : "passed",
                        available.isEmpty
                            ? "No slice matches platform/variant/architecture" : "Matching Mach-O slice exists",
                        file: executable)
                }
                if embedded && slices.contains(where: { $0.kind == "static" || $0.kind == "object" }) {
                    check(
                        "static_framework_embed", "failed",
                        "A static library/framework is embedded in the application Frameworks directory", file: path)
                }
            } catch { check("binary_metadata", "failed", String(describing: error), file: path) }
        }
        func inspectXCFramework(_ path: URL) {
            do {
                let info = try plist(path.appendingPathComponent("Info.plist"))
                guard let libraries = info["AvailableLibraries"] as? [[String: Any]], !libraries.isEmpty else {
                    check("xcframework_layout", "failed", "XCFramework has no AvailableLibraries", file: path)
                    return
                }
                var selected = 0
                for library in libraries {
                    guard let identifier = library["LibraryIdentifier"] as? String,
                        let relative = library["LibraryPath"] as? String,
                        let arches = library["SupportedArchitectures"] as? [String],
                        let sdk = library["SupportedPlatform"] as? String
                    else {
                        check("xcframework_layout", "failed", "Invalid slice descriptor", file: path)
                        continue
                    }
                    let directory = try contained(identifier, in: path)
                    let slice = try contained(relative, in: directory)
                    let sliceVariant = library["SupportedPlatformVariant"] as? String ?? "device"
                    let normalizedSDK = sdk == "macos" ? "osx" : sdk
                    if (platform == nil || normalizedSDK == platform) && (variant == nil || sliceVariant == variant)
                        && (architecture == nil || arches.contains(architecture!))
                    {
                        selected += 1
                    }
                    guard FileManager.default.fileExists(atPath: slice.path) else {
                        check("xcframework_layout", "failed", "Declared slice product is missing", file: slice)
                        continue
                    }
                    let metadata = try BinaryInspection.inspect(binaryURL(slice))
                    minimumOS(metadata, file: slice)
                    binaries.append([
                        "path": slice.path, "declared_platform": normalizedSDK, "declared_variant": sliceVariant,
                        "declared_architectures": arches, "slices": metadata.map(\.json),
                    ])
                    if metadata.isEmpty {
                        check(
                            "xcframework_metadata", "unknown", "Slice requires external toolchain validation",
                            file: slice)
                    } else {
                        let compatible =
                            Set(metadata.map(\.architecture)) == Set(arches)
                            && metadata.allSatisfy { $0.platform == normalizedSDK && $0.variant == sliceVariant }
                        check(
                            "xcframework_metadata", compatible ? "passed" : "failed",
                            compatible
                                ? "Declared architecture/platform/variant match the binary"
                                : "Slice declaration disagrees with Mach-O metadata", file: slice)
                    }
                }
                if platform != nil {
                    check(
                        "xcframework_selection", selected > 0 ? "passed" : "failed",
                        selected > 0
                            ? "Requested slice is declared"
                            : "No declared slice matches requested platform/variant/architecture", file: path)
                }
            } catch { check("xcframework_layout", "failed", String(describing: error), file: path) }
        }
        func inspectProject(_ path: URL) {
            do {
                let result = try ToolProcess.run(
                    "/usr/bin/plutil",
                    ["-convert", "json", "-o", "-", path.appendingPathComponent("project.pbxproj").path])
                guard result.status == 0,
                    let document = try JSONSerialization.jsonObject(with: result.output) as? [String: Any],
                    let objects = document["objects"] as? [String: [String: Any]]
                else {
                    check("project_parse", "failed", "Cannot parse project.pbxproj", file: path)
                    return
                }
                projects.append(["path": path.path, "object_version": document["objectVersion"] ?? "unknown"])
                for object in objects.values where object["isa"] as? String == "PBXNativeTarget" {
                    let products = (object["packageProductDependencies"] as? [String] ?? []).compactMap { objects[$0] }
                    for product in products {
                        let package = (product["package"] as? String).flatMap { objects[$0] }
                        packages.append([
                            "target": object["name"] ?? "unknown", "product": product["productName"] ?? "unknown",
                            "url": package?["repositoryURL"] ?? package?["relativePath"] ?? "unknown",
                            "project": path.path,
                        ])
                    }
                    let configs =
                        (object["buildConfigurationList"] as? String).flatMap { objects[$0] }?["buildConfigurations"]
                        as? [String] ?? []
                    for id in configs {
                        guard let config = objects[id], let settings = config["buildSettings"] as? [String: Any] else {
                            continue
                        }
                        let base = (config["baseConfigurationReference"] as? String).flatMap { objects[$0] }
                        let integrated = (base?["path"] as? String)?.contains("Pods-") == true
                        for key in [
                            "OTHER_LDFLAGS", "OTHER_CFLAGS", "OTHER_CPLUSPLUSFLAGS", "HEADER_SEARCH_PATHS",
                            "FRAMEWORK_SEARCH_PATHS", "LIBRARY_SEARCH_PATHS",
                        ] {
                            guard let value = settings[key], integrated else { continue }
                            let text = (value as? [String])?.joined(separator: " ") ?? value as? String ?? ""
                            if !text.isEmpty && !text.contains("$(inherited)") && !text.contains("${inherited}") {
                                check(
                                    "build_setting_inheritance", "failed",
                                    "\(object["name"] ?? "target")/\(config["name"] ?? "configuration"): \(key) overrides its base configuration without inherited",
                                    file: path)
                            }
                        }
                    }
                }
                check("project_parse", "passed", "Project parsed without executing Ruby", file: path)
            } catch { check("project_parse", "failed", String(describing: error), file: path) }
        }
        let manager = FileManager.default
        if let enumerator = manager.enumerator(
            at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles])
        {
            while let path = enumerator.nextObject() as? URL {
                if ["node_modules", "DerivedData", "SourcePackages", "dist"].contains(path.lastPathComponent)
                    || ((try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true)
                {
                    enumerator.skipDescendants()
                    continue
                }
                if path.pathExtension == "xcodeproj" {
                    inspectProject(path)
                    enumerator.skipDescendants()
                } else if path.pathExtension == "xcframework" {
                    inspectXCFramework(path)
                    enumerator.skipDescendants()
                } else if path.pathExtension == "framework" {
                    inspectBinary(path)
                    enumerator.skipDescendants()
                } else if ["a", "dylib"].contains(path.pathExtension) {
                    inspectBinary(path)
                }
            }
        }
        let installed = try? readObject(ProjectStorage(project: directory).file("installation.json"))
        if let installed {
            for spec in installed["specs"] as? [[String: Any]] ?? [] {
                guard let module = spec["module_name"] as? String else { continue }
                for package in packages where package["product"] as? String == module {
                    let targetPods = (installed["targets"] as? [[String: Any]] ?? []).filter {
                        ($0["user_targets"] as? [String] ?? []).contains(package["target"] as? String ?? "")
                            && ($0["user_project"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.path }
                                == (package["project"] as? String).map {
                                    URL(fileURLWithPath: $0).standardizedFileURL.path
                                }
                    }.flatMap { $0["pods"] as? [String] ?? [] }
                    guard let name = spec["name"] as? String, targetPods.contains(name.components(separatedBy: "/")[0])
                    else { continue }
                    check(
                        "duplicate_sdk", "failed",
                        "Pod \(spec["name"] ?? module) and SPM product \(module) share a module name in \(package["target"] ?? "target")"
                    )
                }
            }
            check(
                "plugin_profile", "unknown",
                "Installed plugin versions are recorded; only published fixture versions are certified")
            report["plugins"] = installed["plugins"] ?? []
        }
        if let application {
            var applicationNames = Set([application.deletingPathExtension().lastPathComponent])
            if !manager.fileExists(atPath: application.appendingPathComponent("Info.plist").path)
                && !manager.fileExists(atPath: application.appendingPathComponent("Contents/Info.plist").path)
            {
                check("application", "failed", "Built application Info.plist is missing", file: application)
            } else {
                let mac = manager.fileExists(atPath: application.appendingPathComponent("Contents/Info.plist").path)
                let info = try? plist(application.appendingPathComponent(mac ? "Contents/Info.plist" : "Info.plist"))
                if let name = info?["CFBundleName"] as? String { applicationNames.insert(name) }
                if let executable = info?["CFBundleExecutable"] as? String {
                    do {
                        _ = try contained(executable, in: application)
                        let path = try contained((mac ? "Contents/MacOS/" : "") + executable, in: application)
                        applicationNames.insert(executable)
                        inspectBinary(path)
                    } catch { check("application", "failed", String(describing: error), file: application) }
                } else {
                    check("application", "failed", "CFBundleExecutable is missing", file: application)
                }
            }
            for location in ["Frameworks", "Contents/Frameworks"] {
                do {
                    let root = try contained(location, in: application)
                    for path in (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
                    where path.pathExtension == "framework" {
                        let relative = NativePath.relativePath(of: path, to: application)
                        inspectBinary(try contained(relative, in: application), embedded: true)
                    }
                } catch { check("application", "failed", String(describing: error), file: application) }
            }
            let resources =
                manager.enumerator(at: application, includingPropertiesForKeys: nil)?.allObjects.compactMap {
                    ($0 as? URL)?.path
                } ?? []
            report["application_resources"] = resources.filter {
                $0.hasSuffix(".xcprivacy") || $0.hasSuffix(".bundle") || $0.hasSuffix(".lproj")
            }
            let matchingTargets = (installed?["targets"] as? [[String: Any]] ?? []).filter {
                !applicationNames.isDisjoint(with: Set($0["user_targets"] as? [String] ?? []))
            }
            let applicationPods = Set(matchingTargets.flatMap { $0["pods"] as? [String] ?? [] })
            if matchingTargets.isEmpty {
                check(
                    "resource_scope", "unknown",
                    "Built product cannot be matched to a recorded user target; expected resource ownership is unverified",
                    file: application)
            }
            for entry in installed?["resources"] as? [[String: Any]] ?? []
            where applicationPods.contains(entry["pod"] as? String ?? "") {
                for bundle in entry["bundles"] as? [String] ?? []
                where !resources.contains(where: { $0.hasSuffix("/" + bundle + ".bundle") }) {
                    check(
                        "resource_bundle", "failed",
                        "Expected installed pod resource bundle \(bundle).bundle is missing", file: application)
                }
                for privacy in entry["privacy_manifests"] as? [String] ?? []
                where !resources.contains(where: { $0.hasSuffix("/" + privacy) }) {
                    check(
                        "privacy_manifest", "failed", "Expected pod privacy manifest \(privacy) is missing",
                        file: application)
                }
            }
        }
        report["checks"] = checks
        report["binaries"] = binaries
        report["packages"] = packages
        report["projects"] = projects
        report["status"] = checks.contains { $0["status"] as? String == "failed" } ? "failed" : "unknown"
        report["scope"] =
            "Static metadata and optional built bundle; runtime loading, toolchain resolution and device behavior remain unverified"
        return report
    }
}
