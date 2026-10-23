#!/usr/bin/env python3
"""Build independent Swift consumers together, with shared module-name families."""

import json
import platform
import subprocess
from pathlib import Path
from xml.etree import ElementTree as ET

from scripts.support.local_build import results_directory
from scripts.support.reporting import execute
from Tests.Fixtures.vendor_fixture import fixture_build_arguments, fixture_derived_data, run
from Tests.Integration.native_lifecycle_tests import LifecycleFixture
from Tests.Integration.native_xcconfig_tests import create
from Tests.Regression.header_ownership_regressions import write_project
from Tests.Regression.workspace_resource_regressions import add_consumer, read_project


def create_case(fixture, label, alias, mode=None, separate_configurations=False):
    work, selected = create(fixture.root / label)
    for pod, module, value in [("Kit", "Feature", 11), ("Other", alias, 31)]:
        directory = work / pod
        directory.mkdir(exist_ok=True)
        (directory / (pod + ".podspec.json")).write_text(json.dumps({
            "name": pod, "version": "1.0", "module_name": module,
            "source_files": "*.swift", "platforms": {"osx": "13.0"},
            "frameworks": ["AppIntents"],
        }))
        (directory / (pod + ".swift")).write_text(
            'import AppIntents\n'
            'struct PodScopeIntent: AppIntent {\n'
            ' static var title: LocalizedStringResource = "Pod scope"\n'
            ' func perform() async throws -> some IntentResult { .result() }\n}\n'
            "public func moduleValue() -> Int { " + str(value) + " }\n"
        )
    source = selected.parent / "Sources/main.swift"
    source.write_text(
        'import AppIntents\n'
        'struct ScopeIntent: AppIntent {\n'
        ' static var title: LocalizedStringResource = "Scope"\n'
        ' func perform() async throws -> some IntentResult { .result() }\n}\n'
        '#if FIRST\nimport Feature\n#else\nimport ' + alias + '\n#endif\n'
        'print(moduleValue())\n'
    )
    graph = read_project(selected)
    for obj in graph["objects"].values():
        if obj.get("isa") == "PBXFileReference" and obj.get("path") == "Sources/main.mm":
            obj.update(path="Sources/main.swift", lastKnownFileType="sourcecode.swift")
    write_project(selected, graph)
    if not separate_configurations:
        add_consumer(selected)
    graph = read_project(selected)
    targets = {key: obj for key, obj in graph["objects"].items() if obj.get("isa") == "PBXNativeTarget"}
    for target in targets.values():
        configs = graph["objects"][target["buildConfigurationList"]]["buildConfigurations"]
        for key in configs:
            config = graph["objects"][key]
            first = config["name"] == "Debug" if separate_configurations else target["name"] == "Demo"
            config["buildSettings"].update(
                SWIFT_VERSION="5.0", SWIFT_ACTIVE_COMPILATION_CONDITIONS="FIRST" if first else "SECOND"
            )
    write_project(selected, graph)
    declarations = "platform :osx, '13.0'\nproject '../Apps/External.xcodeproj'\n"
    if separate_configurations:
        declarations += (
            "target 'Demo' do\n"
            " pod 'Kit', :path => './Kit', :configurations => ['Debug']\n"
            " pod 'Other', :path => './Other', :configurations => ['Release']\nend\n"
        )
    else:
        declarations += "target('Demo') { pod 'Kit', :path => './Kit' }\ntarget 'Other' do\n"
        if mode:
            declarations += " use_frameworks! :linkage => :" + mode + "\n"
        declarations += " pod 'Other', :path => './Other'\nend\n"
    (work / "Podfile").write_text(declarations)
    scheme = ET.Element("Scheme", LastUpgradeVersion="1600", version="1.3")
    action = ET.SubElement(scheme, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES")
    entries = ET.SubElement(action, "BuildActionEntries")
    for key, target in targets.items():
        entry = ET.SubElement(entries, "BuildActionEntry", **{
            "buildFor" + value: "YES" for value in ["Testing", "Running", "Profiling", "Archiving", "Analyzing"]
        })
        ET.SubElement(entry, "BuildableReference", BuildableIdentifier="primary", BlueprintIdentifier=key,
                      BuildableName=target["name"] + ".app", BlueprintName=target["name"],
                      ReferencedContainer="container:External.xcodeproj")
    destination = selected / "xcshareddata/xcschemes/Combined.xcscheme"
    destination.parent.mkdir(parents=True)
    destination.write_bytes(ET.tostring(scheme))
    return work, selected


def build_case(fixture, label, alias, mode=None, separate_configurations=False):
    work, selected = create_case(fixture, label, alias, mode, separate_configurations)
    if alias == "Feature":
        before = (selected / "project.pbxproj").read_bytes()
        report = fixture.cli(work, "install", succeeds=False)
        assert any(event.get("code") == "SP-XCODE-MODULE-CONFLICT" for event in report["events"]), report
        assert (selected / "project.pbxproj").read_bytes() == before
        assert not (work / "Podfile.lock").exists()
        fixture.verified.append(label + "_ambiguous_swift_producers_rejected")
        return []
    fixture.cli(work, "install")
    projects = [selected / "project.pbxproj", work / "Pods/Pods.xcodeproj/project.pbxproj"]
    before = {path: path.read_bytes() for path in projects + [work / "Podfile.lock"]}
    fixture.cli(work, "install", "--offline", "--deployment")
    assert all(path.read_bytes() == data for path, data in before.items()), label
    swift = Path(subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip())
    builds = []
    for configuration in ["Debug", "Release"]:
        build = fixture.root / (label + "-" + configuration)
        build.mkdir()
        log = fixture.root / (build.name + ".log")
        run([
            "xcodebuild", "-workspace", next(work.glob("*.xcworkspace")), "-scheme", "Combined",
            "-configuration", configuration, "-destination", "platform=macOS,arch=" + platform.machine(),
            *fixture_build_arguments(build), "ARCHS=" + platform.machine(), "ONLY_ACTIVE_ARCH=YES",
            "CODE_SIGNING_ALLOWED=NO", "GCC_TREAT_WARNINGS_AS_ERRORS=YES", "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES",
            "TOOLCHAIN_DIR=" + str(swift.parents[2]), "TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault", "build",
        ], work, log, env=fixture.env)
        products = fixture_derived_data(build) / "Build/Products" / configuration
        expected = {"Demo": 11, "Other": 31} if not separate_configurations else {"Demo": 11 if configuration == "Debug" else 31}
        for app, value in expected.items():
            binary = products / (app + ".app/Contents/MacOS/" + app)
            output = run([binary], work, fixture.root / (build.name + "-" + app + "-run.log"), env=fixture.env)
            assert output.strip() == str(value), (label, configuration, app, output)
        builds.append({"case": label, "configuration": configuration, "applications": expected, "log": str(log)})
    fixture.verified.append(label + "_combined_build_execution_and_idempotence")
    return builds


def main():
    fixture = LifecycleFixture()
    builds = []
    for alias in ["Feature", "feature"]:
        for mode in [None, "static", "dynamic"]:
            label = ("same" if alias == "Feature" else "case") + "-" + (mode or "library")
            print("Module scope:", label, flush=True)
            builds.extend(build_case(fixture, label, alias, mode))
    builds.extend(build_case(fixture, "configuration-isolation", "feature", separate_configurations=True))
    (results_directory() / "native-module-scopes.json").write_text(json.dumps({
        "status": "passed", "fixture": str(fixture.root), "builds": builds,
        "verified": fixture.verified,
    }, indent=2) + "\n")


if __name__ == "__main__":
    execute(main, "native-module-scopes.json")
