#!/usr/bin/env python3
"""Exercise Swift negotiation, native headers, public hooks, lint and publication."""

import json
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

from batch_fixture import user_project
from bootstrap import ROOT, environment
from processes import run_captured
from reporting import execute


def graph(path):
    return json.loads(
        subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(path)])
    )


def main():
    parent = Path(tempfile.mkdtemp(prefix="native-contract-", dir=ROOT / ".build"))
    print("Contract fixtures:", parent, flush=True)
    work = parent / "project"
    work.mkdir()
    env = environment()
    env["SWIFTPODS_CACHE_ROOT"] = str(parent / "cache")
    env.update(
        GIT_AUTHOR_NAME="Fixture",
        GIT_AUTHOR_EMAIL="fixture@swiftpods.org",
        GIT_COMMITTER_NAME="Fixture",
        GIT_COMMITTER_EMAIL="fixture@swiftpods.org",
    )
    binary = ROOT / ".build/debug/swiftpods"
    sequence = 0

    def cli(*args, success=True, directory=work):
        nonlocal sequence
        sequence += 1
        result = run_captured(
            [str(binary), *map(str, args), "--json"],
            directory,
            parent / ("cli-" + str(sequence)),
            env=env,
            timeout=180,
        )
        assert (result.returncode == 0) == success, (args, result.stdout, result.stderr)
        return json.loads(result.stdout)

    def data(value, kind="inspection"):
        return next(event["data"] for event in value["events"] if event["kind"] == kind)

    def build(project="Demo.xcodeproj", target="Demo", configuration="Debug"):
        command = [
            "xcodebuild",
            "-project",
            str(work / project),
            "-target",
            target,
            "-configuration",
            configuration,
            "-sdk",
            "macosx",
            "build",
            "CODE_SIGNING_ALLOWED=NO",
            "GCC_TREAT_WARNINGS_AS_ERRORS=YES",
            "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES",
            "SYMROOT=" + str(work / "products"),
        ]
        result = subprocess.run(
            command, cwd=work, env=env, capture_output=True, text=True, timeout=180
        )
        log = parent / ("build-" + target + "-" + configuration + ".log")
        log.write_text(result.stdout + result.stderr)
        assert (
            result.returncode == 0 and " warning:" not in result.stdout + result.stderr
        ), log

    user_project(work, "Demo")
    sources = work / "Sources"
    sources.mkdir()
    module = work / "NativeKit"
    module.mkdir()
    for folder, value in [("Left", 11), ("Right", 22)]:
        directory = module / "include" / folder
        directory.mkdir(parents=True)
        directory.joinpath("Common.h").write_text(
            f"#pragma once\nstatic inline int contract_{folder.lower()}(void) {{ return {value}; }}\n"
        )
    module.joinpath("include/NativeKit.h").write_text(
        '#pragma once\n#include "Left/Common.h"\n#include "Right/Common.h"\n#ifdef __cplusplus\nextern "C" {\n#endif\nint swift_contract_value(void);\n#ifdef __cplusplus\n}\n#endif\n'
    )
    module.joinpath("Value.swift").write_text(
        '@_cdecl("swift_contract_value") public func value() -> Int32 {\n#if swift(>=6.0)\nreturn 6\n#else\nreturn 5\n#endif\n}\n'
    )
    shutil.copy2(
        ROOT / "Tests/Fixtures/iOS/FixtureIntent.swift", module / "FixtureIntent.swift"
    )
    source = {
        "name": "NativeKit",
        "version": "1.0",
        "summary": "A contract fixture.",
        "homepage": "https://swiftpods.org",
        "authors": "SwiftPods",
        "license": {"type": "MIT", "text": "Fixture"},
        "source": {"git": str(parent / "origin"), "tag": "1.0"},
        "source_files": ["Value.swift", "include/**/*.h"],
        "public_header_files": "include/**/*.h",
        "header_mappings_dir": "include",
        "header_dir": "PublicKit",
        "swift_versions": ["5.0", "6.0"],
        "osx": {"deployment_target": "13.0"},
    }
    source["source_files"].append("FixtureIntent.swift")
    source["module_name"] = "NativeKit"
    spec = module / "NativeKit.podspec.json"
    spec.write_text(json.dumps(source))
    sources.joinpath("main.mm").write_text(
        '#import <Foundation/Foundation.h>\n#if __has_include(<PublicKit/NativeKit.h>)\n#import <PublicKit/NativeKit.h>\n#else\n#import <NativeKit/NativeKit.h>\n#endif\n#include <stdio.h>\nint main(void) { printf("%d:%d:%d\\n", swift_contract_value(), contract_left(), contract_right()); return 0; }\n'
    )
    manifest = """project 'Demo'
require 'cocoapods'
require 'cocoapods/installer'
require 'cocoapods-core/specification'
raise 'External engine activated' if Gem.loaded_specs.key?('cocoapods') || Gem.loaded_specs.key?('cocoapods-core')
raise 'Wrong API contract' unless Pod::VERSION == '1.17.0'
supports_swift_versions '>= 5', '< 6'
use_frameworks! :linkage => :dynamic
install! 'swiftpods', :share_schemes_for_development_pods => true, :disable_input_output_paths => true
target 'Demo' do
  pod 'NativeKit', :path => './NativeKit', :configurations => ['Debug']
end
pre_install do |installer|
  raise 'Options missing' unless installer.installation_options.clean? && installer.installation_options.disable_input_output_paths?
  $pod = installer.pod_targets.fetch(0)
  $spec = $pod.root_spec
  $aggregate = installer.aggregate_targets.fetch(0)
  raise 'Platform inference missing' unless $aggregate.platform.name == :osx && $pod.swift_version == '5.0'
  raise 'BuildType missing' unless $pod.build_type == Pod::BuildType.dynamic_framework && $pod.build_as_dynamic_framework?
  raise 'Spec version missing' unless $spec.version == Pod::Version.new('1.0')
  raise 'Spec checksum missing' unless $spec.checksum == Digest::SHA1.file(installer.sandbox.specification_path('NativeKit')).hexdigest
  raise 'Accessor missing' unless $pod.file_accessors.any? { |accessor| accessor.source_files.any? { |path| path.extname == '.swift' } }
end
post_install do |installer|
  pod = installer.pod_targets.fetch(0)
  raise 'Public object identity changed' unless pod.equal?($pod) && pod.root_spec.equal?($spec) && installer.aggregate_targets.fetch(0).equal?($aggregate)
  raise 'Native target missing' unless pod.native_target.is_a?(Xcodeproj::Project::Object::PBXNativeTarget)
  raise 'Installation results missing' unless installer.target_installation_results.pod_target_installation_results[pod.name].native_target.equal?(pod.native_target)
  pod.native_target.build_configurations.each { |config| config.build_settings['CONTRACT_HOOK'] = 'ok' }
  user = installer.aggregate_targets.fetch(0).user_project
  user.native_targets.fetch(0).build_configurations.each { |config| config.build_settings['CONSUMER_HOOK'] = 'ok' }
end
"""
    work.joinpath("Podfile").write_text(manifest)
    cli("install")
    pods = graph(work / "Pods/Pods.xcodeproj/project.pbxproj")["objects"]
    configs = [
        obj["buildSettings"]
        for obj in pods.values()
        if obj["isa"] == "XCBuildConfiguration"
        and obj.get("buildSettings", {}).get("PRODUCT_NAME") == "NativeKit"
    ]
    assert configs and all(
        c["SWIFT_VERSION"] == "5.0" and c["CONTRACT_HOOK"] == "ok" for c in configs
    )
    assert work.joinpath(
        "Pods/Pods.xcodeproj/xcshareddata/xcschemes/NativeKit.xcscheme"
    ).exists()
    user = graph(work / "Demo.xcodeproj/project.pbxproj")["objects"]
    checks = [
        obj
        for obj in user.values()
        if obj["isa"] == "PBXShellScriptBuildPhase"
        and obj.get("name", "").startswith("[SwiftPods]")
    ]
    assert checks and all(
        obj.get("alwaysOutOfDate") == "1"
        and not obj.get("inputPaths")
        and not obj.get("outputPaths")
        for obj in checks
    )
    assert any(
        obj.get("buildSettings", {}).get("CONSUMER_HOOK") == "ok"
        for obj in user.values()
    )
    assert all(
        obj.get("baseConfigurationReference") in user
        for obj in user.values()
        if obj["isa"] == "XCBuildConfiguration"
        and obj.get("buildSettings", {}).get("PRODUCT_NAME") == "Demo"
    )
    build("Pods/Pods.xcodeproj", "NativeKit")
    build()
    assert (
        subprocess.check_output(
            [str(work / "products/Debug/Demo.app/Contents/MacOS/Demo")], text=True
        ).strip()
        == "5:11:22"
    )
    # A hook's singleton build_type override changes the generated native product.
    override = "\npre_install do |installer|\n  installer.pod_targets.each { |pod| def pod.build_type; Pod::BuildType.static_library; end }\nend\n"
    work.joinpath("Podfile").write_text(manifest.split("pre_install do")[0] + override)
    cli("install")
    pods = graph(work / "Pods/Pods.xcodeproj/project.pbxproj")["objects"]
    assert any(
        obj.get("productType") == "com.apple.product-type.library.static"
        for obj in pods.values()
    )
    public = list(work.glob("Pods/Headers/Public/*/PublicKit/Left/Common.h"))
    assert public and public[0].resolve() == module / "include/Left/Common.h"
    build("Pods/Pods.xcodeproj", "NativeKit")
    build()
    assert (
        subprocess.check_output(
            [str(work / "products/Debug/Demo.app/Contents/MacOS/Demo")], text=True
        ).strip()
        == "5:11:22"
    )
    # DSL errors are explicit, and supports_swift_versions has an observable effect.
    work.joinpath("Invalid.Podfile").write_text(
        "install! 'swiftpods', :unknown_option => true\n"
    )
    cli("ipc", "podfile", "Invalid.Podfile", success=False)
    for declaration in [
        "ensure_bundler!",
        "target 'X', :bad => true",
        "target 'X' do\n install! 'swiftpods'\nend",
        "platform :unknown",
    ]:
        work.joinpath("Invalid.Podfile").write_text(declaration + "\n")
        cli("ipc", "podfile", "Invalid.Podfile", success=False)
    work.joinpath("Invalid.Podfile").write_text(
        "platform :ios\nabstract_target 'Shared' do\n supports_swift_versions '>= 5'\n target 'App'\nend\n"
    )
    parsed = data(cli("ipc", "podfile", "Invalid.Podfile"))
    assert parsed["targets"][0]["platform"]["deployment_target"] == "4.3" and parsed[
        "targets"
    ][0]["swift_version_requirements"] == [">= 5"]
    # Lint builds both local source and the source declared by a spec.
    origin = parent / "origin"
    shutil.copytree(module, origin)
    subprocess.run(
        ["git", "init", "-b", "main", str(origin)],
        check=True,
        capture_output=True,
        env=env,
    )

    def git(directory, *args):
        return subprocess.check_output(
            ["git", "-C", str(directory), *args],
            env=env,
            stderr=subprocess.PIPE,
            text=True,
        ).strip()

    git(origin, "add", ".")
    git(origin, "commit", "-m", "Fixture")
    git(origin, "tag", "1.0")
    assert data(cli("lib", "lint", spec, "--platforms=osx"), "validation")[
        "specifications"
    ][0]["built_platforms"] == ["osx"]
    assert data(cli("spec", "lint", spec, "--platforms=osx"), "validation")[
        "specifications"
    ][0]["built_platforms"] == ["osx"]
    lint_tests = module / "LintTests"
    lint_tests.mkdir()
    lint_tests.joinpath("Failure.m").write_text(
        "#import <XCTest/XCTest.h>\n@interface SwiftPodsLintFailure : XCTestCase @end\n@implementation SwiftPodsLintFailure\n- (void)testFailure { XCTAssertEqual(1, 2); }\n@end\n"
    )
    lint_spec = module / "Lint.podspec.json"
    lint_data = dict(source)
    lint_data["testspecs"] = [{"name": "Failing", "source_files": "LintTests/*.m"}]
    lint_spec.write_text(json.dumps(lint_data))
    rejected_lint = cli("lib", "lint", lint_spec, "--platforms=osx", success=False)
    assert any(
        event.get("code") == "SP-LINT-TEST" for event in rejected_lint["events"]
    ), rejected_lint
    skipped_lint = data(
        cli("lib", "lint", lint_spec, "--platforms=osx", "--skip-tests"), "validation"
    )
    assert skipped_lint["specifications"][0]["tested_schemes"] == []
    lint_spec.unlink()
    broken = module / "Broken.podspec.json"
    bad = dict(source)
    bad.pop("summary")
    broken.write_text(json.dumps(bad))
    cli("spec", "lint", broken, "--quick", success=False)
    broken.unlink()
    bare = parent / "specs.git"
    subprocess.run(
        ["git", "init", "--bare", "--initial-branch=main", str(bare)],
        check=True,
        capture_output=True,
        env=env,
    )
    seed = parent / "seed"
    subprocess.run(
        ["git", "clone", str(bare), str(seed)], check=True, capture_output=True, env=env
    )
    seed.joinpath("README.md").write_text("Fixture specs\n")
    git(seed, "add", ".")
    git(seed, "commit", "-m", "Initial")
    git(seed, "push", "origin", "main")
    cli("repo", "add", "publication", bare, "main")
    published = data(
        cli("repo", "push", "publication", spec, "--quick", "--platforms", "osx"),
        "publication",
    )
    assert published["pushed"] is True
    saved = git(bare, "show", "main:NativeKit/1.0/NativeKit.podspec.json")
    assert json.loads(saved)["version"] == "1.0"
    registered = parent / "cache/repositories/publication"
    before = git(registered, "rev-parse", "HEAD")
    rejection = bare / "hooks/pre-receive"
    rejection.write_text("#!/bin/sh\nexit 1\n")
    rejection.chmod(0o755)
    changed = dict(source)
    changed["version"] = "2.0"
    spec.write_text(json.dumps(changed))
    cli("repo", "push", "publication", spec, "--quick", success=False)
    assert (
        git(registered, "rev-parse", "HEAD") == before
        and not registered.joinpath("NativeKit/2.0").exists()
    )
    rejection.unlink()
    spec.write_text(json.dumps(source))
    cli("repo", "push", "publication", spec, "--quick", success=False)
    checkout = parent / "cache/repositories/publication"
    checkout.joinpath("dirty").write_text("keep")
    cli("repo", "push", "publication", spec, "--quick", success=False)
    assert checkout.joinpath("dirty").read_text() == "keep"
    # Xcode must produce actual asset packs from the emitted on-demand tags.
    mobile = parent / "on-demand"
    mobile.mkdir()
    user_project(mobile, "Demo", "ios")
    mobile.joinpath("Sources").mkdir()
    mobile.joinpath("Sources/main.mm").write_text("int main(void) { return 0; }\n")
    shutil.copy2(
        ROOT / "Tests/Fixtures/iOS/FixtureIntent.swift",
        mobile / "Sources/FixtureIntent.swift",
    )
    mobile.joinpath("Info.plist").write_bytes(
        plistlib.dumps(
            {
                "CFBundleExecutable": "$(EXECUTABLE_NAME)",
                "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
                "CFBundleName": "Demo",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1",
                "UILaunchScreen": {},
                "UISupportedInterfaceOrientations": [
                    "UIInterfaceOrientationPortrait",
                    "UIInterfaceOrientationPortraitUpsideDown",
                    "UIInterfaceOrientationLandscapeLeft",
                    "UIInterfaceOrientationLandscapeRight",
                ],
            }
        )
    )
    kit = mobile / "ODRKit"
    kit.mkdir()
    kit.joinpath("Value.c").write_text("int odr_value(void) { return 1; }\n")
    kit.joinpath("initial.txt").write_text("initial")
    kit.joinpath("prefetch.txt").write_text("prefetch")
    kit.joinpath("ODRKit.podspec.json").write_text(
        json.dumps(
            {
                "name": "ODRKit",
                "version": "1.0",
                "source_files": "*.c",
                "on_demand_resources": {
                    "initial": {"paths": "initial.txt", "category": "initial_install"},
                    "prefetch": {"paths": "prefetch.txt", "category": "prefetched"},
                },
            }
        )
    )
    mobile.joinpath("Podfile").write_text(
        "platform :ios, '15.0'\ntarget 'Demo' do\n pod 'ODRKit', :path => './ODRKit'\nend\n"
    )
    cli("install", directory=mobile)
    command = [
        "xcodebuild",
        "-workspace",
        "Demo.xcworkspace",
        "-scheme",
        "Demo",
        "-configuration",
        "Release",
        "-destination",
        "generic/platform=iOS",
        "-sdk",
        "iphoneos",
        "build",
        "CODE_SIGNING_ALLOWED=NO",
        "GCC_TREAT_WARNINGS_AS_ERRORS=YES",
        "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES",
        "SYMROOT=" + str(mobile / "products"),
    ]
    result = subprocess.run(
        command, cwd=mobile, env=env, capture_output=True, text=True, timeout=180
    )
    parent.joinpath("on-demand-build.log").write_text(result.stdout + result.stderr)
    assert (
        result.returncode == 0 and " warning:" not in result.stdout + result.stderr
    ), parent / "on-demand-build.log"
    assert list(mobile.glob("products/**/*.assetpack/initial.txt")) and list(
        mobile.glob("products/**/*.assetpack/prefetch.txt")
    )
    cli("deintegrate", directory=mobile)
    objects = graph(mobile / "Demo.xcodeproj/project.pbxproj")["objects"]
    assert not any(
        obj.get("buildSettings", {}).get("ENABLE_ON_DEMAND_RESOURCES")
        for obj in objects.values()
    )
    report = {
        "status": "passed",
        "engine": "swift",
        "fixture": str(parent),
        "verified": [
            "implicit platform and project extension analysis",
            "Swift requirements affect actual compiled Swift language mode",
            "nested framework/static-library header mappings",
            "public Installer PodTarget Specification AggregateTarget identity",
            "typed BuildType and singleton pre_install override",
            "live consumer and pod project mutations",
            "development scheme sharing and disabled managed phase paths",
            "DSL options and negative requirements",
            "native lib/spec lint with actual Xcode builds",
            "repo push preserves lint option values and immutable versions",
            "rejected remote push preserves the registered checkout",
            "iOS device build produces tagged on-demand asset packs and deintegration restores settings",
            "fresh consumer configurations attach aggregate xcconfig files",
        ],
        "unverified": [
            "remote publication authentication",
            "arbitrary private plugin APIs",
        ],
    }
    ROOT.joinpath("test-results/native-contract.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    execute(main, "native-contract.json")
