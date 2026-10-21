#!/usr/bin/env python3
"""Build/run native test_spec/app_spec products and real XCTest cases."""

import json
import platform
import subprocess

from bootstrap import environment
from local_build import debug_binary, fixture_directory, results_directory
from reporting import execute
from supplementary_fixture import create, declarative, podfile
from vendor_fixture import fixture_build_arguments, run


def install(work, env, *args, binary=None):
    result = subprocess.run(
        [str(binary or debug_binary()), "install", *args, "--json"],
        cwd=work,
        env=env,
        capture_output=True,
        text=True,
        timeout=90,
    )
    if result.returncode:
        raise RuntimeError(result.stderr + result.stdout)
    return json.loads(result.stdout)


def build(work, parent, scheme, action="build", configuration="Debug"):
    prefix = scheme + "-" + configuration + "-" + action
    log = parent / (
        prefix + "-" + str(len(list(parent.glob(prefix + "-*.log")))) + ".log"
    )
    return run(
        [
            "xcodebuild",
            "-project",
            "Pods/Pods.xcodeproj",
            "-scheme",
            scheme,
            "-configuration",
            configuration,
            "-destination",
            "platform=macOS,arch=" + platform.machine(),
            *fixture_build_arguments(parent),
            "CODE_SIGNING_ALLOWED=NO",
            action,
        ],
        work,
        log,
    )


def exercise(parent, linkage):
    parent.mkdir()
    work = parent / "project"
    module = create(work, linkage)
    env = environment()
    env["GEM_HOME"] = str(parent / "empty-gems")
    env["GEM_PATH"] = env["GEM_HOME"]
    env["SWIFTPODS_CACHE_ROOT"] = str(parent / "cache")
    podfile(work, linkage, selections=False)
    initial = install(work, env)
    assert {
        spec["name"]
        for event in initial["events"]
        if event["kind"] == "installation"
        for spec in event["specs"]
    } == {"SpecKit"}
    assert (
        not (work / "Pods/TestHelper").exists()
        and not (work / "Pods/AppHelper").exists()
    )
    podfile(work, linkage)
    install(work, env)
    lock = work.joinpath("Podfile.lock").read_bytes()
    install(work, env, "--deployment", "--offline")
    assert lock == work.joinpath("Podfile.lock").read_bytes()
    graph = json.loads(
        subprocess.check_output(
            [
                "plutil",
                "-convert",
                "json",
                "-o",
                "-",
                str(work / "Demo.xcodeproj/project.pbxproj"),
            ]
        )
    )
    linked = [
        item.get("path")
        for item in graph["objects"].values()
        if item["isa"] == "PBXFileReference"
    ]
    assert not any(
        name and ("TestHelper" in name or "AppHelper" in name or ".xctest" in name)
        for name in linked
    ), linked
    pod_graph = json.loads(
        subprocess.check_output(
            [
                "plutil",
                "-convert",
                "json",
                "-o",
                "-",
                str(work / "Pods/Pods.xcodeproj/project.pbxproj"),
            ]
        )
    )
    targets = {
        item["name"]: item
        for item in pod_graph["objects"].values()
        if item["isa"] == "PBXNativeTarget"
    }
    assert {
        "SpecKit",
        "SpecKit-Unit-Tests",
        "SpecKit-Example",
        "TestHelper",
        "AppHelper",
        "SpecKit-SpecTestResources",
        "SpecKit-SpecAppResources",
    } == set(targets), targets.keys()
    assert (
        targets["SpecKit-Unit-Tests"]["productType"]
        == "com.apple.product-type.bundle.unit-test"
    )
    assert (
        targets["SpecKit-Example"]["productType"]
        == "com.apple.product-type.application"
    )
    text = build(work, parent, "SpecKit-Unit-Tests", "test")
    assert (
        "** TEST SUCCEEDED **" in text and "testScopedDependenciesAndResources" in text
    )
    build(work, parent, "SpecKit-Example")
    app = (
        parent
        / "DerivedData/Build/Products/Debug/SpecKit-Example.app/Contents/MacOS/SpecKit-Example"
    )
    assert (
        subprocess.check_output([str(app)], text=True).strip()
        == "app-value=16 resources=ok"
    )
    run(
        [
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
            parent / "DemoDerived",
            "CODE_SIGNING_ALLOWED=NO",
            "build",
        ],
        work,
        parent / "demo-build.log",
    )
    app = parent / "DemoDerived/Build/Products/Debug/Demo.app/Contents/MacOS/Demo"
    assert subprocess.check_output([str(app)], text=True).strip() == "library-value=7"
    # Every linkage mode must execute standalone, generated and named hosts.
    executions = []
    for configuration in ["Debug", "Release"]:
        spec = module / "SpecKit.podspec"
        original = spec.read_text()
        assert "testScopedDependenciesAndResources" in build(
            work, parent, "SpecKit-Unit-Tests", "test", configuration
        )
        executions.append({"configuration": configuration, "host": "standalone"})
        spec.write_text(
            original.replace(
                "t.osx.deployment_target = '14.0'",
                "t.osx.deployment_target = '14.0'\n    t.requires_app_host = true",
            )
        )
        install(work, env)
        text = build(work, parent, "SpecKit-Unit-Tests", "test", configuration)
        assert (
            "** TEST SUCCEEDED **" in text
            and "testScopedDependenciesAndResources" in text
        )
        executions.append({"configuration": configuration, "host": "generated"})
        # A named host is resolved through its explicit app-spec dependency.
        host_dir = module / "Host"
        host_dir.mkdir(exist_ok=True)
        host_dir.joinpath("main.m").write_text(
            "#import <AppKit/AppKit.h>\nint main(int argc, const char *argv[]) { return NSApplicationMain(argc, argv); }\n"
        )
        hosted = original.replace(
            "t.osx.deployment_target = '14.0'",
            "t.osx.deployment_target = '14.0'\n    t.requires_app_host = true\n    t.app_host_name = 'SpecKit/Host'\n    t.dependency 'SpecKit/Host'",
        )
        hosted = (
            hosted.rsplit("end", 1)[0]
            + "  s.app_spec 'Host' do |a|\n    a.source_files = 'Host/*.m'\n    a.frameworks = 'AppKit'\n    a.info_plist = { 'NSPrincipalClass' => 'NSApplication', 'LSUIElement' => true }\n  end\nend\n"
        )
        spec.write_text(hosted)
        install(work, env)
        text = build(work, parent, "SpecKit-Unit-Tests", "test", configuration)
        assert (
            "** TEST SUCCEEDED **" in text
            and "testScopedDependenciesAndResources" in text
        )
        executions.append({"configuration": configuration, "host": "named"})
        spec.write_text(original)
        install(work, env)
    if linkage == "static":
        podfile(work, linkage, selections=False)
        install(work, env)
        schemes = work / "Pods/Pods.xcodeproj/xcshareddata/xcschemes"
        assert not (schemes / "SpecKit-Unit-Tests.xcscheme").exists()
        assert not (schemes / "SpecKit-Example.xcscheme").exists()
        assert not (schemes / "SpecKit-Host.xcscheme").exists()
        podfile_text = work.joinpath("Podfile").read_text()
        spec.write_text(original.replace("t.test_type = :ui", "t.test_type = :unknown"))
        work.joinpath("Podfile").write_text(
            podfile_text.replace(
                ":path => './Modules/SpecKit'",
                ":path => './Modules/SpecKit', :testspecs => ['UnselectedUI']",
            )
        )
        denied = subprocess.run(
            [str(debug_binary()), "install", "--json"],
            cwd=work,
            env=env,
            capture_output=True,
            text=True,
            timeout=90,
        )
        assert denied.returncode != 0
        denied = json.loads(denied.stdout)
        assert any(event.get("code") == "SP-TEST-TYPE" for event in denied["events"])
        assert denied["project_state"] == "failed_no_managed_changes"
        spec.write_text(original)
        work.joinpath("Podfile").write_text(podfile_text)
        declarative(work)
        hardened_env = dict(env, SWIFTPODS_RUBY="/swiftpods-fixture-no-ruby")
        install(work, hardened_env, "--hardened", "--offline")
        assert "** TEST SUCCEEDED **" in build(
            work, parent, "SpecKit-Unit-Tests", "test"
        )
    return {
        "linkage": linkage or "static-library",
        "status": "passed",
        "fixture": str(parent),
        "xctest": "passed",
        "app_value": 16,
        "host_executions": executions,
    }


def main():
    base = fixture_directory("native-supplementary-")
    print("Supplementary fixtures:", base, flush=True)
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
            "explicit test/app selection and default exclusion",
            "real macOS XCTest execution",
            "standalone/generated/named unit tests execute in Debug/Release for all three linkage modes",
            "app spec build and run",
            "scoped source/resource/dependency isolation",
            "resource bundles",
            "generated schemes and Info.plist",
            "scheme removal",
            "test scheme environment",
            "three library linkage modes",
            "offline deployment reinstall",
            "hardened JSON selection and XCTest without Ruby",
            "unknown test type rejection before managed changes",
        ],
        "unverified": [
            "UI runners",
            "other Apple platforms",
            "signing",
            "complete reference parity",
        ],
    }
    results_directory().joinpath("native-supplementary.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    execute(main, "native-supplementary.json")
