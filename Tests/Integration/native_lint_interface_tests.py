#!/usr/bin/env python3
"""Check real lint consumers for owned headers and C++ public interfaces."""

import json
import plistlib
import shutil
import subprocess

from scripts.support.bootstrap import environment
from scripts.support.local_build import (
    debug_binary,
    fixture_directory,
    results_directory,
)
from scripts.support.reporting import execute
from Tests.Fixtures.vendor_fixture import sdk


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

    def lint(self, spec, flags, passed, label, *, warnings=False):
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
        recorded_warnings = [warning for entry in validation["specifications"]
                             for warning in entry.get("warnings", [])]
        assert bool(recorded_warnings) == warnings, validation
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


def compiler_warnings(fixture):
    spec = fixture.library(
        "compiler-warnings",
        {"source_files": "Kit.c", "compiler_flags": "-Wno-error"},
        {"Kit.c": "#warning SwiftPods_lint_warning\nint kit(void) { return 7; }\n"},
    )
    report = fixture.lint(spec, ["--skip-tests"], False, "compiler-warning-rejected", warnings=True)
    assert any(error["code"] == "SP-LINT-WARNINGS" for error in report["errors"]), report
    fixture.lint(spec, ["--skip-tests", "--allow-warnings"], True,
                 "compiler-warning-explicitly-allowed", warnings=True)
    (spec.parent / "Kit.c").write_text("int kit(void) { return 7; }\n")
    fixture.lint(spec, ["--skip-tests"], True, "corrected-source-passes-without-allow-warnings")


def vendored_interfaces(fixture):
    producer = fixture.root / "vendor-producer"
    producer.mkdir()
    archive = sdk(producer, "Vendor", platforms=("macosx", "iphoneos", "iphonesimulator"))
    metadata = plistlib.loads((archive / "Info.plist").read_bytes())
    for framework in [False, True]:
        label = "vendored-" + ("framework" if framework else "xcframework")
        name = "Vendor.framework" if framework else "Vendor.xcframework"
        spec = fixture.library(label, {"source_files": [], "vendored_frameworks": name}, {})
        mac = next(entry for entry in metadata["AvailableLibraries"] if entry["SupportedPlatform"] == "macos")
        source = archive / mac["LibraryIdentifier"] / mac["LibraryPath"] if framework else archive
        destination = spec.parent / name
        shutil.copytree(source, destination, symlinks=True)
        if framework:
            header = destination / "Headers/Vendor.h"
            # Exercise public headers without a Clang module as well.
            (destination / "Modules/module.modulemap").unlink()
        else:
            header = destination / mac["LibraryIdentifier"] / mac["LibraryPath"] / "Headers/Vendor.h"
            for entry in metadata["AvailableLibraries"]:
                if entry["SupportedPlatform"] != "macos":
                    other = destination / entry["LibraryIdentifier"] / entry["LibraryPath"] / "Headers/Vendor.h"
                    other.write_text("#error Unselected_platform_header\n")
        good = header.read_text()
        header.write_text("#error Broken_vendored_public_interface\n" + good)
        report = fixture.lint(spec, ["--skip-tests"], False, label + "-rejects-broken-interface")
        assert any(error["code"] == "SP-LINT-CONSUMER" for error in report["errors"]), report
        assert "Broken_vendored_public_interface" in json.dumps(report), report
        header.write_text(good)
        fixture.lint(spec, ["--skip-tests"], True, label + "-accepts-corrected-interface")


def swift_vendor_interface(fixture):
    spec = fixture.library("swift-vendor", {"source_files": [], "vendored_frameworks": "SwiftVendor.framework"}, {})
    framework = spec.parent / "SwiftVendor.framework"
    modules = framework / "Modules/SwiftVendor.swiftmodule"
    modules.mkdir(parents=True)
    (framework / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleExecutable": "SwiftVendor", "CFBundleName": "SwiftVendor",
        "CFBundleIdentifier": "org.swiftpods.SwiftVendor", "CFBundlePackageType": "FMWK",
        "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
    }))
    producer = fixture.root / "swift-vendor-producer"
    producer.mkdir()
    source = producer / "Value.swift"
    source.write_text("public func vendorValue() -> Int32 { 7 }\n")
    libraries = []
    for arch in ["arm64", "x86_64"]:
        library = producer / (arch + ".a")
        module = modules / (arch + "-apple-macos.swiftmodule")
        result = subprocess.run([
            "xcrun", "swiftc", "-target", arch + "-apple-macos14.0", "-module-name", "SwiftVendor",
            "-parse-as-library", "-emit-library", "-static", "-emit-module", "-emit-module-path", str(module),
            str(source), "-o", str(library),
        ], text=True, capture_output=True, timeout=120)
        assert result.returncode == 0 and not result.stderr, result.stderr
        libraries.append(str(library))
    subprocess.run(["xcrun", "lipo", "-create", *libraries, "-output", str(framework / "SwiftVendor")], check=True)
    original = {path: path.read_bytes() for path in modules.glob("*.swiftmodule")}
    for path in original:
        path.write_bytes(b"invalid Swift module\n")
    report = fixture.lint(spec, ["--skip-tests"], False, "swift-vendor-rejects-invalid-module")
    assert any(error["code"] == "SP-LINT-CONSUMER" for error in report["errors"]), report
    for path, content in original.items():
        path.write_bytes(content)
    fixture.lint(spec, ["--skip-tests"], True, "swift-vendor-accepts-valid-module")


def cpp_vendor_interface(fixture):
    producer = fixture.root / "cpp-vendor-producer"
    producer.mkdir()
    archive = sdk(producer, "VendorCpp", platforms=("macosx",))
    spec = fixture.library("cpp-vendor", {"source_files": [], "vendored_frameworks": archive.name}, {})
    destination = spec.parent / archive.name
    shutil.copytree(archive, destination, symlinks=True)
    entry = plistlib.loads((destination / "Info.plist").read_bytes())["AvailableLibraries"][0]
    framework = destination / entry["LibraryIdentifier"] / entry["LibraryPath"]
    header = framework / "Headers/VendorCpp.h"
    header.write_text("#pragma once\nnamespace VendorCpp { inline int value() { return 42; } }\n")
    (framework / "Modules/module.modulemap").write_text(
        'framework module VendorCpp { requires cplusplus umbrella header "VendorCpp.h" export * }\n')
    fixture.lint(spec, ["--skip-tests"], True, "cpp-vendor-dot-h-with-module-language-requirement")
    header.write_text(header.read_text() + "\n#error Broken_cpp_vendor_interface\n")
    report = fixture.lint(spec, ["--skip-tests"], False, "cpp-vendor-rejects-broken-public-interface")
    assert "Broken_cpp_vendor_interface" in json.dumps(report), report


def multiple_vendor_modules(fixture):
    producer = fixture.root / "multi-module-vendor-producer"
    producer.mkdir()
    archive = sdk(producer, "VendorModules", library=True, platforms=("macosx",))
    spec = fixture.library("multi-module-vendor", {"source_files": [], "vendored_frameworks": archive.name}, {})
    destination = spec.parent / archive.name
    shutil.copytree(archive, destination, symlinks=True)
    entry = plistlib.loads((destination / "Info.plist").read_bytes())["AvailableLibraries"][0]
    headers = destination / entry["LibraryIdentifier"] / entry["HeadersPath"]
    (headers / "Good.h").write_text("#pragma once\n#define GOOD_VALUE 42\n")
    (headers / "Bad.h").write_text("#error Broken_second_vendor_module\n#define BAD_VALUE 42\n")
    (headers / "CXX.h").write_text("#pragma once\nnamespace CXX { inline int value() { return 42; } }\n")
    (headers / "module.modulemap").write_text(
        '/* module Fake { requires cplusplus } */\n'
        'module Good { requires !cplusplus header "Good.h" export * } '
        'module Bad { header "Bad.h" export * }\n'
        'module CXX { requires cplusplus header "CXX.h" export * }\n')
    report = fixture.lint(spec, ["--skip-tests"], False, "vendor-rejects-broken-second-module")
    assert "Broken_second_vendor_module" in json.dumps(report), report
    (headers / "Bad.h").write_text("#pragma once\n#define BAD_VALUE 42\n")
    fixture.lint(spec, ["--skip-tests"], True, "vendor-accepts-all-modules-with-independent-language-requirements")


def quoted_vendor_module(fixture):
    producer = fixture.root / "quoted-vendor-producer"
    producer.mkdir()
    archive = sdk(producer, "VendorQuoted", library=True, platforms=("macosx",))
    spec = fixture.library("quoted-vendor", {"source_files": [], "vendored_frameworks": archive.name}, {})
    destination = spec.parent / archive.name
    shutil.copytree(archive, destination, symlinks=True)
    entry = plistlib.loads((destination / "Info.plist").read_bytes())["AvailableLibraries"][0]
    headers = destination / entry["LibraryIdentifier"] / entry["HeadersPath"]
    modulemap = headers / "module.modulemap"
    modulemap.write_text('module "Quoted" { header "Missing.h" export * }\n')
    report = fixture.lint(spec, ["--skip-tests"], False, "quoted-vendor-rejects-broken-module")
    assert any(error["code"] == "SP-LINT-CONSUMER" for error in report["errors"]), report
    assert "Missing.h" in json.dumps(report), report
    modulemap.write_text('module "Quoted" { header "VendorQuoted.h" export * }\n')
    fixture.lint(spec, ["--skip-tests"], True, "quoted-vendor-accepts-corrected-module")


def cpp_standard(fixture):
    spec = fixture.library("cpp17-standard", {
        "source_files": ["Kit.hpp", "Kit.cpp"],
        "pod_target_xcconfig": {"KIT_CPP_STANDARD": "c++17", "CLANG_CXX_LANGUAGE_STANDARD": "$(KIT_CPP_STANDARD)"},
    }, {
        "Kit.hpp": "#pragma once\nnamespace Kit { inline constexpr int value = 42; }\n",
        "Kit.cpp": '#include "Kit.hpp"\nint kit_value(void) { return Kit::value; }\n',
    })
    for mode, flags in [("library", ["--use-libraries"]), ("framework", [])]:
        fixture.lint(spec, ["--skip-tests", *flags], True, "cpp17-public-interface-inherits-declared-standard-" + mode)


def source_module_maps(fixture):
    spec = fixture.library("source-module-maps", {
        "source_files": ["Kit.h", "Kit.c"], "module_map": "Custom.modulemap",
    }, {
        "Kit.h": "#pragma once\nint value(void);\n",
        "Kit.c": "int value(void) { return 7; }\n",
        "Custom.modulemap": 'module Kit { header "Kit.h" export * }\n'
                            'module Extra { header "Missing.h" export * }\n',
    })
    flags = ["--skip-tests", "--use-libraries", "--use-modular-headers"]
    report = fixture.lint(spec, flags, False, "source-map-rejects-broken-extra-module")
    assert any(error["code"] == "SP-LINT-CONSUMER" for error in report["errors"]), report
    assert "Missing.h" in json.dumps(report), report
    (spec.parent / "Missing.h").write_text("#pragma once\n#define EXTRA_VALUE 42\n")
    fixture.lint(spec, flags, True, "source-map-accepts-repaired-extra-module")
    (spec.parent / "Custom.modulemap").write_text(
        'module Kit { requires !objc header "Kit.h" export * }\n')
    fixture.lint(spec, flags, True, "source-map-accepts-c-only-primary-module")


def c_only_vendor_modules(fixture):
    producer = fixture.root / "c-only-vendor-producer"
    producer.mkdir()
    archive = sdk(producer, "VendorC", library=True, platforms=("macosx",))
    spec = fixture.library("c-only-vendor", {"source_files": [], "vendored_frameworks": archive.name}, {})
    destination = spec.parent / archive.name
    shutil.copytree(archive, destination, symlinks=True)
    entry = plistlib.loads((destination / "Info.plist").read_bytes())["AvailableLibraries"][0]
    headers = destination / entry["LibraryIdentifier"] / entry["HeadersPath"]
    (headers / "CPP.h").write_text("#pragma once\nnamespace CPP { inline int value() { return 42; } }\n")
    (headers / "module.modulemap").write_text(
        'module COnly { requires !objc, !cplusplus header "VendorC.h" export * }\n'
        'module CPPOnly { requires !objc, cplusplus header "CPP.h" export * }\n')
    fixture.lint(spec, ["--skip-tests"], True, "vendor-accepts-c-and-cpp-without-objc")
    (headers / "CPP.h").write_text("#error Broken_cpp_only_module\n")
    report = fixture.lint(spec, ["--skip-tests"], False, "vendor-rejects-broken-cpp-only-module")
    assert "Broken_cpp_only_module" in json.dumps(report), report


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
    scenarios.append(("compiler-warnings", lambda: compiler_warnings(fixture)))
    scenarios.append(("vendored-interfaces", lambda: vendored_interfaces(fixture)))
    scenarios.append(("swift-vendor", lambda: swift_vendor_interface(fixture)))
    scenarios.append(("cpp-vendor", lambda: cpp_vendor_interface(fixture)))
    scenarios.append(("multiple-vendor-modules", lambda: multiple_vendor_modules(fixture)))
    scenarios.append(("quoted-vendor-module", lambda: quoted_vendor_module(fixture)))
    scenarios.append(("cpp-standard", lambda: cpp_standard(fixture)))
    scenarios.append(("source-module-maps", lambda: source_module_maps(fixture)))
    scenarios.append(("c-only-vendor-modules", lambda: c_only_vendor_modules(fixture)))
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
