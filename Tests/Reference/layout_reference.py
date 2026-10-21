#!/usr/bin/env python3
"""Compare split-project hook models, schemes, XCTest and UI interaction."""

import argparse
import json
import subprocess
from pathlib import Path

from scripts.support.bootstrap import environment
from scripts.support.local_build import fixture_directory, results_directory
from scripts.support.reporting import execute
from Tests.Fixtures.layout_fixture import contract, enable
from Tests.Fixtures.supplementary_fixture import create
from Tests.Fixtures.ui_test_fixture import build as build_ui
from Tests.Fixtures.ui_test_fixture import create as create_ui
from Tests.Fixtures.ui_test_fixture import simulator
from Tests.Integration.native_supplementary_tests import build, install
from Tests.Reference.reference_compare import reference_environment


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gem-home", type=Path, required=True)
    args = parser.parse_args()
    parent = fixture_directory("layout-reference-")
    print("Layout reference fixtures:", parent, flush=True)
    for name in ["native", "reference"]:
        group = parent / name
        group.mkdir()
        create(group / "mac")
        enable(group / "mac")
        create_ui(group / "ios")
        enable(group / "ios")
        env = environment()
        env.update(
            GEM_HOME=str(parent / "empty-gems"),
            GEM_PATH=str(parent / "empty-gems"),
            SWIFTPODS_CACHE_ROOT=str(parent / "cache"),
        )
        ruby, ref_env = reference_environment(args.gem_home, group)
        for platform in ["mac", "ios"]:
            work = group / platform
            if name == "native":
                install(work, env)
            else:
                code = "require 'bundler/setup';require 'cocoapods';abort('Unexpected reference version') unless Pod::VERSION == '1.17.0';Pod::Command.run(ARGV)"
                log = group / (platform + "-reference-install.log")
                with log.open("wb") as out:
                    result = subprocess.run(
                        [ruby, "-e", code, "--", "install", "--no-ansi"],
                        cwd=work,
                        env=ref_env,
                        stdout=out,
                        stderr=subprocess.STDOUT,
                        timeout=120,
                    )
                assert result.returncode == 0, str(log)
        contract(group / "mac", ["SpecKit", "TestHelper", "AppHelper"])
        contract(group / "ios", ["UIWidget"])
        assert "testScopedDependenciesAndResources" in build(
            group / "mac", group, "SpecKit-Unit-Tests", "test"
        )
        build(group / "mac", group, "SpecKit-Example")
        app = next(
            (group / "DerivedData/Build/Products").rglob(
                "SpecKit-Example.app/Contents/MacOS/SpecKit-Example"
            )
        )
        assert (
            subprocess.check_output([str(app)], text=True).strip()
            == "app-value=16 resources=ok"
        )
    with simulator(parent) as device:
        for name in ["native", "reference"]:
            group = parent / name
            assert "testButtonChangesLibraryValue" in build_ui(
                group / "ios", group / "ios", "UIWidget-UI-Interface", device, "test"
            )
    report = {
        "status": "passed",
        "engine": "swift",
        "reference": "1.17.0",
        "fixture": str(parent),
        "verified": [
            "project target ownership and child scheme containers match reference",
            "independent child root build settings affect real compilation",
            "live Installer/child project/configuration identity and immediate saves",
            "public install context project lists",
            "matching idempotent cross-project hook dependencies",
            "original source projects preserved through preserve_paths",
            "matching macOS XCTest and app resource/dependency results",
            "matching named-host iOS UI interaction through split projects",
        ],
        "unverified": [
            "exact project bytes",
            "all plugin APIs",
            "all platform/linkage combinations",
            "distribution signing and physical devices",
        ],
    }
    results_directory().joinpath("native-layout-reference.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    execute(main, "native-layout-reference.json")
