#!/usr/bin/env python3
"""Build an explicitly selected external project through user xcconfig includes."""

import argparse
import json
import platform
import subprocess
from pathlib import Path

from bootstrap import environment
from local_build import debug_binary, fixture_directory, results_directory
from native_integration import project, serialize
from reference_compare import reference_environment
from reporting import execute
from vendor_fixture import run
from xcconfig_syntax_regressions import VERIFIED as SYNTAX_VERIFIED
from xcconfig_syntax_regressions import syntax_regressions


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


def lexical_values(work, selected):
    headers = selected.parent / "Headers With Spaces/Nested"
    headers.mkdir(parents=True)
    (headers / "FixtureLexical.h").write_text("#define FIXTURE_LEXICAL_HEADER 23\n")
    source = selected.parent / "Sources/main.mm"
    source.write_text(
        '#include "FixtureLexical.h"\n#if FIXTURE_LEXICAL_HEADER != 23\n#error Recursive user header path was lost\n#endif\n'
        + source.read_text()
    )
    expected = {
        "LEXICAL_PATTERN": "/root/**/*.h /root/**/Headers",
        "LEXICAL_BLOCK": "x/* kept */y",
        "LEXICAL_QUOTED": '"hello world"',
        "LEXICAL_PATH": '"' + str(headers.parent) + '/**"',
        "LEXICAL_AFTER_COMMENT": "selected",
    }
    base = selected.parent / "Configs/Base.xcconfig"
    base.write_text(
        base.read_text()
        + "\n// Literal xcconfig values.\n"
        + "\n".join(key + " = " + value for key, value in expected.items())
        + "\n// Document /* literally\nLEXICAL_AFTER_COMMENT = selected\n// Close */ literally\n"
    )
    podfile = work / "Podfile"
    podfile.write_text(
        podfile.read_text().removesuffix("end\n")
        + """  target = t
  values = %w[LEXICAL_PATTERN LEXICAL_BLOCK LEXICAL_QUOTED LEXICAL_PATH LEXICAL_AFTER_COMMENT].to_h { |key| [key, target.resolved_build_setting(key, true)] }
  File.write('lexical-settings.json', JSON.generate(values))
  target.build_configurations.each do |configuration|
    configuration.build_settings['USER_HEADER_SEARCH_PATHS'] = values['LEXICAL_PATH'].fetch(configuration.name)
  end
end
"""
    )
    return expected


def invalid_block_comments(parent, env):
    for label, comment in [
        ("single-line", "/* Header */"),
        ("multiline", "/* Header\n * line two\n */"),
    ]:
        work, selected = create(parent / ("invalid-comment-" + label))
        podfile = work / "Podfile"
        podfile.write_text(
            podfile.read_text()
            + "pre_install { |_| File.write('pre-hook-ran', 'yes') }\n"
        )
        (selected.parent / "Configs/Base.xcconfig").write_text(
            "SDKROOT = macosx\n" + comment + "\nMACOSX_DEPLOYMENT_TARGET = 13.0\n"
        )
        original = (selected / "project.pbxproj").read_bytes()
        result = subprocess.run(
            [str(debug_binary()), "install", "--json"],
            cwd=work,
            env=env,
            capture_output=True,
            text=True,
            timeout=90,
        )
        (parent / (label + "-comment-native.log")).write_text(
            result.stdout + result.stderr
        )
        report = json.loads(result.stdout)
        assert (
            result.returncode and report["project_state"] == "failed_no_managed_changes"
        ), report
        assert any(
            event.get("code") == "SP-XCCONFIG-SYNTAX" and event.get("line") == 2
            for event in report["events"] + [report.get("diagnostic", {})]
        ), report
        assert not (work / "resolved-settings.json").exists()
        assert not (work / "pre-hook-ran").exists()
        assert not (work / "Podfile.lock").exists()
        assert not (work / "Pods/Pods.xcodeproj").exists()
        assert (selected / "project.pbxproj").read_bytes() == original
        xcode = subprocess.run(
            [
                "xcodebuild",
                "-project",
                str(selected),
                "-target",
                "Demo",
                "-configuration",
                "Debug",
                "CODE_SIGNING_ALLOWED=NO",
                "build",
            ],
            cwd=work,
            env=env,
            capture_output=True,
            text=True,
            timeout=120,
        )
        output = xcode.stdout + xcode.stderr
        (parent / (label + "-comment-xcode.log")).write_text(output)
        assert (
            xcode.returncode
            and "Base.xcconfig:2:1: error: unexpected character" in output
        ), output[-2000:]


def scalar_values(work):
    podfile = work / "Podfile"
    podfile.write_text(
        podfile.read_text().removesuffix("end\n")
        + """  i.pods_project.targets.each do |target|
    target.build_configurations.each do |configuration|
      configuration.build_settings.merge!(
        'OTHER_CFLAGS' => nil, 'PROBE_NIL' => nil,
        'PROBE_BOOL' => true, 'PROBE_FALSE' => false,
        'PROBE_INT' => 42, 'PROBE_FLOAT' => 1.0,
        'PROBE_ARRAY' => ['before', nil, false, true, 42, 1.0]
      )
    end
  end
end
"""
    )


def invalid_assignments(parent, env):
    for label, operation in [("append", "+="), ("default", "?=")]:
        for nested in [False, True]:
            case = label + ("-included" if nested else "-root")
            work, selected = create(parent / ("invalid-assignment-" + case))
            podfile = work / "Podfile"
            podfile.write_text(
                podfile.read_text()
                + "pre_install { |_| File.write('pre-hook-ran', 'yes') }\n"
            )
            base = selected.parent / "Configs/Base.xcconfig"
            invalid = base.with_name("Invalid.xcconfig") if nested else base
            if nested:
                base.write_text(base.read_text() + '#include "Invalid.xcconfig"\n')
            invalid.write_text("SDKROOT = macosx\nVALUE " + operation + " child\n")
            original = (selected / "project.pbxproj").read_bytes()
            result = subprocess.run(
                [str(debug_binary()), "install", "--json"],
                cwd=work,
                env=env,
                capture_output=True,
                text=True,
                timeout=90,
            )
            (parent / (case + "-assignment-native.log")).write_text(
                result.stdout + result.stderr
            )
            report = json.loads(result.stdout)
            assert (
                result.returncode
                and report["project_state"] == "failed_no_managed_changes"
            ), report
            assert any(
                event.get("code") == "SP-XCCONFIG-SYNTAX"
                and event.get("file") == str(invalid)
                and event.get("line") == 2
                for event in report["events"] + [report.get("diagnostic", {})]
            ), report
            assert not (work / "pre-hook-ran").exists()
            assert not (work / "resolved-settings.json").exists()
            assert not (work / "Podfile.lock").exists()
            assert not (work / "Pods/Pods.xcodeproj").exists()
            assert (selected / "project.pbxproj").read_bytes() == original
            xcode = subprocess.run(
                [
                    "xcodebuild",
                    "-project",
                    str(selected),
                    "-target",
                    "Demo",
                    "-configuration",
                    "Debug",
                    "CODE_SIGNING_ALLOWED=NO",
                    "build",
                ],
                cwd=work,
                env=env,
                capture_output=True,
                text=True,
                timeout=120,
            )
            output = xcode.stdout + xcode.stderr
            (parent / (case + "-assignment-xcode.log")).write_text(output)
            assert (
                xcode.returncode and str(invalid) + ":2:1: error: expected a" in output
            ), output[-2000:]


def verify_scalar_values(project, env, log):
    result = subprocess.run(
        [
            "xcodebuild",
            "-project",
            str(project),
            "-target",
            "Kit",
            "-configuration",
            "Debug",
            "-showBuildSettings",
            "-json",
        ],
        capture_output=True,
        text=True,
        env=env,
        timeout=90,
    )
    log.write_text(result.stdout + result.stderr)
    assert result.returncode == 0 and "warning:" not in result.stderr, result.stderr
    values = next(
        row["buildSettings"]
        for row in json.loads(result.stdout)
        if row["target"] == "Kit"
    )
    expected = {
        "PROBE_BOOL": "true",
        "PROBE_FALSE": "false",
        "PROBE_INT": "42",
        "PROBE_FLOAT": "1.0",
        "PROBE_ARRAY": "before  false true 42 1.0",
    }
    assert all(values.get(key) == value for key, value in expected.items()), values
    assert values.get("PROBE_NIL", "") == values.get("OTHER_CFLAGS", "") == "", values
    return {
        key: values.get(key, "") for key in [*expected, "PROBE_NIL", "OTHER_CFLAGS"]
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gem-home", type=Path)
    args = parser.parse_args()
    parent = fixture_directory("native-xcconfig-")
    print("External xcconfig fixtures:", parent, flush=True)
    env = environment()
    env["SWIFTPODS_CACHE_ROOT"] = str(parent / "cache")
    observations = {}
    lexical_observations = {}
    scalar_observations = {}
    for engine in ["native", "reference"] if args.gem_home else ["native"]:
        work, selected = create(parent / engine)
        lexical_expected = lexical_values(work, selected)
        scalar_values(work)
        if engine == "native":
            command, selected_env = (
                [str(debug_binary()), "install", "--json"],
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
        lexical_observations[engine] = json.loads(
            (work / "lexical-settings.json").read_text()
        )
        for key, expected in lexical_expected.items():
            assert lexical_observations[engine][key] == {
                "Debug": expected,
                "Release": expected,
            }, (engine, key, lexical_observations[engine])
        scalar_observations[engine] = verify_scalar_values(
            work / "Pods/Pods.xcodeproj",
            selected_env,
            parent / (engine + "-scalar-settings.log"),
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
                [str(debug_binary()), "deintegrate", "--json"],
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
        assert scalar_observations["native"] == scalar_observations["reference"]
    syntax_observations = (
        syntax_regressions(parent, env, create) if not args.gem_home else None
    )
    invalid_block_comments(parent, env)
    invalid_assignments(parent, env)
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
            "recursive path patterns remain literal xcconfig values",
            "inline block markers remain literal xcconfig values",
            "quoted custom settings keep their quotes",
            "block markers in line comments cannot consume subsequent assignments",
            "hook-copied quoted recursive header paths build in Debug and Release",
            "unsupported block comment syntax rejected before hooks and writes, matching Xcode builds",
            "nil hook build settings clear compiler flags and preserve successful builds",
            "boolean hook build settings keep Ruby scalar spelling",
            "floating point hook build settings keep decimal precision",
            "mixed scalar arrays preserve Xcode-observed values",
            "non-Xcode assignment operators rejected before hooks and managed writes",
            "nested invalid assignments report original file and line, matching Xcode builds",
        ],
        "lexical_observations": lexical_observations,
        "scalar_observations": scalar_observations,
        "unverified": ["all xcconfig conditional axes and substitution operators"],
    }
    if syntax_observations is not None:
        report["verified"] += SYNTAX_VERIFIED
        report["syntax_observations"] = syntax_observations
    if args.gem_home:
        report["reference"] = "1.17.0"
    name = "native-xcconfig-reference.json" if args.gem_home else "native-xcconfig.json"
    (results_directory() / name).write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    import sys

    execute(
        main,
        "native-xcconfig-reference.json"
        if "--gem-home" in sys.argv
        else "native-xcconfig.json",
    )
