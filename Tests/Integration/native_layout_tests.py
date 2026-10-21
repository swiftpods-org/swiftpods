#!/usr/bin/env python3
"""Execute test/app schemes and public hooks with isolated pod projects."""

import argparse
import json
import subprocess
from pathlib import Path

from scripts.support.bootstrap import environment
from scripts.support.local_build import fixture_directory, results_directory
from scripts.support.reporting import execute, option_value
from Tests.Fixtures.layout_fixture import contract, enable
from Tests.Fixtures.supplementary_fixture import create
from Tests.Fixtures.ui_test_fixture import build as build_ui
from Tests.Fixtures.ui_test_fixture import create as create_ui
from Tests.Fixtures.ui_test_fixture import declarative, simulator
from Tests.Integration.native_supplementary_tests import build, install


def snapshot(work):
    return {
        path.relative_to(work).as_posix(): path.read_bytes()
        for path in work.glob("Pods/**/*.xcodeproj/project.pbxproj")
    } | {
        path.relative_to(work).as_posix(): path.read_bytes()
        for path in work.glob("Pods/**/*.xcscheme")
    }


def mac(parent, linkage, binary, bundle):
    parent.mkdir()
    work = parent / "project"
    module = create(work, linkage)
    enable(work)
    env = environment(bundle)
    env.update(
        GEM_HOME=str(parent / "empty-gems"),
        GEM_PATH=str(parent / "empty-gems"),
        SWIFTPODS_CACHE_ROOT=str(parent / "cache"),
    )
    install(work, env, binary=binary)
    previous = snapshot(work)
    install(work, env, "--offline", "--deployment", binary=binary)
    assert snapshot(work) == previous
    contract(work, ["SpecKit", "TestHelper", "AppHelper"])
    assert "testScopedDependenciesAndResources" in build(
        work, parent, "SpecKit-Unit-Tests", "test"
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
    if linkage == "static":
        spec = module / "SpecKit.podspec"
        original_spec = spec.read_text()
        hosted = original_spec.replace(
            "t.osx.deployment_target = '14.0'",
            "t.osx.deployment_target = '14.0'\n    t.requires_app_host = true",
        )
        spec.write_text(hosted)
        install(work, env, "--offline", binary=binary)
        assert "testScopedDependenciesAndResources" in build(
            work, parent, "SpecKit-Unit-Tests", "test"
        )
        host = module / "Host"
        host.mkdir()
        host.joinpath("main.m").write_text(
            "#import <AppKit/AppKit.h>\nint main(int argc, const char *argv[]) { return NSApplicationMain(argc, argv); }\n"
        )
        named = hosted.replace(
            "t.requires_app_host = true",
            "t.requires_app_host = true\n    t.app_host_name = 'SpecKit/Host'\n    t.dependency 'SpecKit/Host'",
        )
        named = (
            named.rsplit("end", 1)[0]
            + "  s.app_spec 'Host' do |a|\n    a.source_files = 'Host/*.m'\n    a.frameworks = 'AppKit'\n    a.info_plist = { 'NSPrincipalClass' => 'NSApplication', 'LSUIElement' => true }\n  end\nend\n"
        )
        spec.write_text(named)
        install(work, env, "--offline", binary=binary)
        contract(work, ["SpecKit", "TestHelper", "AppHelper"])
        assert "testScopedDependenciesAndResources" in build(
            work, parent, "SpecKit-Unit-Tests", "test"
        )
        spec.write_text(original_spec)
        install(work, env, "--offline", binary=binary)
    # Actual plugin callbacks receive the isolated project models, including root changes.
    plugin = work / "layout_plugin.rb"
    plugin.write_text("""require 'cocoapods/installer/base_install_hooks_context'
Pod::HooksManager.register('layout_plugin', :post_install) do |context|
  raise 'Missing subprojects' unless context.pod_target_subprojects.size == 3
  raise 'Missing all-project view' unless context.generated_projects.size == 4
  context.pod_target_subprojects.each do |project|
    project.root_object.attributes['PluginLayout'] = project.path.basename('.xcodeproj').to_s
    project.save
  end
  File.write('layout-plugin-result', 'ok')
end
""")
    podfile = work / "Podfile"
    original = podfile.read_text()
    podfile.write_text(
        "$LOAD_PATH.unshift(Dir.pwd)\nplugin 'layout_plugin'\n" + original
    )
    install(work, env, "--offline", binary=binary)
    assert work.joinpath("layout-plugin-result").read_text() == "ok"
    projects = contract(work, ["SpecKit", "TestHelper", "AppHelper"])
    for name in ["SpecKit", "TestHelper", "AppHelper"]:
        graph = projects[name]
        assert (
            graph["objects"][graph["rootObject"]]["attributes"]["PluginLayout"] == name
        )
    # Remove selected specs and their helper projects. Edited stale files survive.
    edited = work / "Pods/AppHelper.xcodeproj/project.pbxproj"
    edited.write_text(edited.read_text() + "\n// user note\n")
    podfile.write_text(
        original.replace(", :testspecs => ['Tests'], :appspecs => ['Example']", "")
    )
    install(work, env, "--offline", binary=binary)
    assert not work.joinpath("Pods/TestHelper.xcodeproj").exists()
    assert edited.read_text().endswith("// user note\n")
    assert not work.joinpath(
        "Pods/Pods.xcodeproj/xcshareddata/xcschemes/SpecKit-Unit-Tests.xcscheme"
    ).exists()
    assert not work.joinpath(
        "Pods/Pods.xcodeproj/xcshareddata/xcschemes/SpecKit-Example.xcscheme"
    ).exists()
    workspace = work.joinpath("Demo.xcworkspace/contents.xcworkspacedata").read_text()
    assert (
        "TestHelper.xcodeproj" not in workspace
        and "AppHelper.xcodeproj" not in workspace
    )
    assert not work.joinpath("Pods/SpecKit/SpecKit.xcodeproj").exists(), (
        "Generated project was placed inside pod sources"
    )
    return {
        "linkage": linkage or "static-library",
        "status": "passed",
        "fixture": str(parent),
    }


def ios(parent, binary, bundle):
    parent.mkdir()
    work = parent / "project"
    data = create_ui(work)
    enable(work)
    env = environment(bundle)
    env.update(
        GEM_HOME=str(parent / "empty-gems"),
        GEM_PATH=str(parent / "empty-gems"),
        SWIFTPODS_CACHE_ROOT=str(parent / "cache"),
    )
    install(work, env, binary=binary)
    contract(work, ["UIWidget"])
    with simulator(parent) as device:
        for scheme, test in [
            ("UIWidget-UI-Interface", "testButtonChangesLibraryValue"),
            ("UIWidget-UI-Generated", "testGeneratedHostLaunches"),
            ("UIWidget-Unit-Hosted", "testLibraryAndOwnResources"),
        ]:
            assert test in build_ui(work, parent, scheme, device, "test")
        # JSON installation generates the same split layout without Ruby or hooks.
        declarative(work, data)
        manifest = work / "Podfile.json"
        value = json.loads(manifest.read_text())
        value["options"] = {"generate_multiple_pod_projects": True}
        manifest.write_text(json.dumps(value))
        # The hook-only compiler assertion is deliberately omitted in the JSON fixture.
        source = work / "Modules/UIWidget/Sources/UIWidget.m"
        source.write_text(source.read_text().split("#endif\n", 1)[1])
        install(
            work,
            dict(env, SWIFTPODS_RUBY="/swiftpods-fixture-no-ruby"),
            "--hardened",
            "--offline",
            binary=binary,
        )
        contract(work, ["UIWidget"], hooks=False)
        assert "testButtonChangesLibraryValue" in build_ui(
            work, parent, "UIWidget-UI-Interface", device, "test"
        )
    return {"platform": "ios-simulator", "status": "passed", "fixture": str(parent)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path)
    args = parser.parse_args()
    bundle = args.bundle.resolve() if args.bundle else None
    binary = bundle / "bin/swiftpods" if bundle else None
    parent = fixture_directory("native-layout-")
    print("Layout fixtures:", parent, flush=True)
    scenarios = [
        mac(parent / label, linkage, binary, bundle)
        for label, linkage in [
            ("static", "static"),
            ("dynamic", "dynamic"),
            ("library", None),
        ]
    ]
    scenarios.append(ios(parent / "ios", binary, bundle))
    report = {
        "status": "passed",
        "engine": "swift",
        "fixture": str(parent),
        "scenarios": scenarios,
        "verified": [
            "isolated reachable project graphs",
            "cross-project library/test/app/resource dependencies",
            "main-project shared schemes resolve actual child containers",
            "real macOS XCTest and app execution in three linkage modes",
            "macOS generated/named unit test hosts",
            "iOS named/generated UI host interaction and hosted unit tests",
            "live child project and configuration identity",
            "immediate saves and independent child root settings compile",
            "public plugin subproject/all-project contexts",
            "cross-project hook dependencies are idempotent",
            "preserved original Xcode project in Git pod sources",
            "byte-stable offline deployment reinstall",
            "stale child/scheme/workspace cleanup preserves changed project files",
            "hardened split-project UI execution without Ruby",
        ],
        "unverified": [
            "same-platform target variants",
            "complete public/private plugin APIs",
            "conditional SDK/consumer resources",
            "physical devices and distribution signing",
            "all platform/linkage combinations",
        ],
    }
    if bundle:
        report.update(
            bundle=str(bundle),
            bundle_digest=json.loads(bundle.joinpath("compatibility.json").read_text())[
                "bundle_digest"
            ],
        )
    name = "native-packaged-layout.json" if bundle else "native-layout.json"
    results_directory().joinpath(name).write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    execute(
        main,
        "native-packaged-layout.json"
        if option_value("--bundle") is not None
        else "native-layout.json",
    )
