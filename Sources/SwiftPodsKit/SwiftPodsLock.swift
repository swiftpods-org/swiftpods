import Foundation
import SwiftPodsManifest

/// Reproducible provenance for catalog lookups and materialized package overrides.
struct SwiftPodsLock: Sendable, Codable, Equatable {
    static let fileName = "SwiftPods.lock"
    static let schemaVersion = 1
    private static let overrideSchemaVersion = 2

    struct Entry: Sendable, Codable, Equatable {
        let name: String
        let sha256: String

        init(name: String, sha256: String) {
            self.name = name
            self.sha256 = sha256
        }
    }

    struct Catalog: Sendable, Codable, Equatable {
        let url: String
        let revision: String
        let entries: [Entry]

        init(url: String, revision: String, entries: [Entry]) {
            self.url = url
            self.revision = revision
            self.entries = entries.sorted { ($0.name.lowercased(), $0.name) < ($1.name.lowercased(), $1.name) }
        }
    }

    struct Override: Sendable, Codable, Equatable {
        let identity: String
        let url: String
        let revision: String
        let submodules: Bool
        let sha256: String
        /// Tracked paths under .swiftpm and .build are part of the digest even though adjacent resolver output is not.
        let metadataPaths: [String]

        static func == (lhs: Self, rhs: Self) -> Bool {
            // Digest verification uses the set of tracked paths.
            lhs.identity == rhs.identity && lhs.url == rhs.url && lhs.revision == rhs.revision
                && lhs.submodules == rhs.submodules && lhs.sha256 == rhs.sha256
                && Set(lhs.metadataPaths) == Set(rhs.metadataPaths)
        }

        func matches(_ package: Package) -> Bool {
            guard case .pinnedOverride(let origin, let commit, let includesSubmodules) = package.location else {
                return false
            }
            return package.identity == identity && url == origin && revision == commit && submodules == includesSubmodules
        }
    }

    let version: Int
    let catalogs: [Catalog]
    private let overrides: [Override]?

    var pinnedOverrides: [Override] { overrides ?? [] }
    var isEmpty: Bool { catalogs.isEmpty && pinnedOverrides.isEmpty }

    init(resolutions: [GitCatalog.Resolution], overrides: [Override] = []) {
        version = overrides.isEmpty ? Self.schemaVersion : Self.overrideSchemaVersion
        catalogs = resolutions.map { Catalog(url: $0.url, revision: $0.revision, entries: $0.entries) }
            .sorted { Data($0.url.utf8).lexicographicallyPrecedes(Data($1.url.utf8)) }
        self.overrides = overrides.isEmpty ? nil : overrides.sorted { $0.identity < $1.identity }
    }

    init(data: Data, file: URL) throws {
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw SwiftPodsError(
                "SwiftPods.lock is not valid JSON", file: file.path, hint: "Restore it, or remove it and run `swiftpods install`")
        }
        do {
            self = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw SwiftPodsError(
                "SwiftPods.lock is not valid: \(error)", file: file.path, hint: "Restore it, or remove it and run `swiftpods install`")
        }
        guard version == Self.schemaVersion || version == Self.overrideSchemaVersion else {
            throw SwiftPodsError("SwiftPods.lock has unsupported version \(version)", file: file.path)
        }
        guard Set(catalogs.map(\.url)).count == catalogs.count else {
            throw SwiftPodsError("SwiftPods.lock contains a duplicate catalog URL", file: file.path)
        }
        for catalog in catalogs {
            let names = Set(catalog.entries.map { $0.name.lowercased() })
            guard names.count == catalog.entries.count else {
                throw SwiftPodsError("SwiftPods.lock contains a duplicate entry in catalog \(catalog.url)", file: file.path)
            }
        }
        guard Set(pinnedOverrides.map(\.identity)).count == pinnedOverrides.count else {
            throw SwiftPodsError("SwiftPods.lock contains a duplicate package override", file: file.path)
        }
    }

    init(contentsOf file: URL) throws {
        try self.init(data: Data(contentsOf: file), file: file)
    }

    /// The lock at `file`, or nil when there is none.
    static func read(at file: URL) throws -> SwiftPodsLock? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try SwiftPodsLock(data: Data(contentsOf: file), file: file)
    }

    func catalog(url: String) -> Catalog? { catalogs.first { $0.url == url } }

    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    func problems(comparedTo actual: SwiftPodsLock) -> [String] {
        var problems: [String] = []
        let expectedByURL = Dictionary(uniqueKeysWithValues: catalogs.map { ($0.url, $0) })
        let actualByURL = Dictionary(uniqueKeysWithValues: actual.catalogs.map { ($0.url, $0) })
        for url in Set(expectedByURL.keys).union(actualByURL.keys).sorted() {
            guard let expected = expectedByURL[url] else {
                problems.append("Catalog \(url) is not recorded")
                continue
            }
            guard let found = actualByURL[url] else {
                problems.append("Catalog \(url) is recorded but no longer used")
                continue
            }
            if expected.revision != found.revision {
                problems.append("Catalog \(url) is at \(found.revision), locked at \(expected.revision)")
            }
            let expectedEntries = Dictionary(uniqueKeysWithValues: expected.entries.map { ($0.name.lowercased(), $0) })
            let foundEntries = Dictionary(uniqueKeysWithValues: found.entries.map { ($0.name.lowercased(), $0) })
            for name in Set(expectedEntries.keys).union(foundEntries.keys).sorted() {
                switch (expectedEntries[name], foundEntries[name]) {
                case (nil, let entry?): problems.append("Catalog entry `\(entry.name)` from \(url) is not recorded")
                case (let entry?, nil): problems.append("Catalog entry `\(entry.name)` from \(url) is recorded but no longer used")
                case (let expectedEntry?, let foundEntry?) where expectedEntry.sha256 != foundEntry.sha256:
                    problems.append("Catalog entry `\(foundEntry.name)` from \(url) does not match its locked SHA-256")
                default: break
                }
            }
        }
        // A merged lock may list them in another order.
        let byIdentity: (Override, Override) -> Bool = { $0.identity < $1.identity }
        if pinnedOverrides.sorted(by: byIdentity) != actual.pinnedOverrides.sorted(by: byIdentity) {
            problems.append("Package overrides do not match the locked origins, revisions and tree digests")
        }
        return problems
    }
}
