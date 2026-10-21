#!/usr/bin/env python3
"""Compare variant graphs with a separately executed reference engine."""

import argparse
import json
import subprocess
from collections import Counter
from pathlib import Path

from scripts.support.bootstrap import environment
from scripts.support.local_build import fixture_directory, results_directory
from scripts.support.reporting import execute
from Tests.Fixtures.variant_fixture import contract, create
from Tests.Fixtures.vendor_fixture import sdk
from Tests.Integration.native_supplementary_tests import install
from Tests.Reference.reference_compare import reference_environment


def signature(work):
    result = []
    for path in work.glob("Pods/*.xcodeproj/project.pbxproj"):
        objects = json.loads(
            subprocess.check_output(
                ["plutil", "-convert", "json", "-o", "-", str(path)]
            )
        )["objects"]
        for target in objects.values():
            if not target.get("name", "").startswith(
                ("VariantKit", "VariantPeer")
            ) or target.get("productType") not in [
                "com.apple.product-type.framework",
                "com.apple.product-type.library.static",
            ]:
                continue
            settings = objects[
                objects[target["buildConfigurationList"]]["buildConfigurations"][0]
            ]["buildSettings"]
            sources = []
            for phase in target.get("buildPhases", []):
                if objects[phase]["isa"] != "PBXSourcesBuildPhase":
                    continue
                sources += [
                    Path(objects[objects[build]["fileRef"]]["path"]).name
                    for build in objects[phase]["files"]
                    if not Path(
                        objects[objects[build]["fileRef"]]["path"]
                    ).name.endswith("-dummy.m")
                ]
            mode = (
                "library"
                if target["productType"].endswith("library.static")
                else "dynamic"
                if settings.get("MACH_O_TYPE", "mh_dylib") == "mh_dylib"
                else "static"
            )
            result.append(
                (
                    target["name"],
                    mode,
                    settings["MACOSX_DEPLOYMENT_TARGET"],
                    tuple(sorted(sources)),
                )
            )
    return Counter(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gem-home", type=Path, required=True)
    args = parser.parse_args()
    parent = fixture_directory("variant-reference-")
    print("Variant reference fixtures:", parent, flush=True)
    binary = sdk(parent, "VariantBinary", platforms=("macosx",))
    env = environment()
    env.update(
        GEM_HOME=str(parent / "empty"),
        GEM_PATH=str(parent / "empty"),
        SWIFTPODS_CACHE_ROOT=str(parent / "cache"),
    )
    ruby, ref_env = reference_environment(args.gem_home, parent)
    signatures = {}
    for engine in ["native", "reference"]:
        work = parent / engine
        create(work, binary)
        if engine == "native":
            install(work, env)
        else:
            with (parent / "reference-install.log").open("wb") as output:
                code = "require 'bundler/setup';require 'cocoapods';abort('Unexpected reference version') unless Pod::VERSION == '1.17.0';Pod::Command.run(ARGV)"
                result = subprocess.run(
                    [ruby, "-e", code, "--", "install", "--no-ansi"],
                    cwd=work,
                    env=ref_env,
                    stdout=output,
                    stderr=subprocess.STDOUT,
                    timeout=120,
                )
            assert result.returncode == 0, str(parent / "reference-install.log")
        contract(work)
        signatures[engine] = signature(work)
        schemes = list(work.glob("Pods/*.xcodeproj/**/xcschemes/*.xcscheme"))
        assert len([p for p in schemes if p.stem.endswith("-Unit-Checks")]) == 2
        assert len([p for p in schemes if p.stem.endswith("-Example")]) == 2
    assert signatures["native"] == signatures["reference"], signatures
    report = {
        "status": "passed",
        "engine": "swift",
        "reference": "1.17.0",
        "fixture": str(parent),
        "verified": [
            "independent native and reference installs",
            "matching five library and four transitive variants",
            "matching exact target labels, selected source sets, library packaging, framework linkage and build minima",
            "matching test/app spec variant scheme counts",
            "matching pre-install variant counts and post-install build-setting preservation",
        ],
        "unverified": [
            "reference variant runtime execution; simultaneous reference XCFramework copies produce duplicate outputs",
            "reference archive header isolation",
            "identical project bytes",
            "all platform/linkage combinations",
        ],
    }
    results_directory().joinpath("native-variant-reference.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    execute(main, "native-variant-reference.json")
