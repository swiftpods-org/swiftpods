"""Check xcconfig grammar and literal include paths against real Xcode builds."""

import json
import platform
import subprocess

from scripts.support.local_build import debug_binary
from scripts.support.processes import run_logged
from Tests.Fixtures.vendor_fixture import (
    fixture_build_arguments,
    fixture_derived_data,
    run,
)

KEYS = [
    "SYNTAX_PAREN",
    "SYNTAX_BRACE",
    "SYNTAX_ROOT",
    "SYNTAX_CONFIG",
    "SYNTAX_OPTIONAL",
    "SYNTAX_UNUSED",
    "SYNTAX_NUL",
]
VERIFIED = [
    "whitespace before and between xcconfig conditions matches Xcode",
    "whitespace after the include hash matches Xcode",
    "conditional patterns and contexts cannot truncate at NUL",
    "include paths preserve literal variable and SRCROOT syntax",
    "optional literal includes cannot select expanded paths",
    "hook include observations match Xcode and execute in Debug and Release",
    "xcconfig syntax fixtures preserve inputs and offline reinstall bytes",
    "malformed conditions and include tokens fail before hooks and managed writes",
    "invalid pod, user and legacy xcconfig keys fail before hooks and managed writes",
]


def diagnostics(report):
    return report.get("events", []) + [report.get("diagnostic", {})]


def cli(work, parent, label, env, *arguments):
    log = parent / (label + ".log")
    run([debug_binary(), *arguments, "--json"], work, log, env=env)


def xcode_settings(work, selected, parent, env, configuration):
    result = subprocess.run(
        [
            "xcodebuild",
            "-project",
            str(selected),
            "-scheme",
            "Demo",
            "-configuration",
            configuration,
            "-showBuildSettings",
            "-json",
        ],
        cwd=work,
        env=env,
        capture_output=True,
        text=True,
        timeout=120,
    )
    log = parent / ("syntax-" + configuration + "-settings.log")
    log.write_text(result.stdout + result.stderr)
    assert result.returncode == 0 and "warning:" not in result.stderr, log
    return next(
        row["buildSettings"]
        for row in json.loads(result.stdout)
        if row["target"] == "Demo"
    )


def valid_syntax(parent, env, create):
    work, selected = create(parent / "valid-xcconfig-syntax")
    configs = selected.parent / "Configs"
    base = configs / "Base.xcconfig"
    base.write_text(
        base.read_text() + "DIR = Expanded\nOPTIONAL_DIR = Expanded\n"
        '# include "$(DIR)/Parentheses.xcconfig" // "comment"\n'
        '#\tinclude "${DIR}/Braces.xcconfig"\n'
        '# include "$(SRCROOT)/Root.xcconfig"\n'
        '# include? "$(OPTIONAL_DIR)/Optional.xcconfig"\n'
        "SYNTAX_CONFIG [sdk=macosx*] [config=Debug] = 11\n"
        "SYNTAX_CONFIG\t[sdk=macosx*] [config=Release] = 13\n"
        "SYNTAX_UNUSED[sdk =macosx*] = 89\n"
        "SYNTAX_NUL[sdk=macosx\0wrong] = 83\n"
        "GCC_PREPROCESSOR_DEFINITIONS [sdk=macosx*] [config=Debug] = $(inherited) SYNTAX_DEBUG=11\n"
        "GCC_PREPROCESSOR_DEFINITIONS [sdk=macosx*] [config=Release] = $(inherited) SYNTAX_RELEASE=13\n"
    )
    for name, content in {
        "$(DIR)/Parentheses.xcconfig": "SYNTAX_PAREN = 17\n",
        "${DIR}/Braces.xcconfig": "SYNTAX_BRACE = 19\n",
        "$(SRCROOT)/Root.xcconfig": "SYNTAX_ROOT = 23\n",
        "Expanded/Parentheses.xcconfig": "SYNTAX_PAREN = 91\n",
        "Expanded/Braces.xcconfig": "SYNTAX_BRACE = 93\n",
        "Expanded/Optional.xcconfig": "SYNTAX_OPTIONAL = 97\n",
        "../Root.xcconfig": "SYNTAX_ROOT = 95\n",
    }.items():
        path = configs / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
    source = selected.parent / "Sources/main.mm"
    source.write_text(
        "#if NATIVE_SYNTAX_PAREN != 17 || NATIVE_SYNTAX_BRACE != 19 || NATIVE_SYNTAX_ROOT != 23\n"
        "#error Hook_selected_the_wrong_include_path\n#endif\n"
        "#if NATIVE_SYNTAX_OPTIONAL != 0 || NATIVE_SYNTAX_UNUSED != 0 || NATIVE_SYNTAX_NUL != 0\n"
        "#error Optional_include_or_literal_condition_whitespace_was_expanded\n#endif\n"
        "#if defined(SYNTAX_DEBUG)\n"
        "#if NATIVE_SYNTAX_CONFIG != 11 || SYNTAX_DEBUG != 11\n#error Debug_condition_was_lost\n#endif\n"
        "#elif defined(SYNTAX_RELEASE)\n"
        "#if NATIVE_SYNTAX_CONFIG != 13 || SYNTAX_RELEASE != 13\n#error Release_condition_was_lost\n#endif\n"
        "#else\n#error Spaced_conditions_were_lost\n#endif\n" + source.read_text()
    )
    podfile = work / "Podfile"
    podfile.write_text(
        podfile.read_text().removesuffix("end\n")
        + "  keys = "
        + json.dumps(KEYS)
        + "\n"
        + """  values = keys.to_h { |key| [key, t.resolved_build_setting(key, true)] }
  File.write('syntax-settings.json', JSON.generate(values))
  t.build_configurations.each do |configuration|
    flags = keys.map { |key| "-DNATIVE_#{key}=#{values[key].fetch(configuration.name, '0')}" }
    configuration.build_settings['OTHER_CPLUSPLUSFLAGS'] = '$(inherited) ' + flags.join(' ')
  end
end
"""
    )
    inputs = {
        path: path.read_bytes()
        for path in [
            *configs.rglob("*.xcconfig"),
            configs.parent / "Root.xcconfig",
            work / "Kit/Kit.podspec.json",
            podfile,
        ]
    }
    expected = {
        "SYNTAX_PAREN": {"Debug": "17", "Release": "17"},
        "SYNTAX_BRACE": {"Debug": "19", "Release": "19"},
        "SYNTAX_ROOT": {"Debug": "23", "Release": "23"},
        "SYNTAX_CONFIG": {"Debug": "11", "Release": "13"},
        "SYNTAX_OPTIONAL": {},
        "SYNTAX_UNUSED": {},
        "SYNTAX_NUL": {},
    }
    observed = {key: {} for key in KEYS}
    for configuration in ["Debug", "Release"]:
        values = xcode_settings(work, selected, parent, env, configuration)
        for key in KEYS:
            if key in values:
                observed[key][configuration] = values[key]
    assert observed == expected, observed
    cli(work, parent, "syntax-install", env, "install")
    actual = json.loads((work / "syntax-settings.json").read_text())
    assert actual == expected, actual
    project = selected / "project.pbxproj"
    locked = (work / "Podfile.lock").read_bytes()
    project_bytes = project.read_bytes()
    cli(work, parent, "syntax-reinstall", env, "install", "--offline", "--deployment")
    assert (work / "Podfile.lock").read_bytes() == locked
    assert project.read_bytes() == project_bytes
    assert all(path.read_bytes() == original for path, original in inputs.items())
    for configuration in ["Debug", "Release"]:
        build = parent / ("syntax-" + configuration)
        build.mkdir()
        run(
            [
                "xcodebuild",
                "-workspace",
                next(work.glob("*.xcworkspace")),
                "-scheme",
                "Demo",
                "-configuration",
                configuration,
                "-destination",
                "platform=macOS,arch=" + platform.machine(),
                *fixture_build_arguments(build),
                "CODE_SIGNING_ALLOWED=NO",
                "build",
            ],
            work,
            parent / ("syntax-" + configuration + "-build.log"),
            env=env,
        )
        binary = (
            fixture_derived_data(build)
            / "Build/Products"
            / configuration
            / "Demo.app/Contents/MacOS/Demo"
        )
        output = run(
            [binary], work, parent / ("syntax-" + configuration + "-run.log"), env=env
        )
        assert output.strip() == "value=7 user=1 conditional=1", output
    return {"native": actual, "xcode": observed, "offline_reinstall": "unchanged"}


def rejected(work, selected, parent, env, label, code, file=None, line=None):
    podfile = work / "Podfile"
    podfile.write_text(
        podfile.read_text() + "pre_install { |_| File.write('pre-hook-ran', 'yes') }\n"
    )
    project = selected / "project.pbxproj"
    original = project.read_bytes()
    spec = work / "Kit/Kit.podspec.json"
    spec_bytes = spec.read_bytes()
    result = subprocess.run(
        [str(debug_binary()), "install", "--json"],
        cwd=work,
        env=env,
        capture_output=True,
        text=True,
        timeout=120,
    )
    log = parent / (label + "-native.log")
    log.write_text(result.stdout + result.stderr)
    report = json.loads(result.stdout)
    assert (
        result.returncode and report["project_state"] == "failed_no_managed_changes"
    ), log
    errors = [event for event in diagnostics(report) if event.get("code") == code]
    assert errors, log
    if file is not None:
        assert any(
            event.get("file") == str(file) and event.get("line") == line
            for event in errors
        ), errors
    assert not (work / "pre-hook-ran").exists()
    assert not (work / "resolved-settings.json").exists()
    assert not (work / "Podfile.lock").exists()
    assert not (work / "Pods/Pods.xcodeproj").exists()
    assert project.read_bytes() == original and spec.read_bytes() == spec_bytes
    return {"native_status": result.returncode, "diagnostics": errors}


def invalid_syntax(parent, env, create):
    observations = {}
    for label, text, code, nested in [
        (
            "condition",
            "VALUE[sdk=macosx*][bad] = selected",
            "SP-XCCONFIG-SYNTAX",
            False,
        ),
        ("directive", '#included "Leaf.xcconfig"', "SP-XCCONFIG-INCLUDE", False),
        ("prefix", '#include unexpected "Leaf.xcconfig"', "SP-XCCONFIG-INCLUDE", False),
        ("suffix", '#include "Leaf.xcconfig" trailing', "SP-XCCONFIG-INCLUDE", False),
        ("optional-gap", '#include ? "Leaf.xcconfig"', "SP-XCCONFIG-INCLUDE", False),
        (
            "nested-suffix",
            '#include "Leaf.xcconfig" trailing',
            "SP-XCCONFIG-INCLUDE",
            True,
        ),
    ]:
        work, selected = create(parent / ("invalid-syntax-" + label))
        base = selected.parent / "Configs/Base.xcconfig"
        invalid = base.with_name("Invalid.xcconfig") if nested else base
        if nested:
            base.write_text(base.read_text() + '#include "Invalid.xcconfig"\n')
        invalid.write_text("SDKROOT = macosx\n" + text + "\n")
        base.with_name("Leaf.xcconfig").write_text("VALUE = selected\n")
        row = rejected(work, selected, parent, env, label, code, invalid, 2)
        (selected.parent / "Sources/main.mm").write_text(
            "int main(void) { return 0; }\n"
        )
        build = parent / ("invalid-build-" + label)
        build.mkdir()
        log = parent / (label + "-xcode.log")
        status = run_logged(
            [
                "xcodebuild",
                "-project",
                selected,
                "-scheme",
                "Demo",
                "-configuration",
                "Debug",
                "-destination",
                "platform=macOS,arch=" + platform.machine(),
                *fixture_build_arguments(build),
                "CODE_SIGNING_ALLOWED=NO",
                "build",
            ],
            work,
            log,
            env=env,
            timeout=180,
        )
        output = log.read_text(errors="replace")
        assert status and str(invalid) + ":2:1: error:" in output, log
        assert " warning:" not in output and "\nwarning:" not in output, log
        row["xcode_build_status"] = status
        observations[label] = row
    for attribute in ["xcconfig", "pod_target_xcconfig", "user_target_xcconfig"]:
        for index, key in enumerate(["VALUE[sdk=macosx*][bad]", "VALUE[=macosx*]"]):
            label = attribute + "-key-" + str(index)
            work, selected = create(parent / label)
            spec = work / "Kit/Kit.podspec.json"
            data = json.loads(spec.read_text())
            data[attribute] = {key: "selected"}
            spec.write_text(json.dumps(data))
            observations[label] = rejected(
                work, selected, parent, env, label, "SP-XCCONFIG-KEY"
            )
    return observations


def syntax_regressions(parent, env, create):
    return {
        "valid": valid_syntax(parent, env, create),
        "invalid": invalid_syntax(parent, env, create),
    }
