import Foundation
import SwiftPodsManifest
import XCTest

private let hyprMX: CatalogEntry.BinarySDK = {
    var sdk = CatalogEntry.BinarySDK(releases: [
        .init(version: "6.4.1", url: "https://example.com/HyprMX-6.4.1.zip", sha256: String(repeating: "1", count: 64)),
        .init(version: "6.4.2", url: "https://example.com/HyprMX-6.4.2.zip", sha256: String(repeating: "2", count: 64)),
    ])
    sdk.systemFrameworks = ["WebKit"]
    sdk.resources = ["HyprMX.bundle"]
    return sdk
}()

private struct FakeCatalog: PackageCatalog {
    let entries: [String: [CatalogEntry]]

    func entry(named name: String, in sources: [Source]) throws -> CatalogEntry? {
        for source in sources {
            if let entry = entries[source.url]?.first(where: { $0.name.lowercased() == name.lowercased() }) { return entry }
        }
        return nil
    }
}

final class CatalogTests: XCTestCase {
    private let catalog = FakeCatalog(entries: [
        Source.publicCatalog: [
            CatalogEntry(name: "Datadog", url: "https://github.com/DataDog/dd-sdk-ios.git", products: ["DatadogCore"], source: Source.publicCatalog),
            CatalogEntry(name: "Firebase", url: "https://github.com/firebase/firebase-ios-sdk.git", products: [], source: Source.publicCatalog),
            CatalogEntry(name: "HyprMX", url: nil, products: [], binary: hyprMX, source: Source.publicCatalog),
        ],
        "https://example.com/team/catalog.git": [
            CatalogEntry(name: "Ads", url: "https://example.com/team/ads.git", products: ["Ads"], source: "https://example.com/team/catalog.git"),
        ],
    ])

    private func read(_ podfile: String) throws -> Manifest {
        try ManifestReader(read: { _ in podfile }, catalog: catalog).load("/project/Podfile")
    }

    private func error(_ podfile: String) -> ManifestError? {
        do {
            _ = try read(podfile)
            return nil
        } catch {
            return error as? ManifestError
        }
    }

    func testNamesResolveThroughThePublicCatalog() throws {
        let manifest = try read("target 'App' do\n  spm 'datadog', '~> 3.15'\nend\n")
        XCTAssertEqual(manifest.sources, [Source(url: Source.publicCatalog)])
        let package = try XCTUnwrap(manifest.packages.first)
        XCTAssertEqual(package.name, "Datadog")
        XCTAssertEqual(package.location, .remote(url: "https://github.com/DataDog/dd-sdk-ios.git"))
        XCTAssertEqual(package.catalog, Source.publicCatalog)
        XCTAssertEqual(package.requirement, .upToNextMajor(Version(3, 15, 0)))
        XCTAssertEqual(manifest.targets[0].products.map(\.product), ["DatadogCore"])

        let chosen = try read("target 'App' do\n  spm 'Datadog', '~> 3.15', products: ['DatadogLogs']\nend\n")
        XCTAssertEqual(chosen.targets[0].products.map(\.product), ["DatadogLogs"])
    }

    func testDeclaredSourcesReplaceThePublicCatalog() throws {
        let manifest = try read(
            """
            source 'https://example.com/team/catalog.git'
            target 'App' do
              spm 'Ads', exact: '1.0.0'
            end
            """)
        XCTAssertEqual(manifest.sources.map(\.url), ["https://example.com/team/catalog.git"])
        XCTAssertEqual(manifest.packages[0].location, .remote(url: "https://example.com/team/ads.git"))

        let missing = error("source 'https://example.com/team/catalog.git'\ntarget 'App' do\n  spm 'Datadog', exact: '1.0.0'\nend\n")
        XCTAssertTrue(missing?.message.contains("`Datadog` is not in https://example.com/team/catalog.git") == true, "\(String(describing: missing))")
    }

    func testCatalogErrors() {
        XCTAssertTrue(error("target 'App' do\n  spm 'Firebase', exact: '13.0.1'\nend\n")?.message.contains("has several products") == true)
        XCTAssertTrue(error("target 'App' do\n  spm 'Nope', exact: '1.0.0'\nend\n")?.message.contains("is not in") == true)
        XCTAssertTrue(error("target 'App' do\n  source 'https://example.com/c.git'\nend\n")?.message.contains("cannot be used in a target") == true)
        XCTAssertTrue(error("source 'https://example.com/c.git', revision: 'main'\ntarget 'App' do\nend\n")?.message.contains("commit hash") == true)
        XCTAssertTrue(error("source 'https://example.com/c.git'\nsource 'https://example.com/c'\ntarget 'App' do\nend\n")?.message.contains("declared twice") == true)
        let noCatalog = try? ManifestReader(read: { _ in "target 'App' do\n  spm 'Datadog', exact: '1.0.0'\nend\n" }).load("/project/Podfile")
        XCTAssertNil(noCatalog, "Without a catalog, a package needs a location")
    }

    func testExplicitLocationsNeverConsultTheCatalog() throws {
        let manifest = try read("target 'App' do\n  spm 'Datadog', git: 'https://github.com/fork/dd-sdk-ios.git', exact: '3.15.0'\nend\n")
        XCTAssertEqual(manifest.packages[0].location, .remote(url: "https://github.com/fork/dd-sdk-ios.git"))
        XCTAssertNil(manifest.packages[0].catalog)
    }

    func testBinariesComeFromTheCatalogByVersion() throws {
        let manifest = try read("target 'App' do\n  binary 'hyprmx', '6.4.2'\nend\n")
        let binary = try XCTUnwrap(manifest.binaries.first)
        XCTAssertEqual(binary.name, "HyprMX")
        XCTAssertEqual(binary.source, .remote(url: "https://example.com/HyprMX-6.4.2.zip", sha256: String(repeating: "2", count: 64)))
        XCTAssertEqual(binary.systemFrameworks, ["WebKit"])
        XCTAssertEqual(binary.resources, ["HyprMX.bundle"])
        XCTAssertEqual(manifest.targets[0].binaries, ["HyprMX"])

        let missing = error("target 'App' do\n  binary 'HyprMX', '6.0.0'\nend\n")
        XCTAssertTrue(missing?.message.contains("no version 6.0.0") == true)
        XCTAssertEqual(missing?.hint, "Versions: 6.4.1, 6.4.2")
        XCTAssertTrue(error("target 'App' do\n  spm 'HyprMX', '6.4.2'\nend\n")?.message.contains("is a binary SDK") == true)
        XCTAssertTrue(error("target 'App' do\n  binary 'Datadog', '3.15.0'\nend\n")?.message.contains("is a Swift package") == true)
        XCTAssertTrue(error("target 'App' do\n  binary 'HyprMX', '6.4.2', libraries: ['z']\nend\n")?.message.contains("comes from the catalog") == true)
    }

    func testCatalogFiles() throws {
        let entry = try CatalogEntry.parse(
            "package 'Datadog', git: 'https://github.com/DataDog/dd-sdk-ios.git', products: %w[DatadogCore]\n",
            file: "Datadog.podfile", source: "s")
        XCTAssertEqual(entry, CatalogEntry(name: "Datadog", url: "https://github.com/DataDog/dd-sdk-ios.git", products: ["DatadogCore"], source: "s"))
        XCTAssertThrowsError(try CatalogEntry.parse("package 'X', git: 'https://x/X.git'\npackage 'Y', git: 'https://x/Y.git'\n", file: "X.podfile", source: "s"))
        XCTAssertThrowsError(try CatalogEntry.parse("package 'X', path: 'X'\n", file: "X.podfile", source: "s"))

        let both = try CatalogEntry.parse(
            """
            package 'Kit', git: 'https://github.com/a/Kit.git', products: ['Kit']
            binary 'Kit', libraries: ['z'] do
              version '1.0.0.0', url: 'https://example.com/Kit-1.0.0.0.zip', sha256: '\(String(repeating: "A", count: 64))'
            end
            """, file: "Kit.podfile", source: "s")
        XCTAssertEqual(both.url, "https://github.com/a/Kit.git")
        XCTAssertEqual(both.binary?.libraries, ["z"])
        XCTAssertEqual(both.binary?.releases, [.init(version: "1.0.0.0", url: "https://example.com/Kit-1.0.0.0.zip", sha256: String(repeating: "a", count: 64))])
        XCTAssertThrowsError(try CatalogEntry.parse("binary 'Kit' do\nend\n", file: "Kit.podfile", source: "s"))
        XCTAssertThrowsError(try CatalogEntry.parse("binary 'Kit' do\n  version '1', url: 'http://x/a.zip', sha256: '\(String(repeating: "a", count: 64))'\nend\n", file: "Kit.podfile", source: "s"))
        XCTAssertThrowsError(try CatalogEntry.parse("package 'Kit', git: 'https://x/Kit.git'\nbinary 'Other' do\n  version '1', url: 'https://x/a.zip', sha256: '\(String(repeating: "a", count: 64))'\nend\n", file: "Kit.podfile", source: "s"))
    }
}
