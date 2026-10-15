#!/usr/bin/env python3
"""Build an explicitly selected external project through user xcconfig includes."""

import argparse
import json
import platform
import subprocess
import tempfile
from pathlib import Path

from bootstrap import ROOT, environment
from native_integration import project, serialize
from reference_compare import reference_environment
from reporting import execute
from vendor_fixture import run


def create(parent):
    work, app = parent / "work", parent / "Apps"
    work.mkdir(parents=True)
    (app / "Sources").mkdir(parents=True)
    (app / "Configs").mkdir()
    (app / "Sources/main.mm").write_text(
        '#include <Kit/Kit.h>\n#include <stdio.h>\n#ifndef USER_CONFIG\n#error User include was lost\n#endif\n#ifndef CONDITIONAL_CONFIG\n#error Conditional xcconfig was lost\n#endif\nint main(void) { printf("value=%d user=%d conditional=%d\\n", kit_value(), USER_CONFIG, CONDITIONAL_CONFIG); return 0; }\n'
    )
    selected = app / "External.xcodeproj"
    project(selected)
    graph = json.loads(
        subprocess.check_output(
            ["plutil", "-convert", "json", "-o", "-", str(selected / "project.pbxproj")]
        )
    )
    objects = graph["objects"]
    main = objects[objects[graph["rootObject"]]["mainGroup"]]
    group = "F00000000000000000000001"
    main["children"].append(group)
    objects[group] = {
        "isa": "PBXGroup",
        "path": "Configs",
        "sourceTree": "<group>",
        "children": [],
    }
    (app / "Configs/Base.xcconfig").write_text(
        "SDKROOT = macosx\nMACOSX_DEPLOYMENT_TARGET = 13.0\nGCC_PREPROCESSOR_DEFINITIONS = $(inherited) USER_CONFIG=1\n"
    )
    for index, configuration in enumerate(["Debug", "Release"]):
        filename = configuration + ".xcconfig"
        identifier = "F0000000000000000000000" + str(index + 2)
        objects[group]["children"].append(identifier)
        objects[identifier] = {
            "isa": "PBXFileReference",
            "path": filename,
            "sourceTree": "<group>",
            "lastKnownFileType": "text.xcconfig",
        }
        include = (
            "../../work/Pods/Target Support Files/Pods-Demo/Pods-Demo."
            + configuration.lower()
            + ".xcconfig"
        )
        (app / "Configs" / filename).write_text(
            '#include "Base.xcconfig"\n#include? "'
            + include
            + '"\nGCC_PREPROCESSOR_DEFINITIONS[config='
            + configuration
            + "][sdk=macosx*] = $(inherited) CONDITIONAL_CONFIG=1\n"
        )
        for value in list(objects.values()):
            if (
                value.get("isa") == "XCBuildConfiguration"
                and value["name"] == configuration
                and value["buildSettings"].get("PRODUCT_NAME")
            ):
                value["baseConfigurationReference"] = identifier
                value["buildSettings"]["ALWAYS_SEARCH_USER_PATHS"] = "NO"
                for key in ["SDKROOT", "MACOSX_DEPLOYMENT_TARGET"]:
                    value["buildSettings"].pop(key, None)
    (selected / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(graph))
    kit = work / "Kit"
    kit.mkdir()
    (kit / "Kit.h").write_text(
        '#ifdef __cplusplus\nextern "C" {\n#endif\nint kit_value(void);\n#ifdef __cplusplus\n}\n#endif\n'
    )
    (kit / "Kit.c").write_text("int kit_value(void) { return 7; }\n")
    (kit / "Kit.podspec.json").write_text(
        json.dumps(
            {
                "name": "Kit",
                "version": "1.0",
                "source_files": "*.{c,h}",
                "platforms": {"osx": "13.0"},
                "summary": "Fixture",
                "homepage": "https://swiftpods.org",
                "authors": "Tests",
                "license": "MIT",
                "source": {"git": "https://example.invalid/kit.git", "tag": "1.0"},
            }
        )
    )
    (work / "Podfile").write_text(
        "platform :osx, '13.0'\nproject '../Apps/External.xcodeproj'\ntarget 'Demo' do\n pod 'Kit', :path => './Kit'\nend\npost_install do |i|\n t = i.aggregate_targets.find { |t| t.name == 'Pods-Demo' }.user_targets.first\n File.write('resolved-settings.json', JSON.generate(t.resolved_build_setting('SDKROOT', true)))\nend\n"
    )
    return work, selected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gem-home", type=Path)
    args = parser.parse_args()
    parent = Path(tempfile.mkdtemp(prefix="native-xcconfig-", dir=ROOT / ".build"))
    print("External xcconfig fixtures:", parent, flush=True)
    env = environment()
    env["SWIFTPODS_CACHE_ROOT"] = str(parent / "cache")
    observations = {}
    for engine in ["native", "reference"] if args.gem_home else ["native"]:
        work, selected = create(parent / engine)
        if engine == "native":
            command, selected_env = (
                [str(ROOT / ".build/debug/swiftpods"), "install", "--json"],
                env,
            )
        else:
            ruby, selected_env = reference_environment(args.gem_home, parent)
            command = [
                ruby,
                "-e",
                "require 'bundler/setup';require 'cocoapods';Pod::Command.run(ARGV)",
                "--",
                "install",
                "--no-ansi",
            ]
        with (parent / (engine + "-install.log")).open("wb") as output:
            result = subprocess.run(
                command,
                cwd=work,
                env=selected_env,
                stdout=output,
                stderr=subprocess.STDOUT,
                timeout=90,
            )
        assert result.returncode == 0, parent / (engine + "-install.log")
        observations[engine] = json.loads((work / "resolved-settings.json").read_text())
        assert observations[engine] == {"Debug": "macosx", "Release": "macosx"}, (
            observations[engine]
        )
        workspace = next(work.glob("*.xcworkspace")).name
        for configuration in ["Debug", "Release"]:
            run(
                [
                    "xcodebuild",
                    "-workspace",
                    workspace,
                    "-scheme",
                    "Demo",
                    "-configuration",
                    configuration,
                    "-destination",
                    "platform=macOS,arch=" + platform.machine(),
                    "-derivedDataPath",
                    parent / engine / "DerivedData",
                    "CODE_SIGNING_ALLOWED=NO",
                    "build",
                ],
                work,
                parent / (engine + "-" + configuration + ".log"),
            )
            binary = (
                parent
                / engine
                / "DerivedData/Build/Products"
                / configuration
                / "Demo.app/Contents/MacOS/Demo"
            )
            assert (
                subprocess.check_output([str(binary)], text=True).strip()
                == "value=7 user=1 conditional=1"
            )
        if engine == "native":
            subprocess.run(
                [str(ROOT / ".build/debug/swiftpods"), "deintegrate", "--json"],
                cwd=work,
                env=env,
                check=True,
                capture_output=True,
            )
            text = (selected / "project.pbxproj").read_text()
            assert (
                "F00000000000000000000002" in text
                and "F00000000000000000000003" in text
            )
    if args.gem_home:
        assert observations["native"] == observations["reference"]
    report = {
        "status": "passed",
        "engine": "swift",
        "fixture": str(parent),
        "verified": [
            "explicit project outside installation directory",
            "xcconfig paths resolved relative to PBX groups",
            "existing user base configuration and optional aggregate include retained",
            "conditional sdk/configuration settings consumed by Debug/Release applications",
            "inherited definitions from user include-chain preserved",
            "hook resolved_build_setting reads the included SDKROOT",
            "external project deintegration preserves user base configuration",
        ],
        "unverified": ["all xcconfig conditional axes and substitution operators"],
    }
    if args.gem_home:
        report["reference"] = "1.17.0"
    name = "native-xcconfig-reference.json" if args.gem_home else "native-xcconfig.json"
    (ROOT / "test-results" / name).write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    import sys

    execute(
        main,
        "native-xcconfig-reference.json"
        if "--gem-home" in sys.argv
        else "native-xcconfig.json",
    )
