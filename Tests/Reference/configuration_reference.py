#!/usr/bin/env python3
"""Compare configuration-filtered compiled assets and SDKs with the reference."""

import argparse
import json
import subprocess
from pathlib import Path

from scripts.support.bootstrap import environment
from scripts.support.local_build import fixture_directory, results_directory
from scripts.support.reporting import execute
from Tests.Fixtures.configuration_fixture import build, create, products, simulator_run
from Tests.Fixtures.ui_test_fixture import simulator
from Tests.Integration.native_supplementary_tests import install
from Tests.Reference.reference_compare import reference_environment


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gem-home", type=Path, required=True)
    args = parser.parse_args()
    parent = fixture_directory("configuration-reference-")
    print("Configuration reference fixtures:", parent, flush=True)
    binaries = products(parent)
    env = environment()
    env.update(
        GEM_HOME=str(parent / "empty"),
        GEM_PATH=str(parent / "empty"),
        SWIFTPODS_CACHE_ROOT=str(parent / "cache"),
    )
    ruby, ref_env = reference_environment(args.gem_home, parent)
    code = "require 'bundler/setup';require 'cocoapods';abort('Unexpected reference version') unless Pod::VERSION == '1.17.0';Pod::Command.run(ARGV)"
    for platform, raw, linkage in [
        ("osx", False, "static"),
        ("osx", True, "dynamic"),
        ("ios", False, "static"),
    ]:
        label = platform + ("-raw" if raw else "-xcframework")
        for engine in ["native", "reference"]:
            group = parent / (label + "-" + engine)
            group.mkdir()
            work = group / "project"
            create(
                work, binaries, linkage, raw=raw, platform=platform, multiple=not raw
            )
            if engine == "native":
                install(work, env)
            else:
                log = group / "install.log"
                with log.open("wb") as output:
                    result = subprocess.run(
                        [ruby, "-e", code, "--", "install", "--no-ansi"],
                        cwd=work,
                        env=ref_env,
                        stdout=output,
                        stderr=subprocess.STDOUT,
                        timeout=120,
                    )
                assert result.returncode == 0, str(log)
            if platform == "osx":
                for configuration in ["Debug", "Staging", "Release"]:
                    build(work, group, configuration)
        if platform == "ios":
            with simulator(parent) as device:
                for engine in ["native", "reference"]:
                    group = parent / (label + "-" + engine)
                    for configuration in ["Debug", "Release"]:
                        simulator_run(
                            device,
                            build(group / "project", group, configuration, "ios"),
                            configuration,
                        )
    report = {
        "status": "passed",
        "engine": "swift",
        "reference": "1.17.0",
        "fixture": str(parent),
        "verified": [
            "matching Debug/Staging/Release macOS app execution",
            "matching direct/localized/compiled resources and resource bundles",
            "matching conditional SDK link and embed behavior",
            "static XCFramework and dynamic raw-framework pod modes",
            "matching enabled/disabled iOS simulator app results",
            "multiple pod projects",
            "resource and SDK paths with spaces",
            "unrelated user resource preservation",
        ],
        "unverified": [
            "exact project bytes",
            "reference incremental script scheduling; fixture marks copy/embed scripts always run",
            "all resource formats",
            "all platform/linkage combinations",
            "physical devices and distribution signing",
        ],
    }
    results_directory().joinpath("native-configuration-reference.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    execute(main, "native-configuration-reference.json")
