import Foundation

extension NativeXcode {
    func hookDescription() -> [String: Any] {
        let current = podsProject
        var root = current.root
        root["objects"] = current.objects
        return [
            "path": current.url.deletingLastPathComponent().path, "generated": current.root["rootObject"] != nil,
            "graph": root,
        ]
    }
    func applyHookGraph(_ value: [String: Any], to destination: NativePBX) throws {
        let (objects, graph) = try NativeHookGraph.parse(value)
        if destination === aggregateProject || generatedProjects.values.contains(where: { $0 === destination }) {
            for id in Set(destination.objects.keys).union(objects.keys) {
                guard id != graph["rootObject"] as? String else { continue }
                if try jsonData(destination.objects[id] ?? [:]) != jsonData(objects[id] ?? [:]) {
                    self.graph.objects[id] = objects[id]
                }
            }
            if generatedProjects.values.contains(where: { $0 === destination }),
                let root = graph["rootObject"] as? String
            {
                let directory = destination.url.deletingLastPathComponent()
                let pod =
                    resolution.specs.keys.sorted().first { projectForPod($0).path == directory.path }
                    ?? directory.deletingPathExtension().lastPathComponent
                for id in objects[root]?["targets"] as? [String] ?? [] where targetOwners[id] == nil {
                    targetOwners[id] = pod
                }
            }
        }
        destination.objects = objects
        destination.root = graph.filter { $0.key != "objects" }
        let projects = [podsProject] + generatedProjects.values
        targetIDs = Set(
            projects.flatMap { project -> [String] in
                guard let root = project.root["rootObject"] as? String else { return [] }
                return project.objects[root]?["targets"] as? [String] ?? []
            }
        ).sorted()
        products = products.filter { self.graph.objects[$0] != nil }
    }
    func hookCallback(_ request: [String: Any]) throws -> [String: Any] {
        guard let value = request["value"] as? [String: Any], let raw = value["path"] as? String else {
            throw Diagnostic("SP-HOOK-PROJECT", stage: "hook", "Project callback requires a path")
        }
        let path = URL(fileURLWithPath: raw).standardizedFileURL.appendingPathComponent("project.pbxproj")
        let destination: NativePBX
        if path == podsProject.url {
            destination = podsProject
        } else if let child = generatedProjects[path.deletingLastPathComponent().path] {
            destination = child
        } else if let user = userProjects[path.path] {
            destination = user
        } else {
            throw Diagnostic(
                "SP-HOOK-PROJECT", stage: "hook", "Project is outside the installation's selected projects",
                file: path.path)
        }
        if request["callback"] as? String == "save_project" {
            try applyHookGraph(value, to: destination)
            try destination.save()
        } else if request["callback"] as? String != "open_project" {
            throw Diagnostic("SP-HOOK-PROJECT", stage: "hook", "Unknown project callback")
        }
        var root = destination.root
        root["objects"] = destination.objects
        return ["path": destination.url.deletingLastPathComponent().path, "graph": root]
    }
}

enum NativeHookGraph {
    static func parse(_ value: [String: Any]) throws -> ([String: [String: Any]], [String: Any]) {
        guard let graph = value["graph"] as? [String: Any], let objects = graph["objects"] as? [String: [String: Any]],
            let root = graph["rootObject"] as? String,
            objects[root]?["isa"] as? String == "PBXProject"
        else { throw Diagnostic("SP-HOOK-GRAPH", stage: "hook", "Hook returned an invalid project graph") }
        for (id, object) in objects {
            guard id.range(of: #"\A[A-Fa-f0-9]{24}\z"#, options: .regularExpression) != nil, object["isa"] is String
            else { throw Diagnostic("SP-HOOK-GRAPH", stage: "hook", "Invalid PBX object", file: id) }
            for key in ["targets", "buildPhases", "dependencies", "buildConfigurations", "children", "files"] {
                guard let value = object[key] else { continue }
                guard let ids = value as? [String] else {
                    throw Diagnostic("SP-HOOK-GRAPH", stage: "hook", "Invalid \(key) reference list", file: id)
                }
                if ids.contains(where: { objects[$0] == nil }) {
                    throw Diagnostic("SP-HOOK-GRAPH", stage: "hook", "Dangling \(key) reference", file: id)
                }
            }
        }
        return (objects, graph)
    }
}

final class NativeProjectAccess {
    let root: URL
    private var projects: [String: NativePBX] = [:]
    init(root: URL) { self.root = root }
    func callback(_ request: [String: Any], writable: Bool) throws -> [String: Any] {
        guard let value = request["value"] as? [String: Any], let raw = value["path"] as? String else {
            throw Diagnostic("SP-HOOK-PROJECT", stage: "dsl", "Project callback requires a path")
        }
        let directory = URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath()
        guard directory.pathExtension == "xcodeproj" else {
            throw Diagnostic("SP-HOOK-PROJECT", stage: "dsl", "Expected an Xcode project", file: directory.path)
        }
        if writable {
            try ProjectState(directory: root).registerProject(directory.appendingPathComponent("project.pbxproj"))
        }
        let path = directory.appendingPathComponent("project.pbxproj")
        let project: NativePBX
        if request["callback"] as? String == "create_project" {
            project = try NativePBX(path)
            let products = project.add(
                "hook:products", ["isa": "PBXGroup", "name": "Products", "sourceTree": "<group>", "children": []])
            let main = project.add("hook:main", ["isa": "PBXGroup", "sourceTree": "<group>", "children": [products]])
            let configs = ["Debug", "Release"].map {
                project.add("hook:config:" + $0, ["isa": "XCBuildConfiguration", "name": $0, "buildSettings": [:]])
            }
            let list = project.add(
                "hook:configurations",
                [
                    "isa": "XCConfigurationList", "buildConfigurations": configs, "defaultConfigurationName": "Release",
                    "defaultConfigurationIsVisible": "0",
                ])
            let root = project.add(
                "hook:project",
                [
                    "isa": "PBXProject", "attributes": [:], "targets": [], "mainGroup": main,
                    "productRefGroup": products, "buildConfigurationList": list, "compatibilityVersion": "Xcode 14.0",
                    "developmentRegion": "en", "knownRegions": ["en", "Base"], "projectDirPath": "", "projectRoot": "",
                ])
            project.root = ["archiveVersion": "1", "objectVersion": "56", "rootObject": root, "classes": [:]]
        } else {
            project = try projects[path.path] ?? NativePBX(path, existing: true)
        }
        projects[path.path] = project
        if request["callback"] as? String == "save_project" {
            guard writable else {
                throw Diagnostic("SP-HOOK-PROJECT", stage: "inspect", "Project saves are unavailable during inspection")
            }
            let (objects, graph) = try NativeHookGraph.parse(value)
            project.objects = objects
            project.root = graph.filter { $0.key != "objects" }
            try project.save()
        } else if !["open_project", "create_project"].contains(request["callback"] as? String ?? "") {
            throw Diagnostic("SP-HOOK-PROJECT", stage: "dsl", "Unknown project callback")
        }
        var graph = project.root
        graph["objects"] = project.objects
        return ["path": directory.path, "graph": graph]
    }
}
