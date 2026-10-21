#!/usr/bin/env python3
"""Compare UI host wiring and run the same interaction in both engines."""

import argparse
import json
import subprocess
from pathlib import Path

from bootstrap import environment
from local_build import fixture_directory, results_directory
from native_supplementary_tests import install
from native_ui_tests import graph_contract
from reference_compare import reference_environment
from reporting import execute
from ui_test_fixture import build, create, simulator


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gem-home", type=Path, required=True)
    args = parser.parse_args()
    parent = fixture_directory("ui-reference-")
    print("UI reference fixtures:", parent, flush=True)
    for name in ["native", "reference"]:
        group = parent / name
        group.mkdir()
        create(group / "project")
    env = environment()
    env.update(
        GEM_HOME=str(parent / "empty-gems"),
        GEM_PATH=str(parent / "empty-gems"),
        SWIFTPODS_CACHE_ROOT=str(parent / "cache"),
    )
    install(parent / "native/project", env)
    ruby, ref_env = reference_environment(args.gem_home, parent / "reference")
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
    with simulator(parent) as device:
        for name in ["native", "reference"]:
            group = parent / name
            work = group / "project"
            graph_contract(work)
            assert "testButtonChangesLibraryValue" in build(
                work, group, "UIWidget-UI-Interface", device, "test"
            )
    report = {
        "status": "passed",
        "engine": "swift",
        "reference": "1.17.0",
        "fixture": str(parent),
        "verified": [
            "independent UI product types and host associations match",
            "UI XCTest launches app spec and taps button in both engines",
            "matching library value changes from 7 to 8",
            "Swift UI tests and app specs",
            "own UI resources and Info.plist",
            "UI scheme environment",
        ],
        "unverified": [
            "exact Xcode project bytes",
            "generated host implementation parity",
            "other platforms",
            "complete DSL/API parity",
        ],
    }
    results_directory().joinpath("native-ui-reference.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    execute(main, "native-ui-reference.json")
