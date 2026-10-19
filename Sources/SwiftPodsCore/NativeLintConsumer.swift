import Foundation

/// Lint compiles the exported interface through an ordinary integrated consumer.
enum NativeLintConsumer {
    static func create(in workspace: URL, platform: String, minimum: String) throws {
        let graph = try NativePBX(workspace.appendingPathComponent("Lint.xcodeproj/project.pbxproj"))
        let sdk = ["osx": "macosx", "ios": "iphoneos", "tvos": "appletvos", "watchos": "watchos", "visionos": "xros"]
        let deployment = [
            "osx": "MACOSX_DEPLOYMENT_TARGET", "ios": "IPHONEOS_DEPLOYMENT_TARGET", "tvos": "TVOS_DEPLOYMENT_TARGET",
            "watchos": "WATCHOS_DEPLOYMENT_TARGET", "visionos": "XROS_DEPLOYMENT_TARGET",
        ]
        let settings: [String: Any] = [
            "SDKROOT": sdk[platform]!, deployment[platform]!: minimum, "PRODUCT_NAME": "Lint",
            "PRODUCT_BUNDLE_IDENTIFIER": "org.swiftpods.lint", "GENERATE_INFOPLIST_FILE": "YES",
            "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
            "SWIFT_VERSION": "5.0", "CODE_SIGNING_ALLOWED": "NO",
            "ENABLE_DEBUG_DYLIB": "NO", "SKIP_INSTALL": "YES",
        ]
        func configurations(_ name: String, settings: [String: Any]) -> String {
            let ids = ["Debug", "Release"].map {
                graph.add(
                    "lint:config:" + name + ":" + $0,
                    ["isa": "XCBuildConfiguration", "name": $0, "buildSettings": settings])
            }
            return graph.add(
                "lint:configs:" + name,
                [
                    "isa": "XCConfigurationList", "buildConfigurations": ids,
                    "defaultConfigurationIsVisible": "0", "defaultConfigurationName": "Release",
                ])
        }
        let main = graph.add(
            "lint:main",
            [
                "isa": "PBXFileReference", "path": "main.m", "sourceTree": "SOURCE_ROOT",
                "lastKnownFileType": "sourcecode.c.objc",
            ])
        let probe = graph.add(
            "lint:probe",
            [
                "isa": "PBXFileReference", "path": "Probe.m", "sourceTree": "SOURCE_ROOT",
                "lastKnownFileType": "sourcecode.c.objc",
            ])
        let sources = graph.add(
            "lint:sources",
            [
                "isa": "PBXSourcesBuildPhase", "buildActionMask": "2147483647",
                "runOnlyForDeploymentPostprocessing": "0",
                "files": [main, probe].map { graph.add("lint:build:" + $0, ["isa": "PBXBuildFile", "fileRef": $0]) },
            ])
        let frameworks = graph.add(
            "lint:frameworks",
            [
                "isa": "PBXFrameworksBuildPhase", "files": [], "buildActionMask": "2147483647",
                "runOnlyForDeploymentPostprocessing": "0",
            ])
        let product = graph.add(
            "lint:product",
            [
                "isa": "PBXFileReference", "path": "Lint.app", "sourceTree": "BUILT_PRODUCTS_DIR",
                "explicitFileType": "wrapper.application",
            ])
        let target = graph.add(
            "lint:target",
            [
                "isa": "PBXNativeTarget", "name": "Lint", "productName": "Lint", "productReference": product,
                "productType": "com.apple.product-type.application",
                "buildConfigurationList": configurations("target", settings: settings),
                "buildPhases": [sources, frameworks], "buildRules": [], "dependencies": [],
            ])
        let products = graph.add(
            "lint:products", ["isa": "PBXGroup", "name": "Products", "sourceTree": "<group>", "children": [product]])
        let group = graph.add(
            "lint:group", ["isa": "PBXGroup", "sourceTree": "<group>", "children": [main, probe, products]])
        let project = graph.add(
            "lint:project",
            [
                "isa": "PBXProject", "attributes": [:],
                "buildConfigurationList": configurations("project", settings: [:]),
                "compatibilityVersion": "Xcode 14.0", "developmentRegion": "en", "knownRegions": ["en", "Base"],
                "mainGroup": group, "productRefGroup": products, "projectDirPath": "", "projectRoot": "",
                "targets": [target],
            ])
        graph.root = ["archiveVersion": "1", "objectVersion": "56", "classes": [:], "rootObject": project]
        try Data("int main(void) { return 0; }\n".utf8).write(to: workspace.appendingPathComponent("main.m"))
        try Data().write(to: workspace.appendingPathComponent("Probe.m"))
        try graph.save()
    }

    static func writeProbe(in workspace: URL, spec: NativeSpec, platform: String) throws {
        let installed = try NativeSpec(
            data: readObject(
                workspace.appendingPathComponent(
                    "Pods/Local Podspecs/" + spec.name + ".podspec.json")))
        let lock = try NativeLock(workspace.appendingPathComponent("Podfile.lock"))
        let declarations = (lock.raw["PODS"] as? [Any] ?? []).compactMap {
            ($0 as? String) ?? ($0 as? [String: Any])?.keys.first
        }
        let names = try declarations.map { $0.components(separatedBy: " (")[0] }.filter {
            NativePodName.isWithin($0, spec.name)
        }.filter { try installed.kind($0) == .library }
        let attributes = try NativeVariantPlan.attributes(installed, names: names, platform: platform)
        let pods = try NativePBX(
            workspace.appendingPathComponent("Pods/Pods.xcodeproj/project.pbxproj"), existing: true)
        guard
            let target = pods.objects.values.first(where: {
                $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == spec.name
            }),
            let list = target["buildConfigurationList"] as? String,
            let config = (pods.objects[list]?["buildConfigurations"] as? [String])?.first(where: {
                pods.objects[$0]?["name"] as? String == "Release"
            }),
            let configuration = pods.objects[config]
        else { throw Diagnostic("SP-LINT-CONSUMER", stage: "lint", "Missing library target", file: spec.name) }
        let scope = try NativeBuildSettings.resolvedScopes(
            configuration, graph: pods, targetName: target["name"] as? String
        ).targetScope
        let settings = scope.values
        let phases = target["buildPhases"] as? [String] ?? []
        let sourceFiles = phases.filter { pods.objects[$0]?["isa"] as? String == "PBXSourcesBuildPhase" }.flatMap {
            pods.objects[$0]?["files"] as? [String] ?? []
        }
        let swift = sourceFiles.contains {
            guard let ref = pods.objects[$0]?["fileRef"] as? String else { return false }
            return (pods.objects[ref]?["path"] as? String)?.hasSuffix(".swift") == true
        }
        guard let directory = try scope.expandedValue("PODS_TARGET_SRCROOT") else {
            throw Diagnostic("SP-LINT-CONSUMER", stage: "lint", "Missing library source directory", file: spec.name)
        }
        let selection = try NativeLibraryFiles(
            spec: installed, names: names, platform: platform, root: URL(fileURLWithPath: directory))
        let cxxSources: Set<String> = ["cc", "cpp", "cxx", "c++", "C", "mm", "M"]
        let cxxHeaders: Set<String> = ["hh", "hpp", "hxx", "ipp", "tpp"]
        let objectiveCPlusPlus =
            selection.files.contains { cxxSources.contains($0.pathExtension) }
            || selection.publicHeaders.contains { cxxHeaders.contains($0.pathExtension) }
        let modular = attributes["module_map"] as? Bool != false && settings["DEFINES_MODULE"] as? String == "YES"
        let contents: String
        if swift || modular {
            contents = swift ? "import \(spec.moduleName)\n" : "@import \(spec.moduleName);\n"
        } else {
            contents = try selection.publicHeaders.sorted(by: { $0.path < $1.path }).map {
                let headerDirectory =
                    target["productType"] as? String == "com.apple.product-type.framework"
                    ? installed.moduleName : try selection.headerDirectory($0, module: installed.moduleName)
                return "#import <" + headerDirectory + "/" + (try selection.headerPath($0)) + ">\n"
            }.joined()
        }
        let graph = try NativePBX(workspace.appendingPathComponent("Lint.xcodeproj/project.pbxproj"), existing: true)
        let file = NativePBX.identifier("lint:probe")
        let filename = swift ? "Probe.swift" : objectiveCPlusPlus ? "Probe.mm" : "Probe.m"
        graph.objects[file]?["path"] = filename
        graph.objects[file]?["lastKnownFileType"] =
            swift
            ? "sourcecode.swift"
            : objectiveCPlusPlus ? "sourcecode.cpp.objcpp" : "sourcecode.c.objc"
        for id in Array(graph.objects.keys) where graph.objects[id]?["isa"] as? String == "XCBuildConfiguration" {
            var values = graph.objects[id]?["buildSettings"] as? [String: Any] ?? [:]
            if let version = settings["SWIFT_VERSION"] { values["SWIFT_VERSION"] = version }
            if objectiveCPlusPlus && !swift && values["PRODUCT_NAME"] as? String == "Lint" {
                values["CLANG_DISABLE_CXX_MODULES"] = "NO"
                var flags = nativeStrings(values["OTHER_CPLUSPLUSFLAGS"])
                if flags.isEmpty { flags = ["$(inherited)"] }
                if !flags.contains("-fcxx-modules") { flags.append("-fcxx-modules") }
                values["OTHER_CPLUSPLUSFLAGS"] = flags
            }
            graph.objects[id]?["buildSettings"] = values
        }
        try Data(contents.utf8).write(to: workspace.appendingPathComponent(filename))
        try graph.save()
    }
}
