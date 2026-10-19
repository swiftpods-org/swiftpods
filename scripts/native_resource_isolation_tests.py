#!/usr/bin/env python3
"""Build resource ownership/exclusion and configuration-specific ODR regressions."""

import json
import platform
import plistlib
import shutil

from consumer_build_regressions import update_spec
from native_integration import project
from native_lifecycle_tests import LifecycleFixture
from native_linker_manifest_tests import fixture_project, podfile
from reporting import ROOT, execute
from vendor_fixture import fixture_build_arguments, fixture_derived_data, run
from workspace_resource_regressions import read_project


def build(
    fixture, work, scheme, label, configuration="Debug", mobile=False, test=False
):
    parent = fixture.root / label
    parent.mkdir(exist_ok=True)
    run(
        [
            "xcodebuild",
            "-workspace",
            next(work.glob("*.xcworkspace")),
            "-scheme",
            scheme,
            "-configuration",
            configuration,
            "-destination",
            "generic/platform=iOS"
            if mobile
            else "platform=macOS,arch=" + platform.machine(),
            *(["-sdk", "iphoneos"] if mobile else []),
            *fixture_build_arguments(parent),
            "CODE_SIGNING_ALLOWED=NO",
            "test" if test else "build",
        ],
        work,
        fixture.root / (label + "-" + configuration + ".log"),
        env=fixture.env,
    )
    return (
        fixture_derived_data(parent)
        / "Build/Products"
        / (configuration + ("-iphoneos" if mobile else ""))
    )


def install_twice(fixture, work, selected):
    fixture.cli(work, "install")
    locked = (work / "Podfile.lock").read_bytes()
    before = (selected / "project.pbxproj").read_bytes()
    fixture.cli(work, "install", "--deployment", "--offline")
    assert (work / "Podfile.lock").read_bytes() == locked
    assert (selected / "project.pbxproj").read_bytes() == before


def supplementary(fixture, mode):
    work, selected = fixture_project(fixture, "resource-mac-" + mode)
    declarations = {}
    for directory, name in [("App", "Example"), ("Test", "Checks")]:
        root = work / "Kit" / directory
        (root / "Hidden").mkdir(parents=True)
        (root / "Bundle").mkdir()
        for file, content in [
            ("keep.txt", directory),
            ("secret.txt", "excluded"),
            ("Hidden/deep.txt", "excluded directory"),
            ("Bundle/bundle.txt", directory),
            ("Bundle/secret-bundle.txt", "excluded bundle"),
        ]:
            (root / file).write_text(content)
        declarations[directory] = {
            "name": name,
            "source_files": directory + "/*.m",
            "resources": [directory + "/*.txt", directory + "/Hidden"],
            "resource_bundles": {"Own": directory + "/Bundle/*.txt"},
            "exclude_files": [
                directory + "/secret.txt",
                directory + "/Hidden",
                directory + "/Bundle/secret-bundle.txt",
            ],
        }
    checks = (
        'NSURL *keep = [bundle URLForResource:@"keep" withExtension:@"txt"];\n'
        'NSURL *own = [bundle URLForResource:@"Own" withExtension:@"bundle"];\n'
        "NSBundle *ownBundle = own ? [NSBundle bundleWithURL:own] : nil;\n"
        "NSString *text = keep ? [NSString stringWithContentsOfURL:keep encoding:NSUTF8StringEncoding error:NULL] : nil;\n"
        'BOOL valid = [text isEqualToString:@"EXPECTED"] && own != nil\n'
        ' && [bundle URLForResource:@"secret" withExtension:@"txt"] == nil\n'
        ' && ![[NSFileManager defaultManager] fileExistsAtPath:[[bundle resourcePath] stringByAppendingPathComponent:@"Hidden"]]\n'
        ' && [ownBundle URLForResource:@"bundle" withExtension:@"txt"] != nil\n'
        ' && [ownBundle URLForResource:@"secret-bundle" withExtension:@"txt"] == nil;\n'
    )
    (work / "Kit/App/Main.m").write_text(
        "#import <Foundation/Foundation.h>\nint main(void) { @autoreleasepool {\n"
        "NSBundle *bundle = [NSBundle mainBundle];\n"
        + checks.replace("EXPECTED", "App")
        + "return valid ? 0 : 1; } }\n"
    )
    (work / "Kit/Test/Checks.m").write_text(
        "#import <XCTest/XCTest.h>\n@interface ResourceChecks : XCTestCase\n@end\n"
        "@implementation ResourceChecks\n- (void)testOwnedResources {\n"
        "NSBundle *bundle = [NSBundle bundleForClass:[self class]];\n"
        + checks.replace("EXPECTED", "Test")
        + "XCTAssertTrue(valid);\n}\n@end\n"
    )
    update_spec(work, appspecs=[declarations["App"]], testspecs=[declarations["Test"]])
    text = (
        podfile()
        .replace("'13.0'", "'14.0'")
        .replace(
            ":path => './Kit'",
            ":path => './Kit', :appspecs => ['Example'], :testspecs => ['Checks']",
        )
    )
    (work / "Podfile").write_text(
        ("use_frameworks! :linkage => :" + mode + "\n" if mode != "library" else "")
        + text
    )
    install_twice(fixture, work, selected)
    products = build(fixture, work, "Kit-Example", "resource-app-build-" + mode)
    app = products / "Kit-Example.app"
    run(
        [app / "Contents/MacOS/Kit-Example"],
        work,
        fixture.root / ("resource-app-run-" + mode + ".log"),
        env=fixture.env,
    )
    build(fixture, work, "Kit-Unit-Checks", "resource-test-build-" + mode, test=True)
    fixture.verified.extend(
        [
            "app_spec_executes_with_owned_exclusions_and_bundle_contents_" + mode,
            "test_spec_executes_xctest_with_owned_exclusions_and_bundle_contents_"
            + mode,
            "supplementary_resource_project_and_lock_are_stable_offline_" + mode,
        ]
    )


def mobile_project(fixture, mode):
    work = fixture.root / ("resource-ios-" + mode)
    work.mkdir()
    selected = work / "Demo.xcodeproj"
    project(selected, "ios")
    (work / "Sources").mkdir()
    (work / "Sources/main.mm").write_text("int main(void) { return 0; }\n")
    shutil.copy2(
        ROOT / "Tests/Fixtures/iOS/FixtureIntent.swift",
        work / "Sources/FixtureIntent.swift",
    )
    (work / "Info.plist").write_bytes(
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
    kit = work / "Kit"
    for directory in [
        kit / "A",
        kit / "B",
        kit / "Peer",
        kit / "Folder",
        kit / "en.lproj",
    ]:
        directory.mkdir(parents=True)
    for name in [
        "root.txt",
        "A/a.txt",
        "A/shared.txt",
        "A/hidden.txt",
        "B/b.txt",
        "Peer/peer.txt",
        "Folder/nested.txt",
        "en.lproj/localized.txt",
        "en.lproj/hidden-locale.txt",
    ]:
        (kit / name).write_text(name)
    (kit / "Kit.c").write_text("int kit_value(void) { return 7; }\n")
    (kit / "Peer.c").write_text("int peer_value(void) { return 8; }\n")
    (kit / "Kit.podspec.json").write_text(
        json.dumps(
            {
                "name": "Kit",
                "version": "1.0",
                "source_files": "Kit.c",
                "exclude_files": "en.lproj/hidden-locale.txt",
                "on_demand_resources": {
                    "common": {"paths": "root.txt", "category": "initial_install"},
                    "folder": {"paths": "Folder/nested.txt", "category": "prefetched"},
                    "locale": {"paths": "en.lproj", "category": "prefetched"},
                },
                "subspecs": [
                    {
                        "name": "A",
                        "exclude_files": ["A/hidden.txt", "B/*"],
                        "on_demand_resources": {
                            "common": {
                                "paths": "A/*.txt",
                                "category": "initial_install",
                            },
                            "alpha": {
                                "paths": "A/shared.txt",
                                "category": "prefetched",
                            },
                        },
                    },
                    {
                        "name": "B",
                        "exclude_files": "root.txt",
                        "on_demand_resources": {
                            "common": {
                                "paths": "B/*.txt",
                                "category": "initial_install",
                            },
                        },
                    },
                ],
            }
        )
    )
    # Two local podspecs intentionally share one physical resource path.
    (kit / "Peer.podspec.json").write_text(
        json.dumps(
            {
                "name": "Peer",
                "version": "1.0",
                "source_files": "Peer.c",
                "resources": ["A/shared.txt", "Folder", "en.lproj/localized.txt"],
                "on_demand_resources": {
                    "peer": {"paths": "Peer/peer.txt", "category": "prefetched"}
                },
            }
        )
    )
    text = "use_frameworks! :linkage => :" + mode + "\n" if mode != "library" else ""
    text += "platform :ios, '15.0'\ntarget 'Demo' do\n pod 'Kit', :path => './Kit', :configurations => ['Debug']\n pod 'Peer', :path => './Kit'\nend\n"
    (work / "Podfile").write_text(text)
    return work, selected


def assets(products):
    observed = {}
    for pack in products.rglob("*.assetpack"):
        tags = sorted(plistlib.loads((pack / "Info.plist").read_bytes())["Tags"])
        assert all("$(" not in tag for tag in tags), tags
        for path in pack.rglob("*.txt"):
            if path.name == "localized.txt":
                assert path.parent.name == "en.lproj", path
            assert path.name not in observed, (path, observed)
            observed[path.name] = {"tags": tags, "content": path.read_text()}
    app = products / "Demo.app"
    for path in app.rglob("*.txt"):
        relative = path.relative_to(app).as_posix()
        assert relative not in observed, (path, observed)
        observed[relative] = {"tags": [], "content": path.read_text()}
    return observed


def category_settings(work, configuration, kit_enabled):
    path = (
        work
        / "Pods/Target Support Files/Pods-Demo"
        / ("Pods-Demo." + configuration.lower() + ".xcconfig")
    )
    values = {
        key.strip(): value.strip()
        for line in path.read_text().splitlines()
        if "=" in line
        for key, value in [line.split("=", 1)]
    }
    assert values.get("ENABLE_ON_DEMAND_RESOURCES") == "YES"
    assert values.get("ON_DEMAND_RESOURCES_INITIAL_INSTALL_TAGS", "") == (
        "common" if kit_enabled else ""
    )
    assert values.get("ON_DEMAND_RESOURCES_PREFETCH_ORDER") == (
        "alpha folder locale peer" if kit_enabled else "peer"
    )


def conditional_odr(fixture, mode, observations):
    work, selected = mobile_project(fixture, mode)
    install_twice(fixture, work, selected)
    prefix = "Frameworks/Peer.framework/" if mode == "dynamic" else ""
    full = {
        "root.txt": {"tags": ["common"], "content": "root.txt"},
        "a.txt": {"tags": ["common"], "content": "A/a.txt"},
        "b.txt": {"tags": ["common"], "content": "B/b.txt"},
        "shared.txt": {"tags": ["alpha", "common"], "content": "A/shared.txt"},
        "peer.txt": {"tags": ["peer"], "content": "Peer/peer.txt"},
        "nested.txt": {"tags": ["folder"], "content": "Folder/nested.txt"},
        prefix + "Folder/nested.txt": {"tags": [], "content": "Folder/nested.txt"},
        "localized.txt": {"tags": ["locale"], "content": "en.lproj/localized.txt"},
    }
    if mode == "dynamic":
        full[prefix + "shared.txt"] = {"tags": [], "content": "A/shared.txt"}
        full[prefix + "en.lproj/localized.txt"] = {
            "tags": [],
            "content": "en.lproj/localized.txt",
        }
    limited = {
        prefix + "shared.txt": {"tags": [], "content": "A/shared.txt"},
        "peer.txt": {"tags": ["peer"], "content": "Peer/peer.txt"},
        prefix + "Folder/nested.txt": {"tags": [], "content": "Folder/nested.txt"},
        prefix + "en.lproj/localized.txt": {
            "tags": [],
            "content": "en.lproj/localized.txt",
        },
    }
    for configuration, expected in [("Debug", full), ("Release", limited)]:
        category_settings(work, configuration, configuration == "Debug")
        products = build(
            fixture,
            work,
            "Demo",
            "resource-odr-build-" + mode,
            configuration,
            mobile=True,
        )
        observed = assets(products)
        assert observed == expected, (mode, configuration, observed, expected)
        observations[mode + "-" + configuration] = observed
    (work / "Podfile").write_text(
        (work / "Podfile").read_text().replace("['Debug']", "['Release']")
    )
    install_twice(fixture, work, selected)
    category_settings(work, "Debug", False)
    category_settings(work, "Release", True)
    products = build(
        fixture, work, "Demo", "resource-odr-reselected-" + mode, mobile=True
    )
    observed = assets(products)
    assert observed == limited, (mode, "reselected", observed)
    observations[mode + "-reselected"] = observed
    fixture.cli(work, "deintegrate")
    graph = read_project(selected)
    for obj in graph["objects"].values():
        if obj.get("isa") == "XCBuildConfiguration":
            assert not any(
                key.startswith("ON_DEMAND_RESOURCES_") for key in obj["buildSettings"]
            )
            assert "ENABLE_ON_DEMAND_RESOURCES" not in obj["buildSettings"]
        assert "/OnDemandResources/" not in obj.get("path", "")
    before = (selected / "project.pbxproj").read_bytes()
    fixture.cli(work, "deintegrate")
    assert (selected / "project.pbxproj").read_bytes() == before
    fixture.verified.extend(
        [
            "device_build_keeps_every_selected_subspec_odr_path_and_own_exclusions_"
            + mode,
            "device_asset_packs_preserve_shared_file_tag_sets_per_configuration_"
            + mode,
            "disabled_odr_shared_resource_is_copied_as_normal_resource_" + mode,
            "opaque_resource_directory_layout_survives_conditional_odr_" + mode,
            "localized_directory_tags_and_exclusions_build_real_asset_packs_" + mode,
            "configuration_categories_match_enabled_roots_" + mode,
            "configuration_reselection_is_stable_offline_and_removes_stale_odr_" + mode,
            "deintegration_restores_odr_settings_and_managed_alias_references_" + mode,
        ]
    )


def main():
    fixture = LifecycleFixture()
    observations = {}
    for mode in ["library", "static", "dynamic"]:
        supplementary(fixture, mode)
        conditional_odr(fixture, mode, observations)
    (ROOT / "test-results/native-resource-isolation.json").write_text(
        json.dumps(
            {
                "status": "passed",
                "verified": fixture.verified,
                "fixture": str(fixture.root),
                "asset_pack_observations": observations,
                "unverified": ["Physical device execution", "Distribution signing"],
            },
            indent=2,
        )
        + "\n"
    )
    print(
        "Passed", len(fixture.verified), "resource isolation regressions", fixture.root
    )


if __name__ == "__main__":
    execute(main, "native-resource-isolation.json")
