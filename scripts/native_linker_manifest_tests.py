#!/usr/bin/env python3
"""Build and execute consumers for static linking and manifest lifecycle regressions."""

import json
import shutil

from consumer_build_regressions import update_spec
from input_contract_regressions import commit, diagnostic, git
from native_integration import project
from native_lifecycle_tests import LifecycleFixture
from native_xcconfig_tests import create
from reporting import ROOT, execute
from vendor_fixture import fixture_derived_data, run
from workspace_resource_regressions import read_project


def podfile():
    return "platform :osx, '13.0'\nproject '../Apps/External.xcodeproj'\ntarget 'Demo' do\n pod 'Kit', :path => './Kit'\nend\n"


def fixture_project(fixture, name):
    work, selected = create(fixture.root / name)
    (work / "Podfile").write_text(podfile())
    (selected.parent / "Sources/main.mm").write_text("int main(void) { return 0; }\n")
    return work, selected


def application(fixture, label):
    return (
        fixture_derived_data(fixture.root / label)
        / "Build/Products/Debug/Demo.app/Contents/MacOS/Demo"
    )


def static_linking(fixture):
    for mode in ["library", "static", "dynamic"]:
        work, selected = fixture_project(fixture, "linker-" + mode)
        update_spec(
            work,
            source_files="*.{m,c,h}",
            libraries=["sqlite3"],
            frameworks=["Security"],
            weak_frameworks=["StoreKit"],
            pod_target_xcconfig={"CLANG_ENABLE_MODULES": "NO"},
        )
        (work / "Kit/Kit.c").write_text(
            "#include <sqlite3.h>\n#include <Security/SecRandom.h>\n"
            "int kit_value(void) { unsigned char byte; return sqlite3_libversion_number() > 0 "
            "&& SecRandomCopyBytes(kSecRandomDefault, 1, &byte) == 0 ? 7 : 1; }\n"
        )
        (work / "Kit/Category.h").write_text(
            "#import <Foundation/Foundation.h>\n@interface NSString (LinkerFixture)\n- (int)fixtureValue;\n@end\n"
        )
        (work / "Kit/Category.m").write_text(
            '#import "Category.h"\n@implementation NSString (LinkerFixture)\n- (int)fixtureValue { return 7; }\n@end\n'
            "int fixture_category_anchor = 1;\n"
        )
        (selected.parent / "Sources/main.mm").write_text(
            "#import <Kit/Category.h>\n#import <Kit/Kit.h>\nint main(void) { @autoreleasepool { "
            'return [@"value" fixtureValue] == 7 && kit_value() == 7 ? 0 : 1; } }\n'
        )
        if mode != "library":
            (work / "Podfile").write_text(
                "use_frameworks! :linkage => :" + mode + "\n" + podfile()
            )
        fixture.cli(work, "install")
        fixture.cli(work, "install", "--deployment", "--offline")
        label = "linker-build-" + mode
        fixture.build(work, "Demo", label)
        run(
            [application(fixture, label)],
            work,
            fixture.root / (label + "-run.log"),
            env=fixture.env,
        )
        fixture.verified.append(
            "category_sqlite_and_system_framework_consumer_executes_" + mode
        )


def uppercase_arc_and_optimization(fixture):
    work, selected = fixture_project(fixture, "arc-optimization")
    (work / "Kit/Kit.c").unlink()
    (work / "Kit/Kit.M").write_text(
        "#if __has_feature(objc_arc)\n#error ARC_must_be_disabled\n#endif\n"
        "#ifndef __OPTIMIZE__\n#error Requested_optimization_was_lost\n#endif\n"
        'extern "C" int kit_value(void) { return 7; }\n'
    )
    update_spec(
        work,
        source_files="*.{M,h}",
        requires_arc=["ARC/*.m"],
        pod_target_xcconfig={
            "GCC_OPTIMIZATION_LEVEL": "2",
            "SWIFT_OPTIMIZATION_LEVEL": "-Osize",
        },
    )
    (selected.parent / "Sources/main.mm").write_text(
        "#include <Kit/Kit.h>\nint main(void) { return kit_value() == 7 ? 0 : 1; }\n"
    )
    fixture.cli(work, "install")
    fixture.cli(work, "install", "--deployment")
    label = "arc-optimization-build"
    fixture.build(work, "Demo", label)
    run(
        [application(fixture, label)],
        work,
        fixture.root / (label + "-run.log"),
        env=fixture.env,
    )
    settings = run(
        [
            "xcodebuild",
            "-project",
            work / "Pods/Pods.xcodeproj",
            "-target",
            "Kit",
            "-configuration",
            "Debug",
            "-showBuildSettings",
        ],
        work,
        fixture.root / "optimization-settings.log",
        env=fixture.env,
    )
    assert (
        "GCC_OPTIMIZATION_LEVEL = 2" in settings
        and "SWIFT_OPTIMIZATION_LEVEL = -Osize" in settings
    )
    fixture.verified += [
        "uppercase_M_obeys_arc_masks_and_executes",
        "explicit_optimization_compiles_and_survives_xcode_settings",
    ]


def profile_selection(fixture):
    work, _ = fixture_project(fixture, "profile-selection")
    origin = work / "Kit"
    git(origin, "init", "-b", "main")
    revision = commit(origin, "Fixture")
    for version, extra in [("1.0", {}), ("2.0", {"cocoapods_version": ">= 9.0"})]:
        path = work / "specs/Kit" / version / "Kit.podspec.json"
        path.parent.mkdir(parents=True)
        path.write_text(
            json.dumps(
                {
                    "name": "Kit",
                    "version": version,
                    "platforms": {"osx": "13.0"},
                    "source_files": "*.{c,h}",
                    "source": {"git": str(origin), "commit": revision},
                    **extra,
                }
            )
        )
    body = "install! 'swiftpods', :integrate_targets => false\nsource './specs'\nplatform :osx, '13.0'\ntarget 'Demo' do\n pod 'Kit', '= 1.0'\nend\n"
    (work / "Podfile").write_text(body)
    fixture.cli(work, "install")
    fixture.cli(work, "install", "--deployment", "--offline")
    assert "Kit (1.0)" in (work / "Podfile.lock").read_text()
    (work / "Podfile").write_text(
        body.replace(", '= 1.0'", "")
        + "pre_install { |_| File.write('unexpected-hook', 'yes') }\n"
    )
    failed = fixture.cli(work, "update", succeeds=False)
    diagnostic(failed, "SP-SPEC-PROFILE")
    assert not (work / "unexpected-hook").exists()
    assert failed["project_state"] == "failed_no_managed_changes"
    diagnostic(
        fixture.cli(
            work,
            "lib",
            "lint",
            str(work / "specs/Kit/2.0/Kit.podspec.json"),
            "--quick",
            "--allow-warnings",
            succeeds=False,
        ),
        "SP-SPEC-PROFILE",
    )
    fixture.verified.append(
        "unselected_profile_requirement_is_ignored_but_selected_graph_and_quick_lint_reject_it"
    )


def manifest_selection(fixture):
    for name in [
        "Podfile",
        "CocoaPods.podfile",
        "Podfile.rb",
        "CocoaPods.podfile.yaml",
    ]:
        work, selected = fixture_project(fixture, "manifest-" + name)
        original = work / "Podfile"
        path = work / name
        if name == "CocoaPods.podfile.yaml":
            # Standard serialized CocoaPods target definitions; the abstract
            # Pods root must not become a second concrete consumer target.
            path.write_text("""---
installation_method:
  name: swiftpods
  options: {}
target_definitions:
  - name: Pods
    abstract: true
    platform:
      osx: '13.0'
    children:
      - name: Demo
        user_project_path: ../Apps/External.xcodeproj
        dependencies:
          - Kit:
              - path: ./Kit
""")
            original.unlink()
        elif name != "Podfile":
            original.rename(path)
        sub = work / "Nested"
        sub.mkdir()
        fixture.cli(sub, "install")
        fixture.cli(sub, "install", "--deployment", "--offline")
        report = json.loads((work / ".swiftpods/installation.json").read_text())
        assert report["input_manifest"] == str(path)
        assert report["targets"][0]["name"] == "Demo"
        assert not (sub / ".swiftpods").exists()
        if name in ["CocoaPods.podfile", "CocoaPods.podfile.yaml"]:
            original.write_text("raise 'Lower priority manifest must not execute'\n")
            fixture.cli(work, "install", "--deployment")
        diagnostic(fixture.cli(work, "init", succeeds=False), "SP-INIT-EXISTS")
        report = fixture.cli(work, "doctor", "--static")
        assert next(check for check in report["checks"] if check["name"] == "podfile")[
            "message"
        ] == str(path)
        path.write_text(path.read_text() + "\n")
        assert fixture.cli(work, "graph")["freshness"] == "stale"
        fixture.verified.append(
            "ancestor_manifest_install_deployment_priority_and_freshness_" + name
        )


def platform_graph(fixture):
    work, _ = fixture_project(fixture, "platform-graph")
    update_spec(
        work,
        platforms={"osx": "13.0", "ios": "15.0"},
        osx={"dependencies": {"MacHelper": ["= 1.0"]}},
        ios={"dependencies": {"IOSHelper": ["= 1.0"]}},
    )
    for name, platform, minimum in [
        ("MacHelper", "osx", "13.0"),
        ("IOSHelper", "ios", "15.0"),
    ]:
        helper = work / name
        helper.mkdir()
        (helper / "Value.c").write_text("void " + name + "(void) {}\n")
        (helper / (name + ".podspec.json")).write_text(
            json.dumps(
                {
                    "name": name,
                    "version": "1.0",
                    "platforms": {platform: minimum},
                    "source_files": "*.c",
                }
            )
        )
    body = "install! 'swiftpods', :integrate_targets => false\n"
    for name, platform, minimum in [("IOS", "ios", "15.0"), ("Mac", "osx", "13.0")]:
        body += f"target '{name}App' do\n platform :{platform}, '{minimum}'\n pod 'Kit', :path => './Kit'\n pod '{name}Helper', :path => './{name}Helper'\nend\n"
    (work / "Podfile").write_text(body)
    fixture.cli(work, "install")
    for name in ["IOS", "Mac"]:
        report = fixture.cli(work, "why", name + "Helper")
        chains = report["dependency_chains"]
        assert len(chains) == 2 and all(
            chain["target"] == name + "App" for chain in chains
        ), report
        assert any(
            [node["name"] for node in chain["nodes"]] == ["Kit", name + "Helper"]
            for chain in chains
        ), report
    fixture.verified.append(
        "why_retains_both_platform_graphs_without_cross_target_edges"
    )


def missing_project_cleanup(fixture):
    work, old = fixture_project(fixture, "missing-project")
    fixture.cli(work, "install")
    receipt = work / "Pods/Target Support Files/SwiftPods-Integration.json"
    legacy = json.loads(receipt.read_text())
    shutil.rmtree(old)
    current = old.with_name("Current.xcodeproj")
    project(current)
    (work / "Podfile").write_text(
        podfile().replace("External.xcodeproj", "Current.xcodeproj")
    )
    fixture.cli(work, "install")
    cleaned = json.loads(receipt.read_text())
    assert not any(str(old) in key for key in cleaned)
    for key in ["_base_configurations", "_swift_packages", "_project_attributes"]:
        assert not any(str(old) in path for path in cleaned.get(key, {}))
    # Also tolerate stale receipts written by an older executable.
    for key, value in legacy.items():
        if str(old) in key:
            cleaned[key] = value
    receipt.write_text(json.dumps(cleaned))
    fixture.cli(work, "deintegrate")
    assert not receipt.exists()
    objects = read_project(current)["objects"]
    assert not any(
        o.get("name") == "[CP] Check Pods Manifest.lock" for o in objects.values()
    )
    assert (work / "Kit/Kit.c").exists()
    fixture.cli(work, "install")
    fixture.verified.append(
        "deleted_project_receipts_are_pruned_and_legacy_deintegration_preserves_current_project"
    )


def main():
    fixture = LifecycleFixture()
    print("Linker and manifest fixtures:", fixture.root, flush=True)
    static_linking(fixture)
    uppercase_arc_and_optimization(fixture)
    profile_selection(fixture)
    manifest_selection(fixture)
    platform_graph(fixture)
    missing_project_cleanup(fixture)
    (ROOT / "test-results/native-linker-manifest.json").write_text(
        json.dumps(
            {
                "status": "passed",
                "fixture": str(fixture.root),
                "verified": fixture.verified,
                "unverified": ["signed distributions and device runtime matrix"],
            },
            indent=2,
        )
        + "\n"
    )


if __name__ == "__main__":
    execute(main, "native-linker-manifest.json")
