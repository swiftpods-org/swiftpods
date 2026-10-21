#!/usr/bin/env python3
"""Exercise actual Xcode script execution, incrementality and hardened rejection."""

import json
import platform
import subprocess

from bootstrap import environment
from local_build import debug_binary, fixture_directory, results_directory
from reporting import execute
from script_phase_fixture import create, phase_graph, podfile, specification, write_spec
from vendor_fixture import run


def cli(work, env, *args, success=True):
    result = subprocess.run(
        [str(debug_binary()), *args, "--json"],
        cwd=work,
        env=env,
        capture_output=True,
        text=True,
        timeout=90,
    )
    if (result.returncode == 0) != success:
        raise RuntimeError(result.stderr + result.stdout)
    return json.loads(result.stdout)


def build(work, base, label, success=True):
    arguments = [
        "xcodebuild",
        "-workspace",
        "Demo.xcworkspace",
        "-scheme",
        "Demo",
        "-configuration",
        "Debug",
        "-destination",
        "platform=macOS,arch=" + platform.machine(),
        "-derivedDataPath",
        base / "DerivedData",
        "CODE_SIGNING_ALLOWED=NO",
        "build",
    ]
    if success:
        run(arguments, work, base / (label + ".log"))
        binary = base / "DerivedData/Build/Products/Debug/Demo.app/Contents/MacOS/Demo"
        return subprocess.check_output([str(binary)], text=True).strip()
    result = subprocess.run(
        [str(arg) for arg in arguments],
        cwd=work,
        capture_output=True,
        text=True,
        timeout=180,
    )
    base.joinpath(label + ".log").write_text(result.stdout + result.stderr)
    assert (
        result.returncode != 0
        and "fixture deliberate error" in result.stdout + result.stderr
    )


def exercise(base, linkage):
    base.mkdir()
    work = base / "project"
    module = create(work, linkage)
    env = environment()
    env["GEM_HOME"] = str(base / "empty-gems")
    env["GEM_PATH"] = env["GEM_HOME"]
    env["SWIFTPODS_CACHE_ROOT"] = str(base / "cache")
    cli(work, env, "install")

    def state():
        return {
            name: (base / "DerivedData/Build/Products/Debug" / filename)
            .read_text()
            .splitlines()
            if (base / "DerivedData/Build/Products/Debug" / filename).exists()
            else []
            for name, filename in [
                (name, "phase-" + name + ".txt")
                for name in [
                    "before-headers",
                    "generate",
                    "after-headers",
                    "after-compile",
                    "any",
                ]
            ]
            + [("app", "app-check.txt"), ("original", "original.txt")]
        }

    assert all(not lines for lines in state().values()), (
        "Install executed a build phase"
    )

    def phases():
        return phase_graph(work / "Pods/Pods.xcodeproj/project.pbxproj", "ScriptKit")

    names = [
        phase["name"]
        for phase in phases()
        if phase.get("name", "").startswith("[CP-User] ")
    ]
    assert len(names) == 5 and len(set(names)) == 5, names
    before = work.joinpath("Demo.xcodeproj/project.pbxproj").read_bytes()
    lock = work.joinpath("Podfile.lock").read_bytes()
    cli(work, env, "install", "--offline", "--deployment")
    assert lock == work.joinpath("Podfile.lock").read_bytes()
    assert before == work.joinpath("Demo.xcodeproj/project.pbxproj").read_bytes()
    assert all(not lines for lines in state().values())
    assert build(work, base, "first") == "script-value=41"
    trace = state()
    assert all(lines == [name] for name, lines in trace.items()), trace
    text = base.joinpath("first.log").read_text().replace("\\", "")
    positions = [
        text.index("PhaseScriptExecution [CP-User] " + name + " ")
        for name in [
            "before-headers",
            "generate",
            "after-headers",
            "after-compile",
            "any",
            "app",
        ]
    ]
    assert positions == sorted(positions), positions
    assert build(work, base, "unchanged") == "script-value=41"
    trace = state()
    assert len(trace["generate"]) == 1 and len(trace["any"]) == 2, trace
    module.joinpath("input value.txt").write_text("73\n")
    assert build(work, base, "changed") == "script-value=73"
    trace = state()
    assert len(trace["generate"]) == 2 and len(trace["any"]) == 3, trace
    if linkage == "static":
        # Regeneration removes pod/Podfile phases and preserves user phases.
        data = specification()
        data.pop("script_phase")
        data["osx"].pop("script_phases")
        data["subspecs"][0].pop("script_phases")
        write_spec(module, data)
        podfile(work, linkage, scripts=False)
        module.joinpath("ScriptKit.m").write_text(
            '#import "ScriptKit.h"\nint scriptkit_value(void) { return 7; }\n'
        )
        cli(work, env, "install")
        assert not any(
            phase.get("name", "").startswith("[CP-User] ") for phase in phases()
        )
        app_phases = phase_graph(work / "Demo.xcodeproj/project.pbxproj", "Demo")
        assert not any(
            phase.get("name", "").startswith("[CP-User] ") for phase in app_phases
        )
        assert (
            sum(phase.get("name") == "Original User Script" for phase in app_phases)
            == 1
        )
        assert build(work, base, "removed") == "script-value=7"
        data["script_phase"] = {
            "name": "Fail",
            "script": 'echo "fixture deliberate error" >&2\nexit 23\n',
            "always_out_of_date": "1",
        }
        write_spec(module, data)
        cli(work, env, "install")
        build(work, base, "script-failure", success=False)
        managed = {
            path: path.read_bytes()
            for path in [
                work / "Podfile.lock",
                work / "Demo.xcodeproj/project.pbxproj",
                work / "Pods/Pods.xcodeproj/project.pbxproj",
                work / "Pods/Local Podspecs/ScriptKit.podspec.json",
            ]
        }
        data["script_phase"]["execution_position"] = "after_link"
        write_spec(module, data)
        rejected = cli(work, env, "install", success=False)
        assert any(
            event.get("code") == "SP-SCRIPT-POSITION" for event in rejected["events"]
        )
        assert rejected["project_state"] == "failed_no_managed_changes", rejected
        assert all(path.read_bytes() == content for path, content in managed.items())
        # The restricted JSON path must reject platform/subspec scripts, too.
        data.pop("script_phase")
        data["subspecs"][0]["osx"] = {
            "script_phases": [{"name": "Hidden", "script": "touch should-not-run"}]
        }
        module.joinpath("ScriptKit.podspec.json").write_text(json.dumps(data))
        work.joinpath("Podfile.json").write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "project": "Demo.xcodeproj",
                    "platform": {"name": "osx", "deployment_target": "13.0"},
                    "targets": [
                        {
                            "name": "Demo",
                            "pods": [
                                {"name": "ScriptKit", "path": "./Modules/ScriptKit"}
                            ],
                        }
                    ],
                }
            )
        )
        env["SWIFTPODS_RUBY"] = "/no-ruby"
        rejected = cli(work, env, "install", "--hardened", success=False)
        assert any(
            event.get("code") == "SP-HARDENED-SCRIPT" for event in rejected["events"]
        )
        assert not module.joinpath("should-not-run").exists()
    return {"linkage": linkage or "static-library", "status": "passed", "trace": trace}


def main():
    base = fixture_directory("native-script-phases-")
    print("Script fixtures:", base, flush=True)
    scenarios = [
        exercise(base / (linkage or "library"), linkage)
        for linkage in ("static", "dynamic", None)
    ]
    report = {
        "status": "passed",
        "engine": "swift",
        "fixture": str(base),
        "scenarios": scenarios,
        "verified": [
            "podspec singular/plural, subspec and platform phases",
            "Podfile phases",
            "all five execution positions",
            "scripts deferred until build",
            "generated header compilation and native environment",
            "file lists, dependency file and incremental regeneration",
            "always-out-of-date phases",
            "three pod linkage modes",
            "idempotent offline reinstall",
            "phase removal preserves user scripts",
            "build phase failure propagation",
            "invalid phases rejected before managed changes",
            "nested hardened script rejection without Ruby",
            "Xcode user script sandbox with declared inputs/outputs",
        ],
        "unverified": [
            "iOS script execution",
            "all script interpreters",
            "complete DSL/API parity",
        ],
    }
    results_directory().joinpath("native-script-phases.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    execute(main, "native-script-phases.json")
