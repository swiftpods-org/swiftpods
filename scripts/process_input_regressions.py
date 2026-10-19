"""Process descriptors and environment names retain their declared meaning."""

import json
import platform
import subprocess
import tempfile
from pathlib import Path

from bootstrap import ROOT
from name_boundary_regressions import diagnostic
from native_xcconfig_tests import create
from project_path_regressions import reinstall
from vendor_fixture import fixture_build_arguments, run


def capture_regressions(fixture):
    with tempfile.TemporaryDirectory(
        prefix="process-capture-", dir=fixture.root
    ) as temporary:
        build = Path(temporary)
        include = ROOT / "Sources/ProcessSupport/include"
        (build / "module.modulemap").write_text(
            "module ProcessSupport { header "
            + json.dumps(str(include / "ProcessSupport.h"))
            + " export * }\n"
        )
        object_file = build / "ProcessSupport.o"
        run(
            [
                "xcrun",
                "clang",
                "-std=c11",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-mmacosx-version-min=13.0",
                "-I",
                include,
                "-c",
                ROOT / "Sources/ProcessSupport/ProcessSupport.c",
                "-o",
                object_file,
            ],
            ROOT,
            fixture.root / "process-capture-c-build.log",
        )
        sources = [
            ROOT / "Sources/SwiftPodsCore" / (name + ".swift")
            for name in [
                "NativeChildProcess",
                "ToolProcess",
                "NativeGitEnvironment",
                "NativeProcessEnvironment",
                "Diagnostics",
                "NativeJSON",
                "NativeDictionaryKeys",
                "NativeScalarString",
            ]
        ]
        binary = build / "process-input-fixture"
        run(
            [
                "xcrun",
                "swiftc",
                "-swift-version",
                "5",
                "-warnings-as-errors",
                "-target",
                platform.machine() + "-apple-macosx13.0",
                "-I",
                build,
                *sources,
                ROOT / "Tests/Fixtures/ProcessInputFixture.swift",
                object_file,
                "-o",
                binary,
            ],
            ROOT,
            fixture.root / "process-capture-swift-build.log",
        )
        inherited = " q\u0301 'quoted' = value\t東京 "
        for mode in ["inherit", *map(str, range(1, 8))]:
            observation = build / (mode + ".json")
            arguments = (
                {"input": inherited + "\n"}
                if mode == "inherit"
                else {"stdin": subprocess.DEVNULL}
            )
            driver = subprocess.run(
                [str(binary), mode, str(observation)],
                capture_output=True,
                text=True,
                timeout=8,
                **arguments,
            )
            assert driver.returncode == 0, (mode, driver.stdout, driver.stderr)
            actual = json.loads(observation.read_text())
            expected = {
                "status": 0,
                "output": inherited if mode == "inherit" else "read-status=1",
                "error": "" if mode == "inherit" else "fixture-error",
            }
            (fixture.root / ("process-capture-" + mode + ".json")).write_text(
                json.dumps(actual, indent=2) + "\n"
            )
            assert actual == expected, (mode, actual, expected)
            fixture.verified.append("process_capture_preserves_streams_" + mode)


def invalid_scheme_names(fixture):
    for scope in ["library", "test", "app"]:
        for label, name in [
            ("empty", ""),
            ("equals", "FIELD=SUFFIX"),
            ("equals-mark", "FIELD=\u0301Suffix"),
        ]:
            work, selected = create(
                fixture.root / ("scheme-environment-" + scope + "-" + label)
            )
            spec = work / "Kit/Kit.podspec.json"
            attributes = json.loads(spec.read_text())
            options = {"environment_variables": {name: "value"}}
            if scope == "library":
                attributes["scheme"] = options
            else:
                attributes["testspecs" if scope == "test" else "appspecs"] = [
                    {"name": "Inputs", "scheme": options}
                ]
            attributes["prepare_command"] = "printf ran > prepare-ran"
            spec.write_text(json.dumps(attributes))
            podfile = work / "Podfile"
            podfile.write_text(
                podfile.read_text()
                + "pre_install { |_| File.write('pre-hook-ran', 'yes') }\n"
            )
            originals = {
                p: p.read_bytes() for p in [spec, podfile, selected / "project.pbxproj"]
            }
            for action, arguments in [
                ("quick_lint", ["spec", "lint", str(spec), "--quick"]),
                ("install", ["install"]),
            ]:
                result = fixture.cli(work, *arguments, succeeds=False)
                assert diagnostic(result, "SP-SPEC-SCHEME"), result
                expected_state = (
                    "untracked"
                    if action == "quick_lint"
                    else "failed_no_managed_changes"
                )
                assert result["project_state"] == expected_state, result
                assert all(p.read_bytes() == before for p, before in originals.items())
                assert (
                    not (work / "Pods").exists()
                    and not (work / "Podfile.lock").exists()
                )
                assert (
                    not (work / "pre-hook-ran").exists()
                    and not (work / "Kit/prepare-ran").exists()
                )
                fixture.verified.append(
                    "scheme_environment_rejects_"
                    + scope
                    + "_"
                    + label
                    + "_"
                    + action
                    + "_before_hooks_and_writes"
                )


def valid_scheme_execution(fixture):
    work, selected = create(fixture.root / "scheme-environment-valid")
    spec = work / "Kit/Kit.podspec.json"
    attributes = json.loads(spec.read_text())
    values = {
        "SWIFTPODS_\u0301NAME": "a=b\nnext",
        "SWIFTPODS SPACE": "東京 🧩",
        "SWIFTPODS_EMPTY": "",
    }
    attributes["testspecs"] = [
        {
            "name": "Inputs",
            "platforms": {"osx": "14.0"},
            "source_files": "ProcessInputs.m",
            "scheme": {"environment_variables": values},
        }
    ]
    spec.write_text(json.dumps(attributes))
    original = spec.read_bytes()
    source = "#import <XCTest/XCTest.h>\n@interface ProcessInputs : XCTestCase @end\n@implementation ProcessInputs\n- (void)testDeclaredEnvironmentReachesProcess {\n"
    for name, value in values.items():
        source += (
            "XCTAssertEqualObjects(NSProcessInfo.processInfo.environment[@"
            + json.dumps(name, ensure_ascii=False)
            + "], @"
            + json.dumps(value, ensure_ascii=False)
            + ");\n"
        )
    (work / "Kit/ProcessInputs.m").write_text(source + "}\n@end\n")
    podfile = work / "Podfile"
    podfile.write_text(
        podfile.read_text().replace(
            "pod 'Kit', :path => './Kit'",
            "pod 'Kit', :path => './Kit', :testspecs => ['Inputs']",
        )
    )
    fixture.cli(work, "install")
    reinstall(fixture, work, selected)
    assert spec.read_bytes() == original
    fixture.verified.append(
        "scheme_environment_valid_names_preserve_offline_reinstall_inputs_and_projects"
    )
    output = fixture.root / "scheme-environment-build"
    output.mkdir()
    for configuration in ["Debug", "Release"]:
        text = run(
            [
                "xcodebuild",
                "-project",
                "Pods/Pods.xcodeproj",
                "-scheme",
                "Kit-Unit-Inputs",
                "-configuration",
                configuration,
                "-destination",
                "platform=macOS,arch=" + platform.machine(),
                *fixture_build_arguments(output),
                "CODE_SIGNING_ALLOWED=NO",
                "GCC_TREAT_WARNINGS_AS_ERRORS=YES",
                "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES",
                "test",
            ],
            work,
            fixture.root / ("scheme-environment-" + configuration + ".log"),
            env=fixture.env,
        )
        assert (
            "** TEST SUCCEEDED **" in text
            and "testDeclaredEnvironmentReachesProcess" in text
        )
    fixture.verified.append(
        "scheme_environment_valid_names_and_values_reach_running_xctest_debug_release"
    )


def cli_stdin_controls(fixture):
    for mode in ["closed", "data"]:
        work, _ = create(fixture.root / ("cli-stdin-" + mode))
        spec = work / "Kit/Kit.podspec.json"
        attributes = json.loads(spec.read_text())
        attributes["prepare_command"] = (
            "read value; printf '%s' \"$?\" > prepare-stdin.txt"
            if mode == "closed"
            else "IFS= read -r value; printf '%s' \"$value\" > prepare-stdin.txt"
        )
        spec.write_text(json.dumps(attributes))
        original = spec.read_bytes()
        value = " q\u0301 'quoted' = value\t東京 "
        fixture.cli(
            work,
            "install",
            close_stdin=mode == "closed",
            stdin=value + "\n" if mode == "data" else None,
        )
        assert (work / "Kit/prepare-stdin.txt").read_text() == (
            value if mode == "data" else "1"
        )
        assert spec.read_bytes() == original
        fixture.verified.append("cli_prepare_preserves_" + mode + "_stdin")


def run_regressions(fixture):
    capture_regressions(fixture)
    invalid_scheme_names(fixture)
    valid_scheme_execution(fixture)
    cli_stdin_controls(fixture)
