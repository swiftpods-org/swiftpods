#!/usr/bin/env python3
"""Check real lint consumers for owned headers and C++ public interfaces."""

import json
import subprocess

from bootstrap import environment
from local_build import debug_binary, fixture_directory, results_directory
from reporting import execute


class Fixture:
    def __init__(self):
        self.root = fixture_directory("native-lint-interface-")
        self.env = environment()
        self.env["SWIFTPODS_CACHE_ROOT"] = str(self.root / "cache")
        self.verified = []
        self.observations = []

    def library(self, label, fields, files):
        work = self.root / label
        work.mkdir()
        for name, text in files.items():
            path = work / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        data = {
            "name": "Kit",
            "version": "1.0",
            "summary": "Lint interface fixture.",
            "homepage": "https://swiftpods.org",
            "authors": "SwiftPods",
            "license": {"type": "MIT", "text": "Fixture license"},
            "platforms": {"osx": "14.0"},
            "source": {"git": "https://example.invalid/kit.git", "tag": "1.0"},
            **fields,
        }
        spec = work / "Kit.podspec.json"
        spec.write_text(json.dumps(data))
        return spec

    def lint(self, spec, flags, passed, label):
        result = subprocess.run(
            [
                str(debug_binary()),
                "lib",
                "lint",
                str(spec),
                "--platforms=osx",
                *flags,
                "--json",
            ],
            cwd=spec.parent,
            env=self.env,
            capture_output=True,
            text=True,
            timeout=240,
        )
        log = self.root / (label + ".log")
        log.write_text(result.stdout + result.stderr)
        report = json.loads(result.stdout)
        validation = next(
            event["data"] for event in report["events"] if event["kind"] == "validation"
        )
        self.observations.append(
            {
                "case": label,
                "exit_status": result.returncode,
                "validation": validation,
                "log": str(log),
            }
        )
        assert (result.returncode == 0) == passed, (label, log, validation)
        assert validation["status"] == ("passed" if passed else "failed"), validation
        assert all(not entry["warnings"] for entry in validation["specifications"]), (
            validation
        )
        self.verified.append(label)
        return validation


def ownership(fixture, mask):
    fields = {
        "exclude_files": "B.h",
        "private_header_files": "B.h",
        "project_header_files": "B.h",
        "public_header_files": "A.h",
    }
    spec = fixture.library(
        "ownership-" + mask,
        {
            "module_map": False,
            "subspecs": [
                {"name": "A", "source_files": "A.h", mask: fields[mask]},
                {"name": "B", "source_files": "B.h"},
            ],
        },
        {
            "A.h": "#pragma once\ntypedef struct { int a; } PublicType;\n",
            "B.h": "#pragma once\ntypedef struct { int b; } PublicType;\n",
        },
    )
    report = fixture.lint(
        spec,
        ["--use-libraries"],
        False,
        mask + "-rejects-conflicting-combined-interface",
    )
    errors = report["errors"]
    assert any(
        error["specification"] == "Kit"
        and error["code"] == "SP-LINT-CONSUMER"
        and "PublicType" in error["message"]
        for error in errors
    ), report
    assert not any(error["specification"] in ["Kit/A", "Kit/B"] for error in errors), (
        report
    )
    (spec.parent / "B.h").write_text(
        "#pragma once\ntypedef struct { int b; } OtherPublicType;\n"
    )
    report = fixture.lint(
        spec, ["--use-libraries"], True, mask + "-accepts-corrected-combined-interface"
    )
    assert set(report["specifications"][0]["built_interfaces"]) == {
        "osx:Kit",
        "osx:Kit/A",
        "osx:Kit/B",
    }, report


def mappings(fixture):
    spec = fixture.library(
        "owner-mappings",
        {
            "subspecs": [
                {
                    "name": "A",
                    "source_files": "A/**/*.h",
                    "header_dir": "Alpha",
                    "header_mappings_dir": "A",
                },
                {
                    "name": "B",
                    "source_files": "B/**/*.h",
                    "header_dir": "Beta",
                    "header_mappings_dir": "B",
                },
            ]
        },
        {
            "A/Nested/A.h": "#pragma once\nint alpha(void);\n",
            "B/Nested/B.h": "#pragma once\nint beta(void);\n",
        },
    )
    for mode, flags in [
        ("library", ["--use-libraries"]),
        ("modular", ["--use-libraries", "--use-modular-headers"]),
        ("framework", []),
    ]:
        fixture.lint(spec, flags, True, "owner-header-mappings-" + mode)


def cpp(fixture, header_only, mode):
    flags = {
        "library": ["--use-libraries"],
        "modular": ["--use-libraries", "--use-modular-headers"],
        "framework": [],
    }[mode]
    header = "Kit.hpp" if header_only else "Kit.h"
    files = {
        header: "#pragma once\nnamespace Fixture { template<class T> struct Box { T value; }; }\n"
    }
    if not header_only:
        files["Value.cpp"] = (
            '#include "Kit.h"\nint value() { return Fixture::Box<int>{7}.value; }\n'
        )
    label = ("header-only" if header_only else "compiled") + "-cpp-" + mode
    spec = fixture.library(label, {"source_files": list(files)}, files)
    fixture.lint(spec, flags, True, label)
    if mode == "library":
        (spec.parent / header).write_text(
            files[header] + "\n#error Broken_public_cpp_interface\n"
        )
        report = fixture.lint(spec, flags, False, label + "-rejects-broken-interface")
        assert "Broken_public_cpp_interface" in json.dumps(report), report


def main():
    fixture = Fixture()
    print("Lint interface fixtures:", fixture.root, flush=True)
    failures = []
    scenarios = [
        (mask, lambda mask=mask: ownership(fixture, mask))
        for mask in [
            "exclude_files",
            "private_header_files",
            "project_header_files",
            "public_header_files",
        ]
    ]
    scenarios.append(("owner-mappings", lambda: mappings(fixture)))
    for header_only in [False, True]:
        for mode in ["library", "modular", "framework"]:
            scenarios.append(
                (
                    str(header_only) + ":" + mode,
                    lambda header_only=header_only, mode=mode: cpp(
                        fixture, header_only, mode
                    ),
                )
            )
    for label, scenario in scenarios:
        try:
            scenario()
        except (AssertionError, RuntimeError, subprocess.SubprocessError) as error:
            failures.append({"scenario": label, "error": str(error)})
    report = {
        "status": "failed" if failures else "passed",
        "verified": fixture.verified,
        "failures": failures,
        "observations": fixture.observations,
        "fixture": str(fixture.root),
    }
    (results_directory() / "native-lint-interface.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    if failures:
        raise RuntimeError(json.dumps(failures))
    print("Passed", len(fixture.verified), "lint interface regressions", fixture.root)


if __name__ == "__main__":
    execute(main, "native-lint-interface.json")
