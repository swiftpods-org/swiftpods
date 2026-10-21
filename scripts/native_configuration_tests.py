#!/usr/bin/env python3
"""Run configuration-filtered resources and SDKs through the Swift engine."""

import argparse
import json
import subprocess
from pathlib import Path

from bootstrap import environment
from configuration_fixture import build, create, podfile, products, simulator_run
from local_build import debug_binary, fixture_directory, results_directory
from native_integration import serialize
from native_supplementary_tests import install
from reporting import execute, option_value
from ui_test_fixture import simulator


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path)
    args = parser.parse_args()
    bundle = args.bundle.resolve() if args.bundle else None
    binary = bundle / "bin/swiftpods" if bundle else debug_binary()
    parent = fixture_directory("native-configuration-")
    print("Configuration fixtures:", parent, flush=True)
    binaries = products(parent)
    env = environment(bundle)
    env.update(
        GEM_HOME=str(parent / "empty"),
        GEM_PATH=str(parent / "empty"),
        SWIFTPODS_CACHE_ROOT=str(parent / "cache"),
    )
    lexical = parent / "Lexical.Podfile"
    lexical.write_text(
        "podfile = 1\nproject = 2\ninstaller = 3\nrequest = 4\ninputs = 5\nresult = 6\nplatform :osx, '13.0'\ntarget 'Lexical' do\n pod 'Kit'\nend\n"
    )
    inspected = json.loads(
        subprocess.check_output(
            [str(binary), "ipc", "podfile", str(lexical), "--json"],
            cwd=parent,
            env=env,
            text=True,
        )
    )
    targets = next(
        event["data"]["targets"]
        for event in inspected["events"]
        if event["kind"] == "inspection"
    )
    assert [target["name"] for target in targets] == ["Lexical"]
    scenarios = []
    for label, linkage, raw, multiple in [
        ("xcframework-static", "static", False, True),
        ("raw-dynamic", "dynamic", True, False),
        ("xcframework-library", None, False, False),
    ]:
        group = parent / label
        group.mkdir()
        work = group / "project"
        create(work, binaries, linkage, raw=raw, multiple=multiple)
        install(work, env, binary=binary)
        first = work.joinpath("Demo.xcodeproj/project.pbxproj").read_bytes()
        lock = work.joinpath("Podfile.lock").read_bytes()
        install(work, env, "--deployment", "--offline", binary=binary)
        assert work.joinpath("Demo.xcodeproj/project.pbxproj").read_bytes() == first
        assert work.joinpath("Podfile.lock").read_bytes() == lock
        for configuration in ["Debug", "Staging", "Release"]:
            build(work, group, configuration)
        if label == "xcframework-static":
            # Change filtering and rebuild the same configuration/output directory.
            podfile(work, linkage, multiple, ("Debug", "Staging", "Release"))
            install(work, env, binary=binary)
            path = work / "Demo.xcodeproj/project.pbxproj"
            graph = json.loads(
                subprocess.check_output(
                    ["plutil", "-convert", "json", "-o", "-", str(path)]
                )
            )
            for item in graph["objects"].values():
                if (
                    item.get("isa") == "XCBuildConfiguration"
                    and item["name"] == "Release"
                    and item["buildSettings"].get("PRODUCT_NAME")
                ):
                    item["buildSettings"]["GCC_PREPROCESSOR_DEFINITIONS"] = [
                        "CONDITIONAL_ON=1"
                    ]
            path.write_text("// !$*UTF8*$!\n" + serialize(graph))
            # Debug's expected body is reused with Release's build configuration.
            build(work, group, "Release", expected_configuration="Debug")
            # Restore original filtering and prove the same output loses assets.
            graph = json.loads(
                subprocess.check_output(
                    ["plutil", "-convert", "json", "-o", "-", str(path)]
                )
            )
            for item in graph["objects"].values():
                if (
                    item.get("isa") == "XCBuildConfiguration"
                    and item["name"] == "Release"
                    and item["buildSettings"].get("PRODUCT_NAME")
                ):
                    item["buildSettings"]["GCC_PREPROCESSOR_DEFINITIONS"] = [
                        "CONDITIONAL_ON=0"
                    ]
            path.write_text("// !$*UTF8*$!\n" + serialize(graph))
            podfile(work, linkage, multiple)
            install(work, env, binary=binary)
            build(work, group, "Release")
            declarative = {
                "schema_version": 1,
                "platform": {"name": "osx", "deployment_target": "13.0"},
                "project": "Demo.xcodeproj",
                "frameworks": linkage,
                "options": {"generate_multiple_pod_projects": multiple},
                "targets": [
                    {
                        "name": "Demo",
                        "pods": [
                            {
                                "name": "ConditionalKit",
                                "path": "./Modules/ConditionalKit",
                                "configurations": ["Debug", "Staging"],
                            }
                        ],
                    }
                ],
            }
            work.joinpath("Podfile.json").write_text(json.dumps(declarative))
            work.joinpath("Podfile.lock").unlink()
            install(
                work,
                dict(env, SWIFTPODS_RUBY="/fixture-no-ruby"),
                "--hardened",
                "--offline",
                binary=binary,
            )
            for configuration in ["Debug", "Release"]:
                build(work, group, configuration)
        if label == "raw-dynamic":
            subprocess.run(
                [str(binary), "deintegrate", "--json"],
                cwd=work,
                env=env,
                check=True,
                capture_output=True,
            )
            graph = json.loads(
                subprocess.check_output(
                    [
                        "plutil",
                        "-convert",
                        "json",
                        "-o",
                        "-",
                        str(work / "Demo.xcodeproj/project.pbxproj"),
                    ]
                )
            )
            for item in graph["objects"].values():
                if item.get("isa") == "XCBuildConfiguration" and item[
                    "buildSettings"
                ].get("PRODUCT_NAME"):
                    assert (
                        item["buildSettings"]["EXCLUDED_SOURCE_FILE_NAMES"]
                        == "UserExcluded*.m"
                    )
            install(work, env, binary=binary)
            build(work, group, "Release")
        scenarios.append({"scenario": label, "status": "passed"})
    group = parent / "ios"
    group.mkdir()
    work = group / "project"
    create(work, binaries, platform="ios", multiple=True)
    install(work, env, binary=binary)
    with simulator(parent) as device:
        for configuration in ["Debug", "Release"]:
            simulator_run(
                device, build(work, group, configuration, "ios"), configuration
            )
    scenarios.append({"scenario": "ios-simulator", "status": "passed"})
    report = {
        "status": "passed",
        "engine": "swift",
        "fixture": str(parent),
        "scenarios": scenarios,
        "verified": [
            "configuration-filtered direct/localized/compiled resources and resource bundles",
            "dynamic library resource bundles remain inside the owning framework",
            "Podfile local variables and hook closures cannot replace adapter protocol state",
            "static/dynamic framework and archive SDK link filtering",
            "dynamic SDK embed filtering",
            "native XCFramework destination selection",
            "three macOS pod linkage modes",
            "custom Staging configuration",
            "multiple pod projects",
            "same-configuration incremental asset exclusion",
            "offline byte-stable deployment",
            "hardened filtering without Ruby",
            "user resource and exclusion preservation through deintegration",
            "iOS simulator execution with enabled and disabled assets",
        ],
        "unverified": [
            "same-platform target variants",
            "all platform/linkage combinations",
            "physical devices and distribution signing",
            "all third-party asset formats",
        ],
    }
    if bundle:
        manifest = json.loads(bundle.joinpath("compatibility.json").read_text())
        report.update(bundle=str(bundle), bundle_digest=manifest["bundle_digest"])
    name = (
        "native-packaged-configuration.json" if bundle else "native-configuration.json"
    )
    results_directory().joinpath(name).write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    execute(
        main,
        "native-packaged-configuration.json"
        if option_value("--bundle") is not None
        else "native-configuration.json",
    )
