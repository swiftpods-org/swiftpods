#!/usr/bin/env python3
"""Check every configuration and compare SDK conditions with real Xcode settings."""

import json
import subprocess

from input_contract_regressions import diagnostic, save_project
from native_lifecycle_tests import LifecycleFixture
from native_linker_manifest_tests import application
from native_xcconfig_tests import create
from reporting import ROOT, execute
from vendor_fixture import run
from workspace_resource_regressions import read_project


def declaration(work, kind, hooks=False):
    if kind == "yaml":
        (work / "Podfile").unlink(missing_ok=True)
        (work / "CocoaPods.podfile.yaml").write_text(
            json.dumps(
                {
                    "target_definitions": [
                        {
                            "name": "Demo",
                            "user_project_path": "../Apps/External.xcodeproj",
                            "dependencies": [{"Kit": [{"path": "./Kit"}]}],
                        }
                    ]
                }
            )
        )
        return
    text = "project '../Apps/External.xcodeproj'\ntarget 'Demo' do\n pod 'Kit', :path => './Kit'\nend\n"
    if hooks:
        text += "pre_install { |_| File.write('hook-ran', 'yes') }\n"
        text += """post_install do |installer|
  target = installer.aggregate_targets.first.user_targets.first
  values = %w[SDKROOT INFERENCE_DIRECT INFERENCE_INCLUDED INFERENCE_PROJECT].to_h { |key| [key, target.resolved_build_setting(key, true)] }
  File.write('inferred-settings.json', JSON.generate(values))
end
"""
    (work / "Podfile").write_text(text)


def configure(project, change):
    graph = read_project(project)
    for obj in graph["objects"].values():
        if obj.get("isa") == "XCBuildConfiguration" and obj.get(
            "buildSettings", {}
        ).get("PRODUCT_NAME"):
            change(obj["name"], obj["buildSettings"])
    save_project(project, graph)


def invalid(fixture, kind, scenario):
    work, project = create(fixture.root / (kind + "-" + scenario))
    declaration(work, kind, hooks=True)

    def change(name, values):
        if scenario == "ambiguous-auto":
            values.update(SDKROOT="auto", IPHONEOS_DEPLOYMENT_TARGET="15.0")
        elif scenario == "sdk-cycle":
            values.update(
                {
                    "SDKROOT": "macosx",
                    "SDKROOT[sdk=macosx*]": "iphoneos",
                    "SDKROOT[sdk=iphoneos*]": "macosx",
                }
            )
        elif name == "Release":
            if scenario == "unknown-sdk":
                values["SDKROOT"] = "custom-sdk"
            if scenario == "missing-minimum":
                values["MACOSX_DEPLOYMENT_TARGET"] = ""
            if scenario == "unresolved-minimum":
                values["MACOSX_DEPLOYMENT_TARGET"] = "$(MISSING_MINIMUM)"
            if scenario == "other-sdk-without-minimum":
                values.update(SDKROOT="iphoneos", IPHONEOS_DEPLOYMENT_TARGET="")

    configure(project, change)
    before = (project / "project.pbxproj").read_bytes()
    report = fixture.cli(work, "install", succeeds=False)
    diagnostic(
        report,
        "SP-XCCONFIG-CYCLE" if scenario == "sdk-cycle" else "SP-PLATFORM-MISSING",
    )
    assert report["project_state"] == "failed_no_managed_changes", report
    assert not (work / "hook-ran").exists()
    assert (
        not (work / "Podfile.lock").exists()
        and not (work / "Pods/Pods.xcodeproj").exists()
    )
    assert (project / "project.pbxproj").read_bytes() == before
    fixture.verified.append(kind + "-" + scenario + "-fails-before-hooks-and-writes")


def oracle(fixture, project, configuration, label):
    result = subprocess.run(
        [
            "xcodebuild",
            "-project",
            str(project),
            "-target",
            "Demo",
            "-configuration",
            configuration,
            "-showBuildSettings",
            "-json",
        ],
        capture_output=True,
        text=True,
        timeout=90,
        env=fixture.env,
    )
    (fixture.root / (label + "-" + configuration + "-xcode-settings.log")).write_text(
        result.stdout + result.stderr
    )
    assert result.returncode == 0 and "warning:" not in result.stderr, result.stderr
    values = next(
        row["buildSettings"]
        for row in json.loads(result.stdout)
        if row["target"] == "Demo"
    )
    return {
        key: values.get(key)
        for key in [
            "SDKROOT",
            "SDK_NAME",
            "INFERENCE_DIRECT",
            "INFERENCE_INCLUDED",
            "INFERENCE_PROJECT",
        ]
    }


def valid(fixture, kind, source, observations):
    label = kind + "-" + source
    work, project = create(fixture.root / label)
    declaration(work, kind, hooks=True)
    sdk = subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
    ).strip()
    base = project.parent / "Configs/Base.xcconfig"
    base.write_text(
        base.read_text()
        + "\nINFERENCE_INCLUDED[sdk=macosx*] = selected\nINFERENCE_INCLUDED[sdk=iphoneos*] = wrong\n"
    )
    if source == "xcconfig-sdk-path":
        base.write_text(
            base.read_text().replace("SDKROOT = macosx", "SDKROOT = " + sdk)
        )
    if source == "project-sdk":
        graph = read_project(project)
        objects = graph["objects"]
        configurations = objects[
            objects[graph["rootObject"]]["buildConfigurationList"]
        ]["buildConfigurations"]
        for cid in configurations:
            objects[cid]["buildSettings"].update(
                {
                    "SDKROOT": "iphoneos",
                    "INFERENCE_PROJECT[sdk=macosx*]": "selected",
                    "INFERENCE_PROJECT[sdk=iphoneos*]": "wrong",
                }
            )
        save_project(project, graph)

    def change(name, values):
        if source == "direct-sdk-path":
            values["SDKROOT"] = sdk
        if source == "project-sdk":
            values["SDKROOT"] = "macosx"
        if source == "conditional-sdk":
            values.update(
                {"SDKROOT": "iphoneos", "SDKROOT[config=" + name + "]": "macosx"}
            )
        values.update(
            {
                "INFERENCE_DIRECT[sdk=macosx*]": "selected",
                "INFERENCE_DIRECT[sdk=iphoneos*]": "wrong",
            }
        )

    configure(project, change)
    xcode = {
        name: oracle(fixture, project, name, label) for name in ["Debug", "Release"]
    }
    fixture.cli(work, "install")
    report = json.loads((work / ".swiftpods/installation.json").read_text())
    assert report["targets"][0]["platform"] == {
        "name": "osx",
        "deployment_target": "13.0",
    }, report
    if kind == "ruby":
        values = json.loads((work / "inferred-settings.json").read_text())
        for name, expected in xcode.items():
            keys = ["INFERENCE_DIRECT", "INFERENCE_INCLUDED"] + (
                ["INFERENCE_PROJECT"] if source == "project-sdk" else []
            )
            for key in keys:
                assert values[key][name] == expected[key] == "selected", (
                    label,
                    name,
                    values,
                    xcode,
                )
    before = (project / "project.pbxproj").read_bytes()
    locked = (work / "Podfile.lock").read_bytes()
    fixture.cli(work, "install", "--deployment", "--offline")
    assert (project / "project.pbxproj").read_bytes() == before
    assert (work / "Podfile.lock").read_bytes() == locked
    build = "platform-inference-build-" + label
    fixture.build(work, "Demo", build)
    run(
        [application(fixture, build)],
        work,
        fixture.root / (build + "-run.log"),
        env=fixture.env,
    )
    observations[label] = xcode
    fixture.verified += [
        label + "-matches-xcode-and-infers-platform",
        label + "-builds-runs-and-reinstalls-idempotently",
    ]


def main():
    fixture = LifecycleFixture()
    failures, observations = [], {}
    print("Platform inference fixtures:", fixture.root, flush=True)
    scenarios = [
        (kind + ":" + case, lambda kind=kind, case=case: invalid(fixture, kind, case))
        for kind in ["ruby", "yaml"]
        for case in [
            "unknown-sdk",
            "missing-minimum",
            "unresolved-minimum",
            "other-sdk-without-minimum",
            "ambiguous-auto",
            "sdk-cycle",
        ]
    ]
    scenarios += [
        (
            kind + ":" + source,
            lambda kind=kind, source=source: valid(fixture, kind, source, observations),
        )
        for kind, source in [
            ("ruby", "direct-sdk-path"),
            ("ruby", "xcconfig-sdk-path"),
            ("ruby", "conditional-sdk"),
            ("ruby", "project-sdk"),
            ("yaml", "direct-sdk-path"),
        ]
    ]
    for label, scenario in scenarios:
        try:
            scenario()
        except (AssertionError, RuntimeError, subprocess.SubprocessError) as error:
            failures.append({"scenario": label, "error": str(error)})
    (ROOT / "test-results/native-platform-inference.json").write_text(
        json.dumps(
            {
                "status": "failed" if failures else "passed",
                "verified": fixture.verified,
                "failures": failures,
                "oracle": observations,
                "fixture": str(fixture.root),
            },
            indent=2,
        )
        + "\n"
    )
    if failures:
        raise RuntimeError(json.dumps(failures))
    print(
        "Passed", len(fixture.verified), "platform inference regressions", fixture.root
    )


if __name__ == "__main__":
    execute(main, "native-platform-inference.json")
