#!/usr/bin/env python3
"""Build the combined configuration, inheritance and project layout contract."""

import argparse
import json
import subprocess
import tempfile
from pathlib import Path

from batch_fixture import build, create
from bootstrap import ROOT, environment
from native_integration import serialize
from native_supplementary_tests import install
from reporting import execute


def read_project(path):
    return json.loads(
        subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(path)])
    )


def exercise(parent, linkage, binary=None, bundle=None, multiple=False, mobile=False):
    parent.mkdir()
    work = parent / "project"
    create(work, linkage, multiple, mobile)
    env = environment(bundle)
    env.update(
        SWIFTPODS_CACHE_ROOT=str(parent / "cache"),
        GEM_HOME=str(parent / "empty-gems"),
        GEM_PATH=str(parent / "empty-gems"),
    )
    original = {
        name: read_project(work / (name + ".xcodeproj/project.pbxproj"))
        for name in ["Demo", "Search", "Isolated"]
    }
    podfile = work / "Podfile"
    pre_dsl = "require 'xcodeproj'\np = Xcodeproj::Project.open('Demo.xcodeproj')\np.build_configurations.each { |c| c.build_settings['BATCH_DSL'] = 'preserved' }\np.save\n"
    podfile.write_text(pre_dsl + podfile.read_text())
    install(work, env, binary=binary)
    files = list(work.glob("Pods/**/*.xcodeproj/project.pbxproj")) + list(
        work.glob("*.xcodeproj/project.pbxproj")
    )
    snapshot = {str(path): path.read_bytes() for path in files}
    lock = work.joinpath("Podfile.lock").read_bytes()
    install(work, env, "--deployment", "--offline", binary=binary)
    assert lock == work.joinpath("Podfile.lock").read_bytes()
    assert snapshot == {str(path): path.read_bytes() for path in files}, (
        "Reinstall changed project bytes"
    )
    for configuration, value in [("Debug", 20), ("Staging", 20), ("Release", 17)]:
        build(
            work,
            parent,
            configuration=configuration,
            expected=f"batch={value} resources=ok",
        )
    build(work, parent, scheme="Search", expected="search-ok")
    build(work, parent, scheme="Isolated", expected="isolated=3")
    assert list(
        parent.glob(
            "DerivedData/Build/Intermediates.noindex/Pods.build/Debug/BatchKit*.build/DerivedSources/batch-hook.txt"
        )
    ) or list(parent.glob("DerivedData/**/batch-hook.txt")), (
        "Hook phase did not execute"
    )
    if mobile:
        build(
            work, parent, scheme="Mobile", destination="generic/platform=iOS Simulator"
        )
        build(work, parent, scheme="Mobile", destination="generic/platform=iOS")
    original_podfile = podfile.read_text()
    podfile.write_text(
        "\n".join(
            line
            for line in original_podfile.splitlines()
            if "pod 'DebugKit'" not in line
        )
        + "\n"
    )
    install(work, env, "--offline", "--no-integrate", binary=binary)
    install(work, env, "--offline", binary=binary)
    for name in ["Demo", "Search", "Isolated"]:
        removed = read_project(work / (name + ".xcodeproj/project.pbxproj"))
        assert not any(
            item.get("path", "").endswith(("DebugKit.framework", "libDebugKit.a"))
            for item in removed["objects"].values()
        ), "Removed dependency retained owned references"
    podfile.write_text(original_podfile)
    install(work, env, "--offline", binary=binary)
    # User edits made after installation survive removal. Original settings are restored.
    path = work / "Demo.xcodeproj/project.pbxproj"
    graph = read_project(path)
    for item in graph["objects"].values():
        if item["isa"] == "XCBuildConfiguration" and item["buildSettings"].get(
            "PODS_ROOT"
        ):
            item["buildSettings"]["HEADER_SEARCH_PATHS"] = ["my-user-headers"]
            item["buildSettings"]["BATCH_USER"] = "preserved"
    path.write_text("// !$*UTF8*$!\n" + serialize(graph))
    result = subprocess.run(
        [str(binary or ROOT / ".build/debug/swiftpods"), "deintegrate", "--json"],
        cwd=work,
        env=env,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    for name in ["Demo", "Search", "Isolated"]:
        graph = read_project(work / (name + ".xcodeproj/project.pbxproj"))
        for identifier, item in graph["objects"].items():
            if item["isa"] != "XCBuildConfiguration":
                continue
            settings = item["buildSettings"]
            before = (
                original[name]["objects"].get(identifier, {}).get("buildSettings", {})
            )
            assert (
                "PODS_ROOT" not in settings
                and "SWIFTPODS_CONFIG_LDFLAGS" not in settings
            )
            for key, value in before.items():
                if name == "Demo" and key == "HEADER_SEARCH_PATHS":
                    continue
                assert settings.get(key) == value, (name, key, settings.get(key), value)
        assert not any(
            item.get("name", "").startswith("[SwiftPods]")
            or item.get("name") == "[CP] Check Pods Manifest.lock"
            for item in graph["objects"].values()
        )
        assert not any(
            item.get("path", "").endswith(
                (
                    "BatchKit.framework",
                    "DebugKit.framework",
                    "libBatchKit.a",
                    "libDebugKit.a",
                    "direct.txt",
                    "Palette.xcassets",
                )
            )
            for item in graph["objects"].values()
        )
    assert (
        "group:Pods/"
        not in work.joinpath("Batch.xcworkspace/contents.xcworkspacedata").read_text()
    )
    graph = read_project(path)
    assert any(
        item.get("buildSettings", {}).get("BATCH_USER") == "preserved"
        for item in graph["objects"].values()
    )
    install(work, env, "--offline", binary=binary)
    # Toggle multiple projects off; stale generated workspace references disappear.
    if multiple:
        podfile.write_text(
            podfile.read_text().replace(
                ":generate_multiple_pod_projects => true",
                ":generate_multiple_pod_projects => false",
            )
        )
        install(work, env, "--offline", binary=binary)
        assert (
            "group:Pods/BatchKit.xcodeproj"
            not in work.joinpath(
                "Batch.xcworkspace/contents.xcworkspacedata"
            ).read_text()
        )
    return {
        "linkage": linkage or "static-library",
        "multiple_projects": multiple,
        "multi_platform": mobile,
        "fixture": str(parent),
        "status": "passed",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path)
    args = parser.parse_args()
    bundle = args.bundle.resolve() if args.bundle else None
    binary = bundle / "bin/swiftpods" if bundle else None
    parent = Path(tempfile.mkdtemp(prefix="native-batch-", dir=ROOT / ".build"))
    print("Batch fixtures:", parent, flush=True)
    scenarios = [
        exercise(parent / label, linkage, binary, bundle, multiple, mobile)
        for label, linkage, multiple, mobile in [
            ("static", "static", False, False),
            ("dynamic", "dynamic", False, False),
            ("library-multiple", None, True, True),
        ]
    ]
    report = {
        "status": "passed",
        "engine": "swift",
        "fixture": str(parent),
        "scenarios": scenarios,
        "bundle": str(bundle) if bundle else None,
        "verified": [
            "Debug/Staging/Release executable results in three linkage modes",
            "configuration-specific linking",
            "complete/search_paths/none inheritance",
            "per-file ARC and prefix header",
            "direct localized resources and asset compilation",
            "multiple generated projects and hooks",
            "macOS/iOS platform separation with simulator/device builds",
            "live DSL Project.open/save",
            "Installer and Project identity across hooks",
            "immediate hook saves and hook phase execution",
            "offline deployment byte-stable reinstall",
            "removed dependency reference cleanup",
            "settings and user edits preserved during deintegrate",
            "deintegrate and reinstall",
            "stale workspace reference removal",
        ],
        "unverified": [
            "conditional consumer resources and vendored SDKs",
            "all private plugin APIs",
            "same-platform target variants",
            "physical devices and signing",
            "full platform matrix",
        ],
    }
    if bundle:
        report["bundle_digest"] = json.loads(
            bundle.joinpath("compatibility.json").read_text()
        )["bundle_digest"]
    ROOT.joinpath(
        "test-results/native-batch" + ("-distribution" if bundle else "") + ".json"
    ).write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    execute(
        main,
        "native-batch-distribution.json"
        if "--bundle" in __import__("sys").argv
        else "native-batch.json",
    )
