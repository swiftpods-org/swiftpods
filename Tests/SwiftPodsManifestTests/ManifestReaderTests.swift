import SwiftPodsManifest
import XCTest

final class ManifestReaderTests: XCTestCase {
    private func read(_ podfile: String, files: [String: String] = [:]) throws -> Manifest {
        let all = files.merging(["/project/Podfile": podfile]) { _, new in new }
        let reader = ManifestReader { path in
            guard let text = all[path] else { throw CocoaError(.fileReadNoSuchFile) }
            return text
        }
        return try reader.load("/project/Podfile")
    }

    private func error(_ podfile: String, files: [String: String] = [:]) -> ManifestError? {
        do {
            _ = try read(podfile, files: files)
            return nil
        } catch {
            return error as? ManifestError
        }
    }

    private func assertError(
        _ podfile: String, _ message: String, line: Int? = nil, files: [String: String] = [:],
        file: StaticString = #filePath, sourceLine: UInt = #line
    ) {
        guard let error = error(podfile, files: files) else {
            return XCTFail("Expected an error containing '\(message)'", file: file, line: sourceLine)
        }
        XCTAssertTrue(error.message.contains(message), error.description, file: file, line: sourceLine)
        if let line { XCTAssertEqual(error.location?.line, line, error.description, file: file, line: sourceLine) }
    }

    func testPinnedPackageOverrideSeparatesProjectReferenceFromTargetProducts() throws {
        let revision = String(repeating: "A", count: 64)
        let manifest = try read("""
            group :graph do
              spm 'https://example.com/OverrideKit.git', revision: '\(revision)', override: true, submodules: true
            end
            target 'App' do
              use :graph
            end
            target 'Tool' do
              spm 'https://example.com/OverrideKit.git', revision: '\(revision)', override: true,
                  submodules: true, products: ['Kit'], link: false
            end
            target 'Unrelated' do
            end
            """)
        XCTAssertEqual(manifest.packages.count, 1)
        XCTAssertEqual(manifest.packages.first?.location, .pinnedOverride(
            url: "https://example.com/OverrideKit.git", revision: revision.lowercased(), submodules: true))
        XCTAssertNil(manifest.packages.first?.requirement)
        XCTAssertEqual(manifest.targets.map(\.packageOverrides), [["overridekit"], ["overridekit"], nil])
        XCTAssertTrue(manifest.targets[0].products.isEmpty)
        XCTAssertEqual(manifest.targets[1].products.map(\.product), ["Kit"])
        XCTAssertEqual(manifest.targets[1].products.map(\.link), [false])
    }

    func testPinnedPackageOverrideDiagnostics() {
        let url = "https://example.com/OverrideKit.git"
        let revision = String(repeating: "a", count: 40)
        for options in [
            "override: true",
            "branch: 'main', override: true",
            "revision: '\(revision)', version: '1.0', override: true",
            "revision: '\(revision)', exact: '1.0', override: true",
            "'1.0', revision: '\(revision)', override: true",
            "revision: '\(revision)', path: 'Vendor/OverrideKit', override: true",
        ] {
            assertError("target 'App' do\n  spm '\(url)', \(options)\nend", "requires a Git URL and only a full", line: 2)
        }
        assertError("target 'App' do\nspm '\(url)', revision: 'abc123', override: true\nend", "full 40- or 64-character")
        assertError("target 'App' do\nspm '\(url)', branch: 'main', submodules: true\nend", "requires `override: true`")
        assertError("target 'App' do\nspm 'OverrideKit', revision: '\(revision)', override: true\nend", "requires a Git URL")
        for conflicting in [
            "spm '\(url)', revision: '\(revision)'",
            "spm 'Other', path: 'Vendor/overridekit'",
            "spm '\(url)', revision: '\(revision)', override: true, submodules: true",
        ] {
            let problem = error("""
                target 'App' do
                  spm '\(url)', revision: '\(revision)', override: true
                  \(conflicting)
                end
                """)
            XCTAssertEqual(problem?.location?.line, 3)
            XCTAssertEqual(problem?.related?.line, 2)
            XCTAssertNotNil(problem?.hint)
        }
    }

    func testSharedGroupsFromIncludedFiles() throws {
        let manifest = try read(
            """
            platform :ios, '15.4'
            project 'IPHONE_PROJ_SOL5'

            include '../SwiftPods/sdks.podfile'

            target 'Target_SOL5' do
              use :firebase, :ads
              settings 'IPHONEOS_DEPLOYMENT_TARGET' => '15.4'
            end
            """,
            files: [
                "/SwiftPods/sdks.podfile": """
                group :firebase do
                  spm 'Firebase',
                      :git => 'https://github.com/firebase/firebase-ios-sdk.git',
                      :exact => '13.0.1',
                      :products => %w[FirebaseCore FirebaseAnalytics]
                end

                group :ads do
                  spm 'https://github.com/AppLovin/AppLovin-MAX-Swift-Package.git', '~> 13.6', products: ['AppLovinSDK']
                  binary 'HyprMXAdapter', url: 'https://example.com/hyprmx.zip',
                         sha256: '\(String(repeating: "A", count: 64))', linker_flags: ['-ObjC']
                end
                """
            ])
        XCTAssertEqual(manifest.packages.map(\.identity), ["firebase-ios-sdk", "applovin-max-swift-package"])
        XCTAssertEqual(manifest.packages[0].requirement, .exact(Version(13, 0, 1)))
        XCTAssertEqual(manifest.packages[1].requirement, .upToNextMajor(Version(13, 6, 0)))
        XCTAssertEqual(manifest.packages[1].name, "AppLovin-MAX-Swift-Package")
        XCTAssertEqual(manifest.binaries.map(\.name), ["HyprMXAdapter"])
        XCTAssertEqual(manifest.binaries[0].source, .remote(url: "https://example.com/hyprmx.zip", sha256: String(repeating: "a", count: 64)))
        XCTAssertEqual(manifest.packages[0].declaredAt.file, "/SwiftPods/sdks.podfile")

        let target = try XCTUnwrap(manifest.targets.first)
        XCTAssertEqual(target.project, "IPHONE_PROJ_SOL5.xcodeproj")
        XCTAssertEqual(target.platform, Platform(name: .ios, deploymentTarget: "15.4"))
        XCTAssertEqual(target.products.map(\.product), ["FirebaseCore", "FirebaseAnalytics", "AppLovinSDK"])
        XCTAssertEqual(target.binaries, ["HyprMXAdapter"])
        XCTAssertEqual(target.settings.map(\.key), ["IPHONEOS_DEPLOYMENT_TARGET"])
    }

    func testGroupParameters() throws {
        let manifest = try read(
            """
            include '../Shared/ads.podfile'

            target 'Game' do
              use :ads
            end

            target 'Lite' do
              use :ads, amazon: false
            end

            target 'Full' do
              use :ads, bigo: true
            end
            """,
            files: [
                "/Shared/ads.podfile": """
                group :ads, amazon: true, bigo: false do
                  spm 'https://github.com/AppLovin/AppLovin-MAX-Swift-Package.git', '13.6.4', products: ['AppLovinSDK']
                  with :amazon do
                    spm 'https://github.com/example/amazon.git', '5.6.4', products: ['Amazon']
                  end
                  with :bigo do
                    spm 'https://github.com/example/bigo.git', '5.3.0', products: ['Bigo']
                  end
                end
                """
            ])
        XCTAssertEqual(
            manifest.targets.map { $0.products.map(\.product) },
            [["AppLovinSDK", "Amazon"], ["AppLovinSDK"], ["AppLovinSDK", "Amazon", "Bigo"]])

        assertError("group :a, amazon: 'yes' do\nend", "must be true or false")
        assertError("group :a do\n  with :amazon do\n  end\nend", "Group `a` has no parameter `amazon`", line: 2)
        assertError("group :a, x: true do\nend\ntarget 'App' do\n  use :a, y: false\nend", "Group `a` has no parameter `y`", line: 4)
        assertError("group :a, x: true do\nend\ngroup :b do\nend\ntarget 'App' do\n  use :a, :b, x: false\nend", "Parameters apply to one group")
        assertError("target 'App' do\n  with :x do\n  end\nend", "`with` cannot be used in a target")
    }

    func testPlatformFromAnIncludedFile() throws {
        let manifest = try read(
            "include '../Shared/defaults.podfile'\n\ntarget 'App' do\nend",
            files: ["/Shared/defaults.podfile": "platform :ios, '15.4'"])
        XCTAssertEqual(manifest.targets[0].platform, Platform(name: .ios, deploymentTarget: "15.4"))
    }

    func testGeneratedMenginePodfileWithNestedTargets() throws {
        let manifest = try read(
            """
            # Generated by Mengine; rerun make-solution after changing SDK declarations.
            platform :osx, '12.0'
            project 'Mengine_Xcode_MacOS'

            target 'MacOSApplication' do
              spm 'Sentry', :git => 'https://github.com/getsentry/sentry-cocoa.git', :exact => '9.19.1', :products => ['Sentry']
              script_phase :name => 'Upload symbols', :script => 'upload "${DWARF_DSYM_FOLDER_PATH}"', :execution_position => :after_compile
              target 'MacOSSentryPlugin' do
              end
              target 'MacOSStandalonePlugin' do
                inherit! :none
              end
            end
            """)
        XCTAssertEqual(manifest.targets.map(\.name), ["MacOSApplication", "MacOSSentryPlugin", "MacOSStandalonePlugin"])
        XCTAssertEqual(manifest.targets[0].platform?.name, .macos)
        XCTAssertEqual(manifest.targets[0].scriptPhases.map(\.position), [.afterCompile])
        XCTAssertEqual(manifest.targets[1].products, [ProductUse(package: "sentry-cocoa", product: "Sentry", link: true)])
        XCTAssertTrue(manifest.targets[1].scriptPhases.isEmpty, "A concrete parent's script phases stay on the parent")
        XCTAssertTrue(manifest.targets[2].products.isEmpty)
    }

    func testAbstractTargetsShareSettingsAndRootDependencies() throws {
        let manifest = try read(
            """
            spm 'https://github.com/apple/swift-collections.git', from: '1.1.0', products: ['Collections']

            abstract_target 'Shared' do
              settings 'OTHER_LDFLAGS' => ['$(inherited)', '-ObjC']
              settings 'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => 'BETA', configurations: 'Beta'
              target 'App' do
                spm 'Local', path: '../Local'
              end
              target 'Widget' do
                inherit! :none
              end
            end
            """)
        let app = manifest.targets[0]
        XCTAssertEqual(app.products.map(\.product), ["Collections", "Local"])
        XCTAssertEqual(app.settings.map(\.value), ["$(inherited) -ObjC", "BETA"])
        XCTAssertEqual(app.settings[1].configurations, ["Beta"])
        XCTAssertEqual(manifest.packages[1].location, .local(path: "../Local"))
        XCTAssertNil(manifest.packages[1].requirement)
        let widget = manifest.targets[1]
        XCTAssertTrue(widget.products.isEmpty)
        XCTAssertEqual(widget.settings.count, 2, "Settings of abstract scopes apply regardless of inherit!")
    }

    func testRequirementForms() throws {
        let cases: [(String, Requirement)] = [
            ("'1.2.3'", .exact(Version(1, 2, 3))),
            ("'= 1.2'", .exact(Version(1, 2, 0))),
            ("'~> 1'", .upToNextMajor(Version(1, 0, 0))),
            ("'~> 1.2'", .upToNextMajor(Version(1, 2, 0))),
            ("'~> 1.2.3'", .upToNextMinor(Version(1, 2, 3))),
            ("'>= 1.2', '< 3.0'", .range(Version(1, 2, 0), Version(3, 0, 0))),
            ("exact: '2.0.0-beta.1'", .exact(Version(2, 0, 0, prerelease: ["beta", "1"]))),
            ("up_to_next_minor: '1.4.0'", .upToNextMinor(Version(1, 4, 0))),
            ("range: ['1.0', '2.0']", .range(Version(1, 0, 0), Version(2, 0, 0))),
            ("branch: 'main'", .branch("main")),
            ("revision: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'", .revision("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")),
        ]
        for (text, expected) in cases {
            let manifest = try read("target 'App' do\n  spm 'https://example.com/a/Kit.git', \(text)\nend")
            XCTAssertEqual(manifest.packages.first?.requirement, expected, text)
            XCTAssertEqual(manifest.targets[0].products.first?.product, "Kit")
        }
    }

    func testRequirementsAllowVersions() {
        XCTAssertTrue(Requirement.upToNextMajor(Version(1, 2, 0)).allows(Version(1, 9, 9)))
        XCTAssertFalse(Requirement.upToNextMajor(Version(1, 2, 0)).allows(Version(2, 0, 0)))
        XCTAssertFalse(Requirement.upToNextMinor(Version(1, 2, 3)).allows(Version(1, 3, 0)))
        XCTAssertTrue(Requirement.range(Version(1, 0, 0), Version(2, 0, 0)).allows(Version(1, 0, 0)))
        XCTAssertTrue(Version(1, 0, 0, prerelease: ["beta", "2"]) < Version(1, 0, 0, prerelease: ["beta", "10"]))
        XCTAssertTrue(Version(1, 0, 0, prerelease: ["rc"]) < Version(1, 0, 0))
        XCTAssertNil(Version("1.2.3.4"))
    }

    func testMultilineArgumentsAndParentheses() throws {
        let manifest = try read(
            """
            target('App') do
              spm(
                'Kit',
                git: 'git@github.com:example/Kit.git',
                exact: '1.0.0',
              )
              script_phase name: 'Lint',
                           script: "swiftlint\\n",
                           input_files: [
                             '$(SRCROOT)/Sources',
                           ]
            end
            """)
        XCTAssertEqual(manifest.packages.first?.location, .remote(url: "git@github.com:example/Kit.git"))
        XCTAssertEqual(manifest.targets[0].scriptPhases.first?.script, "swiftlint\n")
        XCTAssertEqual(manifest.targets[0].scriptPhases.first?.inputFiles, ["$(SRCROOT)/Sources"])
    }

    func testCocoaPodsAndRubyConstructsAreRejectedWithHints() {
        assertError("target 'App' do\n  pod 'Alamofire', '~> 5.0'\nend", "CocoaPods pods are not supported", line: 2)
        assertError("post_install do |installer|\nend", "Install hooks are not supported", line: 1)
        assertError("use_frameworks! :linkage => :static", "decides how packages link")
        assertError("def all_pods\nend", "Methods are not supported")
        assertError("require_relative '../SwiftPods/Firebase'", "`require_relative` is not supported")
        assertError("VERSION = '1.0'", "Variables are not supported")
        assertError("platform :ios, MURKA_IOS_DEPLOYMENT_TARGET", "'MURKA_IOS_DEPLOYMENT_TARGET' is not a value")
        assertError("target \"App#{1}\" do\nend", "String interpolation is not supported")
        assertError("target 'App' do\n  if amazon\n  end\nend", "Conditionals are not supported", line: 2)
        assertError("target 'App' do\n  spm 'Kit', git: 'https://x/Kit.git', exact: '1.0.0', configurations: ['Debug']\nend", "Per-configuration linking")
        assertError("target 'App' do\n  inherit! :search_paths\nend", "not supported yet")
    }

    func testDeclarationErrors() {
        assertError("target 'App' do\n  spm 'https://x/Kit.git'\nend", "needs a version requirement", line: 2)
        assertError("target 'App' do\n  spm 'https://x/Kit.git', '>= 1.0'\nend", "has no upper bound")
        assertError("target 'App' do\n  spm 'https://x/Kit.git', '13.9.0.0'\nend", "not a version Swift Package Manager accepts")
        assertError("target 'App' do\n  spm 'https://x/Kit.git', '1.0.0', exact: '1.0.0'\nend", "more than one version requirement")
        assertError("target 'App' do\n  spm 'Kit', path: 'Kit', exact: '1.0.0'\nend", "takes no version requirement")
        assertError("target 'App' do\n  spm 'https://x/Kit.git', exact: '1.0.0', product: ['Kit']\nend", "has no option `product`")
        assertError("target 'App' do\nend\ntarget 'App' do\nend", "declared twice", line: 3)
        assertError("target 'App' do\n  binary 'Bad-Name', path: 'x'\nend", "not a valid binary name")
        assertError(
            "target 'App' do\n  binary 'Kit', url: 'http://x/a.zip', sha256: '\(String(repeating: "0", count: 64))'\nend",
            "must be a safe HTTPS or local file URL")
        assertError("target 'App' do\n  binary 'Kit', url: 'https://x/a.zip'\nend", "needs `url` and `sha256`")
        assertError("target 'App' do\n  binary 'Kit', path: 'Kit.xcframework', dependencies: ['Other']\nend", "undeclared binary `Other`")
        assertError("target 'App' do\n  spm 'Kit', git: 'https://x/Kit.git'\n", "Missing `end`")
        assertError("", "declares no targets")
    }

    func testConflictsNameBothDeclarations() throws {
        let packages = error(
            """
            target 'App' do
              spm 'https://github.com/a/Kit.git', exact: '1.0.0'
            end
            target 'Tool' do
              spm 'https://github.com/a/Kit', exact: '1.1.0'
            end
            """)
        XCTAssertEqual(packages?.location?.line, 5)
        XCTAssertEqual(packages?.related?.line, 2)
        XCTAssertTrue(packages?.message.contains("different requirements") == true)

        assertError(
            "target 'App' do\n  spm 'https://github.com/a/Kit.git', exact: '1.0.0'\n  spm 'https://gitlab.com/b/Kit.git', exact: '1.0.0'\nend",
            "Two packages have the identity `kit`")
        assertError(
            "group :a do\n  settings 'K' => '1'\nend\ngroup :b do\n  settings 'K' => '2'\nend\ntarget 'App' do\n  use :a, :b\nend",
            "sets K twice")

        let same = try read(
            """
            target 'App' do
              spm 'https://github.com/a/Kit.git', exact: '1.0.0'
              target 'Tests' do
                spm 'https://github.com/a/Kit.git', exact: '1.0.0', products: ['KitTesting']
              end
            end
            """)
        XCTAssertEqual(same.packages.count, 1)
        XCTAssertEqual(same.targets[1].products.map(\.product), ["Kit", "KitTesting"])
    }

    func testLexerFollowsRubyForContinuationsInterpolationAndWordArrays() throws {
        let crlf = try read("target 'App' do\r\n  spm 'https://x/Kit.git', \\\r\n      exact: '1.0.0'\r\nend\r\n")
        XCTAssertEqual(crlf.packages.first?.requirement, .exact(Version(1, 0, 0)))

        assertError("target 'App' do\n  script_phase name: 'A', script: \"echo #$HOME\"\nend", "String interpolation is not supported", line: 2)
        assertError("target 'App' do\n  script_phase name: 'A', script: \"echo #@x\"\nend", "String interpolation is not supported", line: 2)
        let escaped = try read("target 'App' do\n  script_phase name: 'A', script: \"echo \\#$HOME\"\n  script_phase name: 'B', script: 'echo #$HOME'\nend")
        XCTAssertEqual(escaped.targets[0].scriptPhases.map(\.script), ["echo #$HOME", "echo #$HOME"])
        // Ruby interpolates only a variable name, or one of its special globals, after `#$` and `#@`.
        for interpolated in ["#$1", "#$_x", "#$?", "#$-w", "#@@x", "#@_x", "#$\\", "#{x}"] {
            assertError("target 'App' do\n  script_phase name: 'A', script: \"\(interpolated)\"\nend",
                        "String interpolation is not supported", line: 2)
        }
        let literal = ["-DTAG=#$(TAG)", "#@1", "a #@ b", "#$ ", "#$-1", "#@@1", "#"]
        let literals = try read("target 'App' do\n" + literal.enumerated().map {
            "  script_phase name: '\($0.offset)', script: \"\($0.element)\"\n"
        }.joined() + "end")
        XCTAssertEqual(literals.targets[0].scriptPhases.map(\.script), literal)

        assertError("target 'App' do\n  spm 'Kit', path: 'Kit', products: %w[A\\ B]\nend", "Escapes are not supported in %w literals", line: 2)
    }

    func testLocalPackageIdentityIsTheStandardizedDirectoryName() throws {
        func manifest(_ podfile: String, at path: String) throws -> Manifest {
            try ManifestReader(read: { _ in podfile }).load(path)
        }
        let parent = try manifest("target 'App' do\n  spm 'MyLib', path: '..'\nend\n", at: "/work/MyLib/Example/Podfile")
        XCTAssertEqual(parent.packages.first?.identity, "mylib")
        let nested = try manifest("target 'App' do\n  spm 'Kit', path: 'Vendor/Kit'\nend\n", at: "/work/App/Podfile")
        XCTAssertEqual(nested.packages.first?.identity, "kit")

        assertError(
            "target 'App' do\n  spm 'Local', path: 'Modules/MyLib/..'\n  spm 'https://github.com/a/Modules.git', exact: '1.0.0'\nend",
            "Two packages have the identity `modules`")
    }

    func testBinaryDependencyCyclesAreRejected() {
        assertError(
            """
            target 'App' do
              binary 'A', path: 'A.xcframework', dependencies: ['B']
              binary 'B', path: 'B.xcframework', dependencies: ['C']
              binary 'C', path: 'C.xcframework', dependencies: ['A']
            end
            """,
            "Binary dependencies form a cycle: `A` → `B` → `C` → `A`")
        XCTAssertNoThrow(try read(
            """
            target 'App' do
              binary 'A', path: 'A.xcframework', dependencies: ['B', 'C']
              binary 'B', path: 'B.xcframework', dependencies: ['C']
              binary 'C', path: 'C.xcframework'
            end
            """))
    }

    func testConfigurationSelectorsInSettingKeysAreConfigurations() throws {
        assertError(
            "target 'App' do\n  settings 'A[config=Debug]' => '1'\n  settings 'A' => '2', configurations: ['Debug']\nend",
            "sets A twice")
        assertError("target 'App' do\n  settings 'A[config=Debug]' => '1', configurations: ['Release']\nend", "restricts its configurations twice")
        let manifest = try read("target 'App' do\n  settings 'A[sdk=iphoneos*][config=Debug]' => '1'\n  settings 'A' => '2', configurations: ['Release']\nend")
        let settings = manifest.targets[0].settings
        XCTAssertEqual(settings.map(\.key), ["A[sdk=iphoneos*]", "A"])
        XCTAssertEqual(settings.map(\.configurations), [["Debug"], ["Release"]])

        // A value for some configurations refines the one for all of them, in either spelling and order.
        let refined = try read("""
            target 'App' do
              settings 'OTHER_LDFLAGS[config=Debug]' => '-ObjC -lz', 'OTHER_LDFLAGS' => '-ObjC'
              settings 'OTHER_LDFLAGS' => '-ObjC -lc++', configurations: ['Release']
            end
            """)
        XCTAssertEqual(refined.targets[0].settings.map(\.key), ["OTHER_LDFLAGS", "OTHER_LDFLAGS", "OTHER_LDFLAGS"])
        XCTAssertEqual(refined.targets[0].settings.map(\.configurations), [["Debug"], nil, ["Release"]])
        assertError("target 'App' do\n  settings 'A' => '1'\n  settings 'A' => '2'\nend", "sets A twice")
        assertError(
            "target 'App' do\n  settings 'A' => '1', configurations: ['Debug', 'Release']\n  settings 'A[config=Release]' => '2'\nend",
            "sets A twice")
    }

    func testTheReferenceOpeningExampleReads() throws {
        let reference = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/Podfile.md")
        let text = try String(contentsOf: reference, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "```ruby\n"))
        let end = try XCTUnwrap(text.range(of: "```", range: start.upperBound..<text.endIndex))
        let example = String(text[start.upperBound..<end.lowerBound])
        let ads = "group :ads do\n  spm 'https://github.com/AppLovin/AppLovin-MAX-Swift-Package.git', '~> 13.6', products: ['AppLovinSDK']\nend\n"
        let manifest = try read(example, files: ["/Shared/ads.podfile": ads])
        XCTAssertEqual(manifest.targets.map(\.name), ["Game", "GameTests"])
    }

    func testGroupsAndIncludes() {
        assertError("group :a do\n  use :b\nend\ngroup :b do\n  use :a\nend\ntarget 'App' do\n  use :a\nend", "cycle")
        assertError("target 'App' do\n  use :missing\nend", "Unknown group `missing`")
        assertError("include 'a.podfile'", "includes itself", files: ["/project/a.podfile": "include 'a.podfile'"])
        assertError("include 'a.podfile'", "may only contain `platform`, `group` and `include`", files: ["/project/a.podfile": "target 'App' do\nend"])
        assertError("platform :ios, '15.0'\ninclude 'a.podfile'", "`platform` is declared twice", files: ["/project/a.podfile": "platform :ios, '16.0'"])
        assertError("include 'missing.podfile'", "Cannot read included file")
        assertError("group :a do\nend\ngroup :a do\nend", "Group `a` is declared twice", line: 3)
    }
}
