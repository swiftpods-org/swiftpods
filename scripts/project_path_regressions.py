"""Recovery, relocation, generated projects and SDK paths at Unicode boundaries."""

import json
import platform
import plistlib
import re
import shutil
import subprocess
from xml.etree import ElementTree as ET

from bootstrap import ROOT, project_state_directory
from native_integration import serialize
from native_xcconfig_tests import create
from vendor_fixture import fixture_build_arguments, fixture_derived_data, run, sdk
from workspace_resource_regressions import read_project


def internal_project(parent):
    work, old = create(parent)
    selected = work / "\u0301Demo.xcodeproj"
    old.rename(selected)
    graph = read_project(selected)
    graph["objects"][graph["rootObject"]]["projectDirPath"] = "../Apps"
    (selected / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(graph))
    (work / "Podfile").write_text(
        "platform :osx, '13.0'\nproject './\u0301Demo.xcodeproj'\n"
        "target('Demo') { pod 'Kit', :path => './Kit' }\n"
    )
    return work, selected


def builds(fixture, work, label):
    for configuration in ["Debug", "Release"]:
        name = label + "-" + configuration
        build = fixture.root / name
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
            fixture.root / (name + "-build.log"),
            env=fixture.env,
        )
        binary = (
            fixture_derived_data(build)
            / "Build/Products"
            / configuration
            / "Demo.app/Contents/MacOS/Demo"
        )
        run([binary], work, fixture.root / (name + "-run.log"), env=fixture.env)


def reinstall(fixture, work, selected, *arguments):
    lock = (work / "Podfile.lock").read_bytes()
    projects = {
        path: path.read_bytes()
        for path in [
            selected / "project.pbxproj",
            *(work / "Pods").glob("*.xcodeproj/project.pbxproj"),
        ]
    }
    fixture.cli(work, "install", "--deployment", "--offline", *arguments)
    assert (work / "Podfile.lock").read_bytes() == lock
    assert all(path.read_bytes() == before for path, before in projects.items())


def assert_restored(fixture, selected, original, label):
    restored = read_project(selected)
    # An absent attributes dictionary and an empty one have the same Xcode semantics.
    root_object = original["rootObject"]
    if (
        "attributes" not in original["objects"][root_object]
        and restored["objects"][root_object].get("attributes") == {}
    ):
        restored["objects"][root_object].pop("attributes")
    if restored != original:
        (fixture.root / (label + "-deintegration.log")).write_text(
            json.dumps({"before": original, "after": restored}, indent=2) + "\n"
        )
    assert restored == original


def legacy_upgrade(fixture):
    base = fixture.root / "legacy-unicode-project"
    work, selected = internal_project(base)
    podfile = work / "Podfile"
    podfile.write_text(
        podfile.read_text().replace(
            "pod 'Kit',", "pod 'Kit', ENV.fetch('LEGACY_REQUIREMENT', '>= 0'),"
        )
    )
    fixture.cli(work, "install")
    report = fixture.cli(work, "ipc", "podfile", str(podfile))
    manifest = next(
        event["data"] for event in report["events"] if event.get("kind") == "inspection"
    )
    for target in manifest["targets"]:
        target.pop("_id", None)
        target["project"] = str(selected)
        target["swift_version"] = "5.0"
    # Independent Foundation encoder, verified against an actual pre-fix CLI lock.
    encoder = """import Foundation
import CryptoKit
let value = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile())
let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
print(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
"""
    encoded = subprocess.run(
        ["swift", "-warnings-as-errors", "-e", encoder],
        input=json.dumps(manifest),
        capture_output=True,
        text=True,
        cwd=ROOT,
        timeout=90,
        check=True,
    )
    (fixture.root / "legacy-checksum-encoder.log").write_text(
        encoded.stdout + encoded.stderr
    )
    checksum = encoded.stdout.strip()
    assert re.fullmatch("[0-9a-f]{64}", checksum)
    for path in [work / "Podfile.lock", work / "Pods/Manifest.lock"]:
        text, count = re.subn(
            r"(?m)^SWIFTPODS MANIFEST CHECKSUM: .+$",
            "SWIFTPODS MANIFEST CHECKSUM: " + checksum,
            path.read_text(),
        )
        assert count == 1
        path.write_text(text)
    receipt = work / "Pods/Target Support Files/SwiftPods-Integration.json"
    ownership = json.loads(receipt.read_text())
    for key in [
        "_project_root",
        "_project_paths",
        "_workspace_paths",
        "_manifest_checksum_aliases",
    ]:
        ownership.pop(key, None)
    receipt.write_text(json.dumps(ownership))
    lock = (work / "Podfile.lock").read_bytes()
    for _ in range(2):
        reinstall(fixture, work, selected)
    relocated = fixture.root / "legacy-unicode-project-relocated"
    shutil.move(base, relocated)
    work, selected = relocated / "work", relocated / "work/\u0301Demo.xcodeproj"
    for _ in range(2):
        fixture.cli(work, "install", "--deployment", "--offline")
        assert (work / "Podfile.lock").read_bytes() == lock
        assert (work / "Pods/Manifest.lock").read_bytes() == lock
    before = (selected / "project.pbxproj").read_bytes()
    old_requirement = fixture.env.get("LEGACY_REQUIREMENT")
    fixture.env["LEGACY_REQUIREMENT"] = ">= 1.0"
    try:
        rejected = fixture.cli(
            work, "install", "--deployment", "--offline", succeeds=False
        )
        assert any(
            event.get("code") == "SP-DEPLOYMENT-LOCK"
            for event in rejected.get("events", []) + [rejected.get("diagnostic", {})]
        ), rejected
        assert (work / "Podfile.lock").read_bytes() == lock
        assert (selected / "project.pbxproj").read_bytes() == before
    finally:
        if old_requirement is None:
            fixture.env.pop("LEGACY_REQUIREMENT")
        else:
            fixture.env["LEGACY_REQUIREMENT"] = old_requirement
    fixture.verified.extend(
        [
            "legacy_absolute_project_checksum_upgrades_and_relocates_without_lock_changes",
            "legacy_checksum_alias_rejects_changed_dynamic_dependency_requirements",
        ]
    )


def external_project_copy(fixture):
    base = fixture.root / "external-project-original"
    work, selected = create(base)
    graph = read_project(selected)
    for value in graph["objects"].values():
        if value.get("isa") != "XCBuildConfiguration" or not value["buildSettings"].get(
            "PRODUCT_NAME"
        ):
            continue
        value.pop("baseConfigurationReference", None)
        value["buildSettings"].update(
            {
                "SDKROOT": "macosx",
                "MACOSX_DEPLOYMENT_TARGET": "13.0",
                "GCC_PREPROCESSOR_DEFINITIONS": "$(inherited) USER_CONFIG=1 CONDITIONAL_CONFIG=1",
            }
        )
    (selected / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(graph))
    original = read_project(selected)
    fixture.cli(work, "install")
    original_integrated = (selected / "project.pbxproj").read_bytes()
    copied = fixture.root / "external-project-copy"
    shutil.copytree(base, copied, symlinks=True)
    work, selected = copied / "work", copied / "Apps/External.xcodeproj"
    fixture.cli(work, "install", "--deployment", "--offline")
    reinstall(fixture, work, selected)
    builds(fixture, work, "external-project-copy")
    fixture.cli(work, "deintegrate")
    assert_restored(fixture, selected, original, "external-project-copy")
    assert (
        base / "Apps/External.xcodeproj/project.pbxproj"
    ).read_bytes() == original_integrated
    fixture.verified.extend(
        [
            "copied_relative_external_project_reattaches_managed_xcconfigs_and_executes_debug_release",
            "copied_external_project_deintegration_restores_settings_without_changing_original",
        ]
    )


def project_recovery(fixture):
    base = fixture.root / "unicode-recovery"
    work, selected = internal_project(base)
    source = selected / "project.pbxproj"
    original = source.read_bytes()
    original_graph = read_project(selected)
    hidden = work / ".\u0301Private/Secret.xcodeproj/project.pbxproj"
    hidden.parent.mkdir(parents=True)
    hidden.write_bytes(b"private user file\n")
    podfile = work / "Podfile"
    original_podfile = podfile.read_bytes()
    podfile.write_text(
        podfile.read_text()
        + "post_integrate { |_| raise 'Intentional_recovery_fixture_failure' }\n"
    )
    failed = fixture.cli(work, "install", succeeds=False)
    assert failed["project_state"] == "recovery_required"
    journal = json.loads((project_state_directory(work) / "state.json").read_text())
    paths = [entry["path"] for entry in journal["journal"]]
    assert paths.count("\u0301Demo.xcodeproj/project.pbxproj") == 1
    assert not any(path.startswith("/") or "Private" in path for path in paths)
    managed = source.read_bytes()
    assert managed != original
    source.write_bytes(managed + b"// external edit\n")
    conflict = fixture.cli(work, "recover", succeeds=False)
    assert conflict["diagnostic"]["code"] == "SP-RECOVER-CONFLICT"
    assert source.read_bytes() == managed + b"// external edit\n"
    source.write_bytes(managed)
    restored = fixture.cli(work, "recover")
    assert restored["status"] == "recovered"
    assert (
        source.read_bytes() == original
        and hidden.read_bytes() == b"private user file\n"
    )
    assert not (work / "Pods").exists() and not (work / "Podfile.lock").exists()
    podfile.write_bytes(original_podfile)
    fixture.cli(work, "install")
    references = [
        element.attrib["location"]
        for element in ET.parse(
            next(work.glob("*.xcworkspace")) / "contents.xcworkspacedata"
        )
        .getroot()
        .iter("FileRef")
    ]
    assert "group:./\u0301Demo.xcodeproj" in references
    assert not any(value.startswith("absolute:") for value in references)
    lock = (work / "Podfile.lock").read_bytes()
    moved = fixture.root / "unicode-recovery-relocated"
    shutil.move(base, moved)
    work, selected = moved / "work", moved / "work/\u0301Demo.xcodeproj"
    fixture.cli(work, "install", "--deployment", "--offline")
    assert (work / "Podfile.lock").read_bytes() == lock
    reinstall(fixture, work, selected)
    builds(fixture, work, "unicode-recovery-relocated")
    fixture.cli(work, "deintegrate")
    assert_restored(fixture, selected, original_graph, "relocation")
    fixture.verified.extend(
        [
            "unicode_project_recovery_restores_original_and_preserves_external_edits",
            "hidden_unicode_projects_are_excluded_from_the_recovery_journal",
            "unicode_workspace_references_and_deployment_lock_survive_relocation",
            "relocated_unicode_project_builds_executes_debug_release_and_deintegrates",
            "relocated_unicode_project_reinstall_preserves_lock_and_project_bytes",
        ]
    )


def generated_projects(fixture):
    work, selected = create(fixture.root / "unicode-generated-projects")
    podfile = work / "Podfile"
    original = podfile.read_text()
    podfile.write_text(
        "install! 'cocoapods', :generate_multiple_pod_projects => true\n"
        + original.replace(
            ":path => './Kit'", ":path => './Kit', :project_name => '\u0301Library'"
        )
    )
    fixture.cli(work, "install")
    generated = work / "Pods/\u0301Library.xcodeproj"
    assert (generated / "project.pbxproj").is_file()
    inventory = json.loads(
        (work / "Pods/Target Support Files/SwiftPods-Projects.json").read_text()
    )
    assert "\u0301Library.xcodeproj/project.pbxproj" in inventory["files"]
    reinstall(fixture, work, selected)
    builds(fixture, work, "unicode-generated-projects")
    unowned = generated / "user-owned.txt"
    unowned.write_text("preserve\n")
    podfile.write_text(
        "install! 'cocoapods', :generate_multiple_pod_projects => true\n" + original
    )
    fixture.cli(work, "install")
    assert not (generated / "project.pbxproj").exists()
    assert unowned.read_text() == "preserve\n"
    assert (work / "Pods/Kit.xcodeproj/project.pbxproj").is_file()
    fixture.verified.extend(
        [
            "unicode_generated_project_inventory_builds_executes_debug_release",
            "unicode_generated_project_reinstall_is_stable_and_stale_project_is_removed",
        ]
    )


def sdk_fixture(parent, original, case):
    work, selected = create(parent)
    product = work / "Kit/Payload.xcframework"
    shutil.copytree(original, product, symlinks=True)
    metadata = plistlib.loads((product / "Info.plist").read_bytes())
    entry = metadata["AvailableLibraries"][0]
    if case in ("identifier", "nested-identifier"):
        old = entry["LibraryIdentifier"]
        entry["LibraryIdentifier"] = (
            "\u0301" + old if case == "identifier" else "Nested/\u0301Slice"
        )
        destination = product / entry["LibraryIdentifier"]
        destination.parent.mkdir(parents=True, exist_ok=True)
        (product / old).rename(destination)
    else:
        directory = product / entry["LibraryIdentifier"]
        old = entry["HeadersPath"]
        if case == "headers":
            entry["HeadersPath"] = "\u0301" + old
        elif case == "line-break-headers":
            entry["HeadersPath"] = "Headers\r\n"
        else:
            entry["HeadersPath"] = "/\u0301" + old
        (directory / old).rename(directory / entry["HeadersPath"].lstrip("/"))
    (product / "Info.plist").write_bytes(
        plistlib.dumps(
            metadata,
            fmt=plistlib.FMT_BINARY
            if case == "line-break-headers"
            else plistlib.FMT_XML,
        )
    )
    spec = work / "Kit/Kit.podspec.json"
    attributes = json.loads(spec.read_text())
    attributes["vendored_frameworks"] = "Payload.xcframework"
    spec.write_text(json.dumps(attributes))
    (work / "Kit/Kit.c").write_text(
        "int Payload_value(void); int kit_value(void) { return Payload_value()==42 ? 7 : -1; }\n"
    )
    return work, selected


def sdk_paths(fixture):
    producer = fixture.root / "unicode-sdk-producer"
    producer.mkdir()
    original = sdk(producer, "Payload", library=True, platforms=("macosx",))
    for case in ["identifier", "headers"]:
        work, selected = sdk_fixture(
            fixture.root / ("unicode-sdk-" + case), original, case
        )
        fixture.cli(work, "install")
        reinstall(fixture, work, selected)
        builds(fixture, work, "unicode-sdk-" + case)
        fixture.verified.extend(
            [
                "unicode_xcframework_" + case + "_builds_executes_debug_release",
                "unicode_xcframework_" + case + "_reinstall_is_stable_offline",
            ]
        )
    for case, code in [
        ("nested-identifier", "SP-XCFRAMEWORK-METADATA"),
        ("absolute-headers", "SP-XCFRAMEWORK-PATH"),
        ("line-break-headers", "SP-XCFRAMEWORK-PATH"),
    ]:
        work, selected = sdk_fixture(
            fixture.root / ("unicode-sdk-" + case), original, case
        )
        original_project = (selected / "project.pbxproj").read_bytes()
        rejected = fixture.cli(work, "install", succeeds=False)
        assert any(event.get("code") == code for event in rejected.get("events", [])), (
            rejected
        )
        assert (selected / "project.pbxproj").read_bytes() == original_project
        if rejected.get("project_state") == "recovery_required":
            fixture.cli(work, "recover")
        fixture.verified.append("unicode_xcframework_rejects_" + case)


def run_regressions(fixture):
    legacy_upgrade(fixture)
    external_project_copy(fixture)
    project_recovery(fixture)
    generated_projects(fixture)
    sdk_paths(fixture)
