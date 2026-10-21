#!/usr/bin/env python3
"""Compare generated phases and real builds against an isolated 1.17.0 engine."""

import argparse
import json
import subprocess
from pathlib import Path

from bootstrap import environment
from local_build import fixture_directory, results_directory
from native_script_phase_tests import build, cli
from reference_compare import reference_environment
from reporting import execute
from script_phase_fixture import canonical, create


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gem-home", type=Path, required=True)
    args = parser.parse_args()
    base = fixture_directory("script-reference-")
    native = base / "native"
    reference = base / "reference"
    for parent in [native, reference]:
        parent.mkdir()
        create(parent / "project")
    env = environment()
    env["GEM_HOME"] = str(base / "empty-gems")
    env["GEM_PATH"] = env["GEM_HOME"]
    env["SWIFTPODS_CACHE_ROOT"] = str(base / "cache")
    cli(native / "project", env, "install")
    ruby, ref_env = reference_environment(args.gem_home, reference)
    code = "require 'bundler/setup'; require 'cocoapods'; abort('Unexpected reference version') unless Pod::VERSION == '1.17.0'; Pod::Command.run(ARGV)"
    with base.joinpath("reference-install.log").open("wb") as log:
        result = subprocess.run(
            [ruby, "-e", code, "--", "install", "--no-ansi"],
            cwd=reference / "project",
            env=ref_env,
            stdout=log,
            stderr=subprocess.STDOUT,
            timeout=90,
        )
    assert result.returncode == 0, str(base / "reference-install.log")
    for project, target in [
        ("Pods/Pods.xcodeproj/project.pbxproj", "ScriptKit"),
        ("Demo.xcodeproj/project.pbxproj", "Demo"),
    ]:
        actual = canonical(native / "project" / project, target)
        expected = canonical(reference / "project" / project, target)
        base.joinpath(target + "-native.json").write_text(
            json.dumps(actual, indent=2) + "\n"
        )
        base.joinpath(target + "-reference.json").write_text(
            json.dumps(expected, indent=2) + "\n"
        )
        assert actual == expected, "Script phase graph differs: " + str(
            base / (target + "-native.json")
        )
    for parent in [native, reference]:
        work = parent / "project"
        assert build(work, parent, "first") == "script-value=41"
        assert build(work, parent, "unchanged") == "script-value=41"
        work.joinpath("Modules/ScriptKit/input value.txt").write_text("73\n")
        assert build(work, parent, "changed") == "script-value=73"
        assert parent.joinpath(
            "DerivedData/Build/Products/Debug/phase-generate.txt"
        ).read_text().splitlines() == ["generate", "generate"]
    report = {
        "status": "passed",
        "engine": "swift",
        "reference": "1.17.0",
        "fixture": str(base),
        "verified": [
            "independent native/reference script phase generation",
            "matching pod/Podfile phase order and options",
            "matching generated-header builds and execution",
            "matching incremental file-list regeneration",
            "sandboxed script execution",
        ],
        "unverified": [
            "complete DSL/API parity",
            "other platforms",
            "all script shells",
        ],
    }
    results_directory().joinpath("native-script-reference.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    execute(main, "native-script-reference.json")
