import Foundation

extension CLIContext {
    func checkArchive() throws -> Int32 {
        guard arguments.count == 2 else {
            throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Archive path required")
        }
        try ExecutionPolicy.validateArchive(arguments[1])
        try output(["schema_version": 1, "status": "passed"])
        return 0
    }

    func accessContentStore() throws -> Int32 {
        guard arguments.count == 3,
            let payload = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile())
                as? [String: Any],
            let rawOrigin = payload["origin"] as? [String: Any],
            let origin = redactor.scrubObject(rawOrigin) as? [String: Any]
        else {
            throw Diagnostic("SP-CACHE-ARGUMENT", stage: "cache", "Invalid content-store request")
        }
        let store = try ContentStore(cacheRoot: URL(fileURLWithPath: arguments[2]))
        if arguments[1] == "get" {
            try output(store.get(origin: origin))
        } else if arguments[1] == "put", let path = payload["path"] as? String {
            try output(store.put(file: URL(fileURLWithPath: path), origin: origin))
        } else {
            throw Diagnostic("SP-CACHE-ARGUMENT", stage: "cache", "Unknown content-store operation")
        }
        return 0
    }

    func verifyCache() throws -> Int32 {
        guard arguments == ["cache", "verify"] else {
            throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Unknown cache verify argument")
        }
        let managed = try managedBundle()
        let root = managed.cacheRootPath(from: environment)
        try output(NativeCacheIntegrity.verify(URL(fileURLWithPath: root)))
        return 0
    }

    func runMaintenance() throws -> Int32 {
        let managed = try managedBundle()
        let root = URL(fileURLWithPath: managed.cacheRootPath(from: environment))
        let value = try NativeMaintenance.run(arguments, cache: root)
        try output(
            value.merging(["schema_version": 1, "status": "passed"]) { old, _ in old })
        return 0
    }

    func checkTree() throws -> Int32 {
        guard arguments.count == 2 else { throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Tree path required") }
        let value = try FileFingerprint.tree(URL(fileURLWithPath: arguments[1]), requireContainedLinks: true)
        guard value != "absent" else {
            throw Diagnostic("SP-ARCHIVE-MISSING", stage: "extract", "Extraction root does not exist")
        }
        try output(["schema_version": 1, "status": "passed", "sha256": value])
        return 0
    }

    func recover() throws -> Int32 {
        guard arguments.count == 1 else {
            throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Unknown recover argument")
        }
        try output(ProjectState(directory: directory).recover())
        return 0
    }

    func runIntegrity() throws -> Int32 {
        let action = arguments.dropFirst().first ?? "verify"
        let options = Array(arguments.dropFirst(2))
        guard options.isEmpty else {
            throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Unknown integrity option")
        }
        let integrity = ArtifactIntegrity(project: directory)
        if action == "verify" {
            try output(integrity.verify())
        } else if action == "record" {
            let lock = ProjectState(directory: directory)
            try lock.acquire()
            try output(integrity.record(report: lock.graph()))
        } else {
            throw Diagnostic("SP-CLI-ARGUMENT", stage: "cli", "Use integrity record or integrity verify")
        }
        return 0
    }
}
