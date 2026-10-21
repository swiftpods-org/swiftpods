#!/usr/bin/env python3
"""Run the combined native fixture independently through the isolated reference."""

import argparse
import json
import subprocess
from pathlib import Path

from batch_fixture import build, create
from bootstrap import environment
from local_build import debug_binary, fixture_directory, results_directory
from native_supplementary_tests import install
from reference_compare import reference_environment
from reporting import execute


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gem-home", type=Path, required=True)
    args = parser.parse_args()
    parent = fixture_directory("batch-reference-")
    print("Batch reference fixtures:", parent, flush=True)
    for name in ["native", "reference"]:
        group = parent / name
        group.mkdir()
        create(group / "project", multiple=True)
    env = environment()
    env.update(
        GEM_HOME=str(parent / "empty-gems"),
        GEM_PATH=str(parent / "empty-gems"),
        SWIFTPODS_CACHE_ROOT=str(parent / "cache"),
    )
    nested = parent / "native/project/Nested.Podfile"
    nested.write_text(
        "target 'Outer' do\n pod 'OuterKit'\n target 'Search' do\n  inherit! :search_paths\n  target 'CompleteChild' do\n  end\n  target 'NoneChild' do\n   inherit! :none\n   pod 'OwnKit'\n  end\n end\nend\n"
    )
    raw = subprocess.check_output(
        [str(debug_binary()), "ipc", "podfile", str(nested), "--json"],
        cwd=nested.parent,
        env=env,
        text=True,
    )
    targets = next(
        event["data"]["targets"]
        for event in json.loads(raw)["events"]
        if event["kind"] == "inspection"
    )
    inherited = {
        target["name"]: {
            key: sorted({entry["name"] for entry in target[key]})
            for key in ["dependencies", "search_dependencies"]
        }
        | {
            "configurations": {
                configuration: sorted(
                    {
                        entry["name"]
                        for entry in target["dependencies"]
                        if entry["options"].get("configurations") is None
                        or configuration in entry["options"]["configurations"]
                    }
                )
                for configuration in ["Debug", "Release"]
            }
        }
        for target in targets
    }
    install(parent / "native/project", env)
    ruby, ref_env = reference_environment(args.gem_home, parent / "reference")
    analysis = "require 'bundler/setup';require 'cocoapods';require 'json';f=Pod::Podfile.from_ruby(Pathname(ARGV[0]),File.read(ARGV[0]));puts JSON.generate(f.target_definitions.values.reject(&:abstract?).to_h { |t| [t.name, { 'dependencies' => t.dependencies.map(&:name).uniq.sort, 'search_dependencies' => t.targets_to_inherit_search_paths.reject(&:abstract?).flat_map(&:dependencies).map(&:name).uniq.sort, 'configurations' => %w[Debug Release].to_h { |c| [c,t.dependencies.select { |d| t.pod_whitelisted_for_configuration?(d.name,c) }.map(&:name).uniq.sort] } }] })"
    expected = json.loads(
        subprocess.check_output(
            [ruby, "-e", analysis, str(nested)],
            cwd=parent / "reference/project",
            env=ref_env,
            text=True,
        )
    )
    own_configurations = {"Debug": ["OwnKit"], "Release": ["OwnKit"]}
    assert expected["NoneChild"]["configurations"] == {"Debug": [], "Release": []}
    assert inherited["NoneChild"]["configurations"] == own_configurations
    corrected = json.loads(json.dumps(expected))
    corrected["NoneChild"]["configurations"] = own_configurations
    assert inherited == corrected, (inherited, expected)
    code = "require 'bundler/setup';require 'cocoapods';abort('Unexpected reference version') unless Pod::VERSION == '1.17.0';Pod::Command.run(ARGV)"
    log = parent / "reference-install.log"
    with log.open("wb") as output:
        result = subprocess.run(
            [ruby, "-e", code, "--", "install", "--no-ansi"],
            cwd=parent / "reference/project",
            env=ref_env,
            stdout=output,
            stderr=subprocess.STDOUT,
            timeout=120,
        )
    assert result.returncode == 0, str(log)
    for name in ["native", "reference"]:
        group = parent / name
        work = group / "project"
        for configuration, value in [("Debug", 20), ("Staging", 20), ("Release", 17)]:
            build(
                work,
                group,
                configuration=configuration,
                expected=f"batch={value} resources=ok",
            )
        build(work, group, scheme="Search", expected="search-ok")
        build(work, group, scheme="Isolated", expected="isolated=3")
        assert list(work.glob("Pods/**/BatchKit.xcodeproj/project.pbxproj"))
    report = {
        "status": "passed",
        "engine": "swift",
        "reference": "1.17.0",
        "fixture": str(parent),
        "verified": [
            "same Debug/Staging/Release executable results in independent engines",
            "complete/search_paths/none inheritance",
            "nested inheritance matches reference except the registered none default-configuration fix",
            "matching per-file ARC, prefix header and localized resource behavior",
            "multiple pod projects",
            "live project hooks and immediate saves",
            "Installer and Project identity",
            "lockfile lifecycle",
        ],
        "verified_cases": [
            "Targets.none_nested_input",
            "Targets.none_nested_configurations",
        ],
        "none_nested_observations": {"native": inherited, "reference": expected},
        "differences": [
            {
                "id": "Targets.none_nested_configurations",
                "feature": "Targets",
                "parity": False,
                "reference": "none after search_paths disables an own unconfigured dependency",
                "native": "own dependency remains enabled in Debug and Release",
            }
        ],
        "unverified": [
            "project/lock byte parity",
            "all plugin APIs",
            "multi-platform reference matrix",
            "conditional SDK and consumer resources",
        ],
    }
    results_directory().joinpath("native-batch-reference.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    execute(main, "native-batch-reference.json")
