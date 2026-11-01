import Darwin
import Foundation
@testable import SwiftPodsManifest
import XCTest

private struct UntrustedBinaryCatalog: PackageCatalog {
    let url: String

    func entry(named name: String, in _: [Source]) throws -> CatalogEntry? {
        let sdk = CatalogEntry.BinarySDK(releases: [
            .init(version: "1.0.0", url: url, sha256: String(repeating: "a", count: 64))
        ])
        return CatalogEntry(name: name, url: nil, products: [], binary: sdk, source: Source.publicCatalog)
    }
}

private final class ManifestGraphSwapCatalog: PackageCatalog, @unchecked Sendable {
    private let first: String
    private let second: String
    private let lock = NSLock()

    init(first: URL, second: URL) {
        self.first = first.path
        self.second = second.path
    }

    func entry(named name: String, in _: [Source]) throws -> CatalogEntry? {
        if name == "SwitchToDecoy" || name == "RestoreOriginal" {
            lock.lock()
            defer { lock.unlock() }
            let result = first.withCString { firstPath in
                second.withCString { secondPath in
                    renameatx_np(AT_FDCWD, firstPath, AT_FDCWD, secondPath, UInt32(RENAME_SWAP))
                }
            }
            guard result == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        return CatalogEntry(
            name: name, url: "https://example.com/\(name).git", products: [name],
            source: Source.publicCatalog)
    }
}

final class SecurityRegressionTests: XCTestCase {
    private func read(_ podfile: String, files: [String: String] = [:]) throws -> Manifest {
        let all = files.merging(["/project/Podfile": podfile]) { _, new in new }
        return try ManifestReader(read: { path in
            guard let text = all[path] else { throw CocoaError(.fileReadNoSuchFile) }
            return text
        }).load("/project/Podfile")
    }

    private func error(_ podfile: String, files: [String: String] = [:]) -> ManifestError? {
        do {
            _ = try read(podfile, files: files)
            return nil
        } catch {
            return error as? ManifestError
        }
    }

    func testRevisionPinsMustBeFullObjectIDs() throws {
        let sha1 = String(repeating: "A", count: 40)
        let sha256 = String(repeating: "B", count: 64)
        let manifest = try read(
            "source 'https://example.com/catalog.git', revision: '\(sha1)'\n"
                + "target 'App' do\n  spm 'https://example.com/Kit.git', revision: '\(sha256)'\nend\n")
        XCTAssertEqual(manifest.sources[0].revision, sha1.lowercased())
        XCTAssertEqual(manifest.packages[0].requirement, .revision(sha256.lowercased()))

        XCTAssertTrue(error("source 'https://example.com/catalog.git', revision: 'abcdef1'\ntarget 'App' do\nend")?.message.contains("full 40- or 64-character") == true)
        XCTAssertTrue(error("target 'App' do\n  spm 'https://example.com/Kit.git', revision: 'abcdef1'\nend")?.message.contains("full 40- or 64-character") == true)
    }

    func testBranchNamesAreBoundedValidGitRefs() throws {
        let valid = try read("target 'App' do\n  spm 'Kit', git: 'https://example.com/Kit.git', branch: 'feature/ios-17'\nend\n")
        XCTAssertEqual(valid.packages[0].requirement, .branch("feature/ios-17"))
        for branch in ["bad\0name", "bad\u{c}name", "../main", "feature..old", "topic@{one", "-option"] {
            let problem = error(
                "target 'App' do\n  spm 'Kit', git: 'https://example.com/Kit.git', branch: \"\(branch)\"\nend\n")
            XCTAssertTrue(problem?.message.contains("valid Git branch") == true, branch)
        }
        let oversized = String(repeating: "a", count: 4_097)
        XCTAssertTrue(error(
            "target 'App' do\n  spm 'Kit', git: 'https://example.com/Kit.git', branch: '\(oversized)'\nend\n")?
            .message.contains("valid Git branch") == true)
    }

    func testRemoteLocationsUseSafeTransportsAndOrigins() throws {
        XCTAssertTrue(PackageLocation.isSafeRemote("https://example.com/Team/Kit.git"))
        XCTAssertTrue(PackageLocation.isSafeRemote("ssh://git@example.com:2222/Team/Kit.git"))
        XCTAssertTrue(PackageLocation.isSafeRemote("git@example.com:Team/Kit.git"))
        XCTAssertEqual(PackageLocation.identity("git@example.com:Kit.git"), "kit")
        XCTAssertTrue(PackageLocation.isSafeRemote("ssh://git@[2001:db8::1]:2222/Team/Kit.git"))
        XCTAssertTrue(PackageLocation.isSafeRemote("git@[2001:db8::1]:Team/Kit.git"))
        XCTAssertFalse(PackageLocation.isSafeRemote("http://example.com/Kit.git"))
        XCTAssertFalse(PackageLocation.isSafeRemote("git://example.com/Kit.git"))
        XCTAssertFalse(PackageLocation.isSafeRemote("https://token@example.com/Kit.git"))
        XCTAssertFalse(PackageLocation.isSafeRemote("https://example.com/Kit.git?ref=main"))
        XCTAssertFalse(PackageLocation.isSafeRemote("--upload-pack=helper.git"))
        XCTAssertFalse(PackageLocation.isSafeRemote("ssh://-oProxyCommand=helper@example.com/Kit.git"))
        XCTAssertFalse(PackageLocation.isSafeRemote("ssh://git@-oProxyCommand=helper/Kit.git"))
        XCTAssertFalse(PackageLocation.isSafeRemote("ssh://%2DoProxyCommand@example.com/Kit.git"))
        XCTAssertFalse(PackageLocation.isSafeRemote("ssh://git@%2Dhost/Kit.git"))
        XCTAssertFalse(PackageLocation.isSafeRemote("ssh://git@[fe80::1%25en0]/Kit.git"))
        XCTAssertFalse(PackageLocation.isSafeRemote("admin@example.com:Team/Kit.git"))
        XCTAssertFalse(PackageLocation.isSafeRemote("https://example.com:0/Kit.git"))
        XCTAssertFalse(PackageLocation.isSafeRemote("ssh://git@example.com:65536/Kit.git"))
        let https = try XCTUnwrap(PackageLocation.remoteEndpoint("https://example.com/Team/Kit.git"))
        XCTAssertEqual(https.transport, .https)
        XCTAssertEqual(https.host, "example.com")
        XCTAssertEqual(https.port, 443)
        let ssh = try XCTUnwrap(PackageLocation.remoteEndpoint(
            "ssh://git@[2001:4860:4860::8888]:2222/Team/Kit.git"))
        XCTAssertEqual(ssh.transport, .ssh)
        XCTAssertEqual(ssh.host, "2001:4860:4860::8888")
        XCTAssertEqual(ssh.port, 2222)
        let scp = try XCTUnwrap(PackageLocation.remoteEndpoint("git@example.com:Team/Kit.git"))
        XCTAssertEqual(scp.transport, .ssh)
        XCTAssertEqual(scp.host, "example.com")
        XCTAssertEqual(scp.port, 22)
        XCTAssertTrue(PackageLocation.isSafeCatalogSource("/tmp/local catalog"))
        XCTAssertTrue(PackageLocation.isSafeCatalogSource("file:///tmp/local%20catalog"))

        XCTAssertEqual(
            PackageLocation.fetchIdentity("https://EXAMPLE.com/Team/Kit.git"),
            PackageLocation.fetchIdentity("https://example.com/Team/Kit/"))
        XCTAssertNotEqual(
            PackageLocation.fetchIdentity("https://example.com/Team/Kit.git"),
            PackageLocation.fetchIdentity("https://example.com/team/Kit.git"))
        XCTAssertNotEqual(
            PackageLocation.fetchIdentity("https://example.com/Team/Kit.git"),
            PackageLocation.fetchIdentity("https://example.com/Team/Kit.GIT"))
        XCTAssertNotEqual(
            PackageLocation.fetchIdentity("https://example.com/Team/Kit.git"),
            PackageLocation.fetchIdentity("ssh://git@example.com/Team/Kit.git"))

        XCTAssertTrue(error("source '--upload-pack=helper.git'\ntarget 'App' do\nend")?.message.contains("HTTPS/SSH") == true)
        XCTAssertTrue(error("target 'App' do\n  spm 'http://example.com/Kit.git', exact: '1.0.0'\nend")?.message.contains("safe HTTPS or SSH") == true)
        XCTAssertTrue(
            error(
                "target 'App' do\n  spm 'https://example.com/Team/Kit.git', exact: '1.0.0'\nend\n"
                    + "target 'Tool' do\n  spm 'https://example.com/team/Kit.git', exact: '1.0.0'\nend")?
                .message.contains("Two packages have the identity `kit`") == true)
    }

    func testLocalCatalogSourceIdentityPreservesFilesystemCase() throws {
        let manifest = try read("""
            source '/tmp/Catalog/Foo.git'
            source '/tmp/catalog/foo'
            target 'App' do
            end
            """)
        XCTAssertEqual(manifest.sources.map(\.url), ["/tmp/Catalog/Foo.git", "/tmp/catalog/foo"])

        XCTAssertTrue(
            error("source '/tmp/Catalog'\nsource 'file:///tmp/Catalog'\ntarget 'App' do\nend\n")?
                .message.contains("is declared twice") == true)
    }

    func testBinaryDownloadURLsKeepSignedQueriesAndRejectAmbiguity() throws {
        let signed = "https://cdn.example.com/SDK.zip?X-Amz-Signature=abc%2F123&X-Amz-Expires=60"
        XCTAssertTrue(PackageLocation.isSafeHTTPSDownloadURL(signed))
        XCTAssertFalse(PackageLocation.isSafeHTTPSDownloadURL("https://token@cdn.example.com/SDK.zip"))
        XCTAssertFalse(PackageLocation.isSafeHTTPSDownloadURL("https://cdn.example.com/SDK.zip#other"))
        XCTAssertFalse(PackageLocation.isSafeHTTPSDownloadURL("https://cdn.example.com/SDK.zip\n"))
        XCTAssertFalse(PackageLocation.isSafeHTTPSDownloadURL("https:///SDK.zip"))

        XCTAssertTrue(PackageLocation.isSafeLocalFileURL("file:///tmp/SDK%20Archive.zip"))
        XCTAssertTrue(PackageLocation.isSafeLocalFileURL("file://localhost/tmp/SDK.zip"))
        XCTAssertFalse(PackageLocation.isSafeLocalFileURL("file://server/tmp/SDK.zip"))
        XCTAssertFalse(PackageLocation.isSafeLocalFileURL("file:///tmp/../secret.zip"))
        XCTAssertFalse(PackageLocation.isSafeLocalFileURL("file:///tmp%2Fsecret.zip"))
        XCTAssertFalse(PackageLocation.isSafeLocalFileURL("file:///tmp/SDK.zip?version=1"))

        let checksum = String(repeating: "a", count: 64)
        let remote = try read("target 'App' do\n  binary 'Kit', url: '\(signed)', sha256: '\(checksum)'\nend")
        XCTAssertEqual(remote.binaries[0].source, .remote(url: signed, sha256: checksum))
        let local = try read("target 'App' do\n  binary 'Kit', url: 'file:///tmp/SDK%20Archive.zip', sha256: '\(checksum)'\nend")
        XCTAssertEqual(local.binaries[0].source, .remote(url: "file:///tmp/SDK%20Archive.zip", sha256: checksum))

        for url in ["https://token@example.com/SDK.zip", "https://example.com/SDK.zip#fragment", "file://server/SDK.zip"] {
            let problem = error("target 'App' do\n  binary 'Kit', url: '\(url)', sha256: '\(checksum)'\nend")
            XCTAssertTrue(problem?.message.contains("safe HTTPS or local file URL") == true, url)
        }

        let catalogText = """
            binary 'Kit' do
              version '1.0.0', url: '\(signed)', sha256: '\(checksum)'
            end
            """
        XCTAssertNoThrow(try CatalogEntry.parse(catalogText, file: "Kit.podfile", source: "test"))
        XCTAssertThrowsError(
            try CatalogEntry.parse(
                catalogText.replacingOccurrences(of: signed, with: "https://token@example.com/SDK.zip"),
                file: "Kit.podfile", source: "test"))

        let untrusted = UntrustedBinaryCatalog(url: "https://token@example.com/SDK.zip")
        XCTAssertThrowsError(
            try ManifestReader(read: { _ in "target 'App' do\n  binary 'Kit', '1.0.0'\nend" }, catalog: untrusted)
                .load("/project/Podfile")) { error in
                    XCTAssertTrue("\(error)".contains("unsafe release URL"), "\(error)")
                }
    }

    func testArchivePathsAllowSpacesButRejectTraversalAndExpansion() throws {
        let manifest = try read(
            "target 'App' do\n"
                + "  binary 'Kit', path: 'Vendor Kit', xcframeworks: ['SDK 1/Kit.xcframework'], resources: ['SDK 1/Resource Bundle.bundle']\n"
                + "end\n")
        XCTAssertEqual(manifest.binaries[0].resources, ["SDK 1/Resource Bundle.bundle"])

        for path in ["../Secret.bundle", "/Secret.bundle", "SDK/$(id).bundle", "SDK/`id`.bundle"] {
            let problem = error("target 'App' do\n  binary 'Kit', path: 'Vendor', resources: ['\(path)']\nend")
            XCTAssertTrue(problem?.message.contains("safe relative .bundle path") == true, path)
        }
        let controlCharacter = """
            target 'App' do
              binary 'Kit', path: 'Vendor', resources: ["Bad\\n.bundle"]
            end
            """
        XCTAssertTrue(error(controlCharacter)?.message.contains("safe relative .bundle path") == true)
    }

    func testScriptEnvironmentLoggingIsOffByDefault() throws {
        let manifest = try read(
            "target 'App' do\n"
                + "  script_phase name: 'Default', script: 'true'\n"
                + "  script_phase name: 'Diagnostic', script: 'true', show_env_vars_in_log: true\n"
                + "end\n")
        XCTAssertFalse(manifest.targets[0].scriptPhases[0].showEnvironmentInLog)
        XCTAssertTrue(manifest.targets[0].scriptPhases[1].showEnvironmentInLog)
    }

    func testScriptBodiesHaveAPerPhaseSizeLimit() {
        let body = String(repeating: "x", count: 256 * 1_024 + 1)
        let problem = error("target 'App' do\n  script_phase name: 'Huge', script: '\(body)'\nend\n")
        XCTAssertTrue(problem?.message.contains("256 KiB") == true, problem?.description ?? "no error")
    }

    func testBuildSettingsCannotInjectXcconfigLinesOrSelectors() throws {
        let valid = try read(
            "target 'App' do\n"
                + "  settings 'SEARCH_PATHS' => ['$(inherited)', 'Path With Spaces']\n"
                + "  settings 'FLAGS' => 'NAME=\"value\" C:\\\\SDK', configurations: ['Debug QA']\n"
                + "end\n")
        XCTAssertEqual(valid.targets[0].settings[0].value, "$(inherited) \"Path With Spaces\"")
        XCTAssertEqual(valid.targets[0].settings[1].value, "NAME=\"value\" C:\\SDK")
        XCTAssertEqual(valid.targets[0].settings[1].configurations, ["Debug QA"])

        XCTAssertTrue(
            error("target 'App' do\n  settings 'A' => \"ok\\n#include \\\"Secrets.xcconfig\\\"\"\nend")?
                .message.contains("cannot contain control characters") == true)
        XCTAssertTrue(
            error("target 'App' do\n  settings 'A' => 'ok', configurations: [\"Debug\\nRelease\"]\nend")?
                .message.contains("Configuration names") == true)
        XCTAssertTrue(
            error("target 'App' do\n  settings 'A' => 'ok', configurations: ['Debug] = HACK']\nend")?
                .message.contains("Configuration names") == true)
        XCTAssertTrue(
            error("target 'App' do\n  settings 'A' => ['A\"B']\nend")?
                .message.contains("quotes or backslashes") == true)
        XCTAssertTrue(
            error(#"""
                target 'App' do
                  settings 'A' => ['A\\B']
                end
                """#)?.message.contains("quotes or backslashes") == true)
        XCTAssertTrue(
            error("target 'App' do\n  settings \"A[config=Debug\\n#include HACK]\" => 'ok'\nend")?
                .message.contains("not a build setting name") == true)
    }

    func testNamesAndProductsRejectControlCharacters() throws {
        let directName = error(
            "target 'App' do\n  spm \"Bad\\nName\", git: 'https://example.com/Kit.git', exact: '1.0.0'\nend")
        XCTAssertTrue(directName?.message.contains("package name") == true)

        let product = error(
            "target 'App' do\n  spm 'Kit', git: 'https://example.com/Kit.git', exact: '1.0.0', products: [\"Kit\\nInjected\"]\nend")
        XCTAssertTrue(product?.message.contains("bounded names") == true)

        XCTAssertThrowsError(
            try CatalogEntry.parse(
                "package \"Bad\\nName\", git: 'https://example.com/Kit.git'\n",
                file: "Kit.podfile", source: "test"))
        XCTAssertThrowsError(
            try CatalogEntry.parse(
                "package 'Kit', git: 'https://example.com/Kit.git', products: [\"Kit\\nInjected\"]\n",
                file: "Kit.podfile", source: "test"))
    }

    func testPathScopesPreserveIntendedSiblingAndXcodePaths() throws {
        let manifest = try read(
            "project 'Projects/My App'\n"
                + "target 'App' do\n"
                + "  spm 'Shared', path: '../Shared Kit'\n"
                + "  binary 'Vendor', path: 'Vendor SDK/Kit.xcframework'\n"
                + "  script_phase name: 'Build', script: 'true', shell_path: '/bin/zsh', input_files: ['$(SRCROOT)/Input File']\n"
                + "end\n")
        XCTAssertEqual(manifest.targets[0].project, "Projects/My App.xcodeproj")
        XCTAssertEqual(manifest.packages[0].location, .local(path: "../Shared Kit"))
        XCTAssertEqual(manifest.targets[0].scriptPhases[0].shellPath, "/bin/zsh")
        XCTAssertEqual(manifest.targets[0].scriptPhases[0].inputFiles, ["$(SRCROOT)/Input File"])

        XCTAssertTrue(error("project '../App'\ntarget 'App' do\nend")?.message.contains("inside the Podfile directory") == true)
        XCTAssertTrue(error("project '/tmp/App'\ntarget 'App' do\nend")?.message.contains("inside the Podfile directory") == true)
        XCTAssertTrue(
            error("target 'App' do\n  binary 'Kit', path: '../Vendor/Kit.xcframework'\nend")?.message.contains("inside the Podfile directory") == true)
        XCTAssertTrue(
            error("target 'App' do\n  spm 'Kit', path: '/tmp/Kit'\nend")?.message.contains("must be relative") == true)
        XCTAssertTrue(error("include '/tmp/shared.podfile'\n")?.message.contains("must be relative") == true)
    }

    func testCanonicalContainmentRejectsExistingSymlinkEscape() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftpods-containment-" + UUID().uuidString, isDirectory: true)
        let root = temporary.appendingPathComponent("root", isDirectory: true)
        let outside = temporary.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Escaped.xcodeproj"), withDestinationURL: outside)

        XCTAssertTrue(PackageLocation.isPath(root.appendingPathComponent("App.xcodeproj").path, containedIn: root.path))
        XCTAssertFalse(PackageLocation.isPath(outside.appendingPathComponent("App.xcodeproj").path, containedIn: root.path))
        XCTAssertFalse(PackageLocation.isPath(root.appendingPathComponent("Escaped.xcodeproj").path, containedIn: root.path))
    }

    func testIncludeAliasesCannotBypassCycleDetection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swiftpods-includes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let podfile = directory.appendingPathComponent("Podfile")
        try "include 'alias.podfile'\n".write(to: podfile, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("alias.podfile"), withDestinationURL: podfile)

        XCTAssertThrowsError(try ManifestReader().load(podfile.path)) { error in
            XCTAssertTrue("\(error)".contains("includes itself"), "\(error)")
        }
    }

    func testDefaultReaderRejectsNonRegularManifestFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftpods-non-regular-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try ManifestReader().load(directory.path)) { error in
            XCTAssertTrue("\(error)".contains("non-regular manifest file"), "\(error)")
        }

        let real = directory.appendingPathComponent("RealPodfile")
        try "target 'App' do\nend\n".write(to: real, atomically: true, encoding: .utf8)
        let symlink = directory.appendingPathComponent("LinkedPodfile")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: real)
        XCTAssertThrowsError(try ManifestReader().load(symlink.path)) { error in
            XCTAssertTrue("\(error)".contains("symbolic link manifest file"), "\(error)")
        }

        let fifo = directory.appendingPathComponent("FIFOPodfile")
        XCTAssertEqual(fifo.path.withCString { mkfifo($0, 0o600) }, 0)
        XCTAssertThrowsError(try ManifestReader().load(fifo.path)) { error in
            XCTAssertTrue("\(error)".contains("non-regular manifest file"), "\(error)")
        }

        let oversized = directory.appendingPathComponent("OversizedPodfile")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(8 * 1_024 * 1_024 + 1))
        try handle.close()
        XCTAssertThrowsError(try ManifestReader().load(oversized.path)) { error in
            XCTAssertTrue("\(error)".contains("large"), "\(error)")
        }

        let invalidUTF8 = directory.appendingPathComponent("InvalidPodfile")
        try Data([0xFF]).write(to: invalidUTF8)
        XCTAssertThrowsError(try ManifestReader().load(invalidUTF8.path))
    }

    func testUnrelatedAncestorChildMutationDoesNotChangeManifestPathIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftpods-ancestor-mutation-" + UUID().uuidString, isDirectory: true)
        let project = directory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let podfile = project.appendingPathComponent("Podfile")
        try "target 'App' do\nend\n".write(to: podfile, atomically: true, encoding: .utf8)
        let unrelated = directory.appendingPathComponent("unrelated", isDirectory: true)

        let manifest = try ManifestReader(beforeAncestorVerification: {
            try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        }).load(podfile.path)

        XCTAssertEqual(manifest.targets.map(\.name), ["App"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testCanonicalManifestPathsCannotInjectChecksumLines() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftpods-canonical-path-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let unsafe = directory.appendingPathComponent("line\nbreak", isDirectory: true)
        try FileManager.default.createDirectory(at: unsafe, withIntermediateDirectories: false)
        try "target 'App' do\nend\n".write(
            to: unsafe.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let alias = directory.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: unsafe)

        XCTAssertThrowsError(try ManifestReader().load(alias.appendingPathComponent("Podfile").path)) { error in
            XCTAssertTrue("\(error)".contains("canonical manifest path"), "\(error)")
        }
    }

    func testManifestPathsCannotChangeThroughParentSymlinksWhileRead() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftpods-path-race-" + UUID().uuidString, isDirectory: true)
        let first = directory.appendingPathComponent("first", isDirectory: true)
        let second = directory.appendingPathComponent("second", isDirectory: true)
        let alias = directory.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for target in [first, second] {
            try "target 'App' do\nend\n".write(
                to: target.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
            try "# included\n".write(
                to: target.appendingPathComponent("Part.podfile"), atomically: true, encoding: .utf8)
        }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)

        let aliasPath = alias.path
        let secondPath = second.path
        XCTAssertThrowsError(try ManifestReader(read: { _ in
            try FileManager.default.removeItem(atPath: aliasPath)
            try FileManager.default.createSymbolicLink(atPath: aliasPath, withDestinationPath: secondPath)
            return "target 'App' do\nend\n"
        }).load(alias.appendingPathComponent("Podfile").path)) { error in
            XCTAssertTrue("\(error)".contains("Manifest path changed while it was being read"), "\(error)")
        }

        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
        let rootPath = directory.appendingPathComponent("Podfile").path
        let includedPath = alias.appendingPathComponent("Part.podfile").path
        XCTAssertThrowsError(try ManifestReader(read: { path in
            if path == rootPath { return "include 'alias/Part.podfile'\n" }
            XCTAssertEqual(path, includedPath)
            try FileManager.default.removeItem(atPath: aliasPath)
            try FileManager.default.createSymbolicLink(atPath: aliasPath, withDestinationPath: secondPath)
            return "# included\n"
        }).load(rootPath)) { error in
            XCTAssertTrue("\(error)".contains("Included path changed while it was being read"), "\(error)")
        }
    }

    func testManifestGraphRejectsDirectoryABAAcrossSeparateFileReads() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftpods-graph-aba-" + UUID().uuidString, isDirectory: true)
        let live = directory.appendingPathComponent("live", isDirectory: true)
        let decoy = directory.appendingPathComponent("decoy", isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let podfile = """
        spm 'SwitchToDecoy', exact: '1.0.0'
        include 'Part.podfile'
        spm 'RestoreOriginal', exact: '1.0.0'
        target 'App' do
          use :shared
        end
        """
        try podfile.write(to: live.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        try podfile.write(to: decoy.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        try "group :shared do\n  settings 'GENERATION' => 'original'\nend\n".write(
            to: live.appendingPathComponent("Part.podfile"), atomically: true, encoding: .utf8)
        try "group :shared do\n  settings 'GENERATION' => 'decoy'\nend\n".write(
            to: decoy.appendingPathComponent("Part.podfile"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try ManifestReader(catalog: ManifestGraphSwapCatalog(first: live, second: decoy))
                .load(live.appendingPathComponent("Podfile").path)
        ) { error in
            XCTAssertTrue("\(error)".contains("manifest graph was being read"), "\(error)")
        }
    }

    func testIncludeDepthAndSizeAreBounded() {
        var files: [String: String] = [:]
        for index in 1...65 {
            files["/project/\(index).podfile"] = "include '\(index + 1).podfile'\n"
        }
        XCTAssertTrue(
            error("include '1.podfile'\n", files: files)?.message.contains("nested more than 64 levels") == true)

        let oversized = String(repeating: "#", count: 8 * 1_024 * 1_024 + 1)
        XCTAssertTrue(
            error("include 'large.podfile'\n", files: ["/project/large.podfile": oversized])?.message.contains("8 MiB limit") == true)
    }

    func testIncludeCountAndParserWorkAreGloballyBounded() {
        var manyFiles: [String: String] = [:]
        var manyIncludes = ""
        for index in 0..<256 {
            let name = "include-\(index).podfile"
            manyIncludes += "include '\(name)'\n"
            manyFiles["/project/\(name)"] = "# empty\n"
        }
        XCTAssertTrue(
            error(manyIncludes, files: manyFiles)?.message.contains("256-file limit") == true)

        var tokenFiles: [String: String] = [:]
        var tokenIncludes = ""
        for index in 0..<20 {
            let name = "tokens-\(index).podfile"
            tokenIncludes += "include '\(name)'\n"
            tokenFiles["/project/\(name)"] = String(repeating: ";", count: 11_000)
        }
        XCTAssertTrue(
            error(tokenIncludes, files: tokenFiles)?.message.contains("parser token budget") == true)
    }

    func testParserNestingTokenAndNodeBudgetsAreBounded() {
        let nestedArray = String(repeating: "[", count: 129) + "'value'" + String(repeating: "]", count: 129)
        XCTAssertTrue(
            error("target 'App' do\n  settings 'A' => \(nestedArray)\nend\n")?
                .message.contains("nested more than 128 levels") == true)

        let blocks = String(repeating: "group :nested do\n", count: 129)
            + String(repeating: "end\n", count: 129)
        XCTAssertTrue(error(blocks)?.message.contains("nested more than 128 levels") == true)

        let tooManyTokens = String(repeating: ";\n", count: 100_001)
        XCTAssertTrue(error(tooManyTokens)?.message.contains("parser token budget") == true)

        let words = String(repeating: "value ", count: 50_001)
        let tooManyNodes = "target 'App' do\n  spm 'Kit', path: 'Kit', products: %w[\(words)]\nend\n"
        XCTAssertTrue(error(tooManyNodes)?.message.contains("syntax node budget") == true)
    }

    func testGroupExpansionDepthAndWorkAreBounded() {
        var deep = ""
        for index in 0..<130 {
            deep += "group :g\(index) do\n"
            deep += index == 129 ? "  settings 'FLAG' => 'YES'\n" : "  use :g\(index + 1)\n"
            deep += "end\n"
        }
        deep += "target 'App' do\n  use :g0\nend\n"
        XCTAssertTrue(error(deep)?.message.contains("Group expansion is nested more than 128 levels") == true)

        var exponential = "group :g0 do\n  settings 'FLAG' => 'YES'\nend\n"
        for index in 1...18 {
            exponential += "group :g\(index) do\n  use :g\(index - 1)\n  use :g\(index - 1)\nend\n"
        }
        exponential += "target 'App' do\n  use :g18\nend\n"
        XCTAssertTrue(error(exponential)?.message.contains("Group expansion exceeds the work budget") == true)

        let parameters = (0..<1_025).map { "p\($0): true" }.joined(separator: ", ")
        XCTAssertTrue(
            error("group :many, \(parameters) do\nend\n")?.message
                .contains("cannot declare more than 1024 parameters") == true)

        let boundedParameters = (0..<1_024).map { "p\($0): true" }.joined(separator: ", ")
        let repeatedUses = String(repeating: "  use :many\n", count: 100)
        let parameterWork = "group :many, \(boundedParameters) do\nend\ntarget 'App' do\n\(repeatedUses)end\n"
        XCTAssertTrue(error(parameterWork)?.message.contains("Group expansion exceeds the work budget") == true)
    }

    func testExpandedTargetItemWorkIsBounded() {
        let frameworks = (0..<100).map { "'Framework\($0)'" }.joined(separator: ", ")
        let targets = (0..<2_000).map { "target 'App\($0)' do\nend\n" }.joined()
        let podfile = "binary 'SDK', path: 'SDK', system_frameworks: [\(frameworks)]\n" + targets
        XCTAssertTrue(error(podfile)?.message.contains("Expanded targets exceed the item budget") == true)
    }

    func testManifestKeepsTheExactParsedFileSnapshots() throws {
        let root = "include 'Shared.podfile'\ntarget 'App' do\n  use :shared\nend\n"
        let include = "group :shared do\n  settings 'FLAG' => 'YES'\nend\n"
        let manifest = try read(root, files: ["/project/Shared.podfile": include])
        XCTAssertEqual(manifest.files.map(\.path), ["/project/Podfile", "/project/Shared.podfile"])
        XCTAssertEqual(manifest.includes, ["/project/Shared.podfile"])
        XCTAssertEqual(manifest.files.map(\.contents), [Data(root.utf8), Data(include.utf8)])

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftpods-snapshot-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let podfile = directory.appendingPathComponent("Podfile")
        let first = "target 'App' do\nend\n"
        try Data(first.utf8).write(to: podfile)
        let loaded = try ManifestReader().load(podfile.path)
        try Data("target 'Changed' do\nend\n".utf8).write(to: podfile)
        XCTAssertEqual(loaded.files, [ManifestFile(path: podfile.path, contents: Data(first.utf8))])
    }

    func testManifestJSONDoesNotSerializeParsedFileContents() throws {
        let podfile = "# SNAPSHOT-ONLY-SECRET\ntarget 'App' do\nend\n"
        let manifest = try read(podfile)
        let encoded = try JSONEncoder().encode(manifest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["files"])
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("SNAPSHOT-ONLY-SECRET"))

        let decoded = try JSONDecoder().decode(Manifest.self, from: encoded)
        XCTAssertTrue(decoded.files.isEmpty)
        XCTAssertEqual(decoded, manifest)
    }
}
