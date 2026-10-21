"""PBX paths and inventory receipts retain literal filesystem identities."""

import hashlib
import json
import platform
import plistlib
import shutil

from Tests.Fixtures.vendor_fixture import (
    fixture_build_arguments,
    fixture_derived_data,
    run,
)
from Tests.Integration.native_integration import serialize
from Tests.Integration.native_xcconfig_tests import create
from Tests.Regression.name_boundary_regressions import diagnostic
from Tests.Regression.project_path_regressions import builds, reinstall
from Tests.Regression.workspace_resource_regressions import read_project

PATH_CASES = [
    "file-relative",
    "file-absolute",
    "group",
    "source-root-relative",
    "source-root-absolute",
    "project-root",
]


def write_graph(selected, graph, encoding="openstep"):
    file = selected / "project.pbxproj"
    if encoding == "binary":
        file.write_bytes(plistlib.dumps(graph, fmt=plistlib.FMT_BINARY))
    else:
        # OpenStep uses upper-case U for UTF-16 escapes, unlike JSON.
        file.write_text(
            "// !$*UTF8*$!\n" + serialize(graph).replace("\\u0000", "\\U0000")
        )


def invalid_project(parent, case, encoding):
    work, selected = create(parent)
    graph = read_project(selected)
    fields = []
    if case.startswith("file-"):
        for identifier, value in graph["objects"].items():
            name = value.get("path")
            if value.get("isa") != "PBXFileReference" or name not in [
                "Debug.xcconfig",
                "Release.xcconfig",
            ]:
                continue
            actual = selected.parent / "Configs" / name
            actual.rename(
                actual.with_name(name.replace(".xcconfig", "%00Ignored.xcconfig"))
            )
            value["path"] = (
                str(actual).replace(".xcconfig", "\0Ignored.xcconfig")
                if case.endswith("absolute")
                else name.replace(".xcconfig", "\0Ignored.xcconfig")
            )
            fields.append((identifier, "path"))
    elif case == "group":
        (selected.parent / "Configs").rename(selected.parent / "Configs%00Ignored")
        for identifier, value in graph["objects"].items():
            if value.get("isa") == "PBXGroup" and value.get("path") == "Configs":
                value["path"] = "Configs\0Ignored"
                fields.append((identifier, "path"))
    elif case.startswith("source-root-"):
        alias = selected.parent.with_name("Apps%00Ignored")
        alias.mkdir()
        for name in ["Configs", "Sources"]:
            shutil.copytree(selected.parent / name, alias / name)
        graph["objects"][graph["rootObject"]]["projectDirPath"] = (
            str(alias).replace("%00", "\0")
            if case.endswith("absolute")
            else "../Apps\0Ignored"
        )
        fields.append((graph["rootObject"], "projectDirPath"))
    else:
        graph["objects"][graph["rootObject"]]["projectRoot"] = "Before\0After"
        fields.append((graph["rootObject"], "projectRoot"))
    write_graph(selected, graph, encoding)
    retained = read_project(selected)
    assert fields and all("\0" in retained["objects"][i][k] for i, k in fields)
    return work, selected


def invalid_projects(fixture):
    for encoding in ["openstep", "binary"]:
        for case in PATH_CASES:
            label = encoding + "-" + case
            work, selected = invalid_project(
                fixture.root / ("pbx-nul-" + label), case, encoding
            )
            podfile = work / "Podfile"
            podfile.write_text(
                podfile.read_text()
                + "pre_install { |_| File.write('pre-hook-ran', 'yes') }\n"
            )
            spec = work / "Kit/Kit.podspec.json"
            data = json.loads(spec.read_text())
            data["prepare_command"] = "printf ran > prepare-ran"
            spec.write_text(json.dumps(data))
            originals = {
                p: p.read_bytes() for p in [podfile, spec, selected / "project.pbxproj"]
            }
            result = fixture.cli(work, "install", succeeds=False)
            assert diagnostic(result, "SP-XCODE-PATH"), result
            assert result["project_state"] == "failed_no_managed_changes", result
            assert all(p.read_bytes() == before for p, before in originals.items())
            assert (
                not (work / "pre-hook-ran").exists()
                and not (spec.parent / "prepare-ran").exists()
            )
            assert not (work / "Pods").exists() and not (work / "Podfile.lock").exists()
            fixture.verified.append("pbx_path_nul_" + label + "_early_rejection")


def invalid_hooks(fixture):
    assignments = {
        "group": 'installer.pods_project.main_group.path = "Before\\u0000After"',
        "file": 'installer.pods_project.main_group.new_file("Before\\u0000After")',
        "source-root": 'installer.pods_project.root_object.project_dir_path = "Before\\u0000After"',
        "project-root": 'installer.pods_project.root_object.project_root = "Before\\u0000After"',
    }
    for callback in [False, True]:
        for kind, assignment in assignments.items():
            label = kind + ("-callback" if callback else "-reply")
            work, selected = create(fixture.root / ("pbx-hook-nul-" + label))
            original = (selected / "project.pbxproj").read_bytes()
            podfile = work / "Podfile"
            podfile.write_text(
                podfile.read_text().split("post_install do |i|", 1)[0]
                + "post_install do |installer|\n"
                + assignment
                + "\n"
                + ("installer.pods_project.save\n" if callback else "")
                + "end\n"
            )
            result = fixture.cli(work, "install", succeeds=False)
            if callback:
                assert diagnostic(result, "SP-DSL-ERROR") and any(
                    "SP-XCODE-PATH" in e.get("message", "") for e in result["events"]
                ), result
            else:
                assert diagnostic(result, "SP-XCODE-PATH"), result
            assert result["project_state"] == "recovery_required", result
            generated = work / "Pods/Pods.xcodeproj/project.pbxproj"
            assert not generated.exists() or b"\0" not in generated.read_bytes()
            fixture.cli(work, "recover")
            assert (selected / "project.pbxproj").read_bytes() == original
            fixture.verified.append("pbx_path_nul_hook_" + label + "_recoverable")


def invalid_inspection(fixture):
    for encoding in ["openstep", "binary"]:
        work, selected = invalid_project(
            fixture.root / ("pbx-inspect-nul-" + encoding), "group", encoding
        )
        podfile = work / "Podfile"
        podfile.write_text(
            "require 'xcodeproj'\nXcodeproj::Project.open('../Apps/External.xcodeproj')\n"
            "File.write('after-open-ran', 'yes')\n" + podfile.read_text()
        )
        originals = {p: p.read_bytes() for p in [podfile, selected / "project.pbxproj"]}
        result = fixture.cli(work, "ipc", "podfile", str(podfile), succeeds=False)
        assert diagnostic(result, "SP-DSL-ERROR") and any(
            "SP-XCODE-PATH" in e.get("message", "") for e in result["events"]
        ), result
        assert result["project_state"] == "untracked", result
        assert all(p.read_bytes() == before for p, before in originals.items())
        assert not (work / "after-open-ran").exists()
        assert not (work / "Pods").exists()
        fixture.verified.append("pbx_path_nul_" + encoding + "_inspection_is_read_only")


def inventory_alias(work, scheme, name="Retired%00Ignored"):
    return work / (
        "Pods/Retired.xcodeproj/xcshareddata/xcschemes/" + name + ".xcscheme"
        if scheme
        else "Pods/" + name + ".xcodeproj/project.pbxproj"
    )


def invalid_inventory(fixture):
    for scheme in [False, True]:
        for matching in [False, True]:
            label = ("scheme" if scheme else "project") + (
                "-matching" if matching else "-different"
            )
            work, selected = create(fixture.root / ("inventory-nul-" + label))
            podfile = work / "Podfile"
            podfile.write_text(
                podfile.read_text()
                + "pre_install { |_| File.write('pre-hook-ran', 'yes') }\n"
            )
            fixture.cli(work, "install")
            (work / "pre-hook-ran").unlink()
            alias = inventory_alias(work, scheme)
            alias.parent.mkdir(parents=True)
            alias.write_text("preserved inventory alias\n")
            receipt = work / "Pods/Target Support Files/SwiftPods-Projects.json"
            value = json.loads(receipt.read_text())
            relative = alias.relative_to(work / "Pods").as_posix().replace("%00", "\0")
            value["files"][relative] = (
                hashlib.sha256(alias.read_bytes()).hexdigest() if matching else "0" * 64
            )
            receipt.write_text(json.dumps(value))
            originals = {
                p: p.read_bytes()
                for p in [
                    receipt,
                    alias,
                    selected / "project.pbxproj",
                    work / "Podfile.lock",
                ]
            }
            result = fixture.cli(work, "install", succeeds=False)
            assert diagnostic(result, "SP-XCODE-INVENTORY"), result
            assert result["project_state"] == "failed_no_managed_changes", result
            assert all(p.read_bytes() == before for p, before in originals.items())
            assert not (work / "pre-hook-ran").exists()
            fixture.verified.append(
                "project_inventory_nul_" + label + "_preserves_alias"
            )


def valid_projects(fixture):
    for absolute in [False, True]:
        for spelling in ["percent", "unicode"]:
            label = spelling + ("-absolute" if absolute else "-relative")
            work, selected = create(fixture.root / ("pbx-valid-" + label))
            graph = read_project(selected)
            root_name = "Apps%00Ignored" if spelling == "percent" else "\u0301Apps東京"
            group_name = (
                "Configs%00Ignored" if spelling == "percent" else "\u0301Configs東京"
            )
            source = selected.parent.with_name(root_name)
            source.mkdir()
            shutil.copytree(selected.parent / "Configs", source / group_name)
            shutil.copytree(selected.parent / "Sources", source / "Sources")
            graph["objects"][graph["rootObject"]]["projectDirPath"] = (
                str(source) if absolute else "../" + root_name
            )
            for value in graph["objects"].values():
                if value.get("isa") == "PBXGroup" and value.get("path") == "Configs":
                    value["path"] = group_name
                if value.get("isa") == "PBXFileReference" and value.get("path") in [
                    "Debug.xcconfig",
                    "Release.xcconfig",
                ]:
                    old = value["path"]
                    name = ("%00" if spelling == "percent" else "\u0301") + old
                    (source / group_name / old).rename(source / group_name / name)
                    value["path"] = (
                        str(source / group_name / name) if absolute else name
                    )
                    if absolute:
                        value["sourceTree"] = "<absolute>"
            write_graph(selected, graph)
            fixture.cli(work, "install")
            reinstall(fixture, work, selected)
            retained = read_project(selected)["objects"][graph["rootObject"]][
                "projectDirPath"
            ]
            assert retained == graph["objects"][graph["rootObject"]]["projectDirPath"]
            fixture.verified.append("pbx_valid_" + label + "_offline_reinstall")
            builds(fixture, work, "pbx-valid-" + label)
            fixture.verified.append("pbx_valid_" + label + "_debug_release_consumers")


def valid_inventory(fixture):
    for scheme in [False, True]:
        label = "unicode-scheme" if scheme else "percent-project"
        work, selected = create(fixture.root / ("inventory-valid-" + label))
        fixture.cli(work, "install")
        owned = inventory_alias(
            work, scheme, "\u0301Retired東京" if scheme else "Retired%00Ignored"
        )
        edited = inventory_alias(work, scheme, "Peer%00Edited")
        for file in [owned, edited]:
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text("original\n")
        receipt = work / "Pods/Target Support Files/SwiftPods-Projects.json"
        value = json.loads(receipt.read_text())
        for file in [owned, edited]:
            value["files"][file.relative_to(work / "Pods").as_posix()] = hashlib.sha256(
                file.read_bytes()
            ).hexdigest()
        receipt.write_text(json.dumps(value))
        edited.write_text("external edit\n")
        fixture.cli(work, "install")
        assert not owned.exists() and edited.read_text() == "external edit\n"
        reinstall(fixture, work, selected)
        assert edited.read_text() == "external edit\n"
        fixture.verified.append(
            "project_inventory_valid_" + label + "_cleanup_preserves_edits"
        )


def unicode_schemes(fixture):
    name = "\u0301Kit"
    for multiple in [False, True]:
        label = "multiple" if multiple else "single"
        work, selected = create(fixture.root / ("unicode-shared-scheme-" + label))
        spec = work / "Kit/Kit.podspec.json"
        value = json.loads(spec.read_text())
        value["name"] = name
        spec.unlink()
        spec = spec.with_name(name + ".podspec.json")
        spec.write_text(json.dumps(value))
        (work / "Podfile").write_text(
            "install! 'cocoapods', :integrate_targets => false, :share_schemes_for_development_pods => true"
            + (", :generate_multiple_pod_projects => true" if multiple else "")
            + "\nplatform :osx, '13.0'\ntarget 'Demo' do\npod "
            + json.dumps(name, ensure_ascii=False)
            + ", :path => './Kit'\nend\n"
        )
        fixture.cli(work, "install")
        project = work / "Pods/Pods.xcodeproj"
        scheme = project / ("xcshareddata/xcschemes/" + name + ".xcscheme")
        assert scheme.is_file()
        lock = work / "Podfile.lock"
        reference = run(
            [
                fixture.env["SWIFTPODS_RUBY"],
                "-e",
                "require 'yaml';require 'json';puts JSON.generate(YAML.safe_load(File.read(ARGV[0]), permitted_classes: [Symbol]))",
                lock,
            ],
            work,
            fixture.root / ("unicode-scheme-" + label + "-reference.log"),
            env=fixture.env,
        )
        assert name in json.loads(reference)["EXTERNAL SOURCES"]
        reinstall(fixture, work, selected)
        fixture.verified.append("unicode_shared_scheme_" + label + "_offline_reinstall")
        for configuration in ["Debug", "Release"]:
            build = fixture.root / ("unicode-scheme-" + label + "-" + configuration)
            build.mkdir()
            log_label = "unicode-scheme-" + label + "-" + configuration
            run(
                [
                    "xcodebuild",
                    "-project",
                    project,
                    "-scheme",
                    name,
                    "-configuration",
                    configuration,
                    "-destination",
                    "platform=macOS,arch=" + platform.machine(),
                    *fixture_build_arguments(build),
                    "CODE_SIGNING_ALLOWED=NO",
                    "build",
                ],
                work,
                fixture.root / (log_label + "-build.log"),
                env=fixture.env,
            )
            derived = fixture_derived_data(build)
            libraries = list((derived / "Build/Products" / configuration).glob("*.a"))
            assert len(libraries) == 1, libraries
            source = build / "consumer.c"
            source.write_text(
                '#include <stdio.h>\nint kit_value(void);\nint main(void) { int value=kit_value(); printf("scheme-value=%d\\n",value); return value==7 ? 0 : 1; }\n'
            )
            binary = derived / "scheme-consumer"
            run(
                [
                    "xcrun",
                    "clang",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    "-mmacosx-version-min=13.0",
                    source,
                    libraries[0],
                    "-o",
                    binary,
                ],
                work,
                fixture.root / (log_label + "-consumer-build.log"),
                env=fixture.env,
            )
            text = run(
                [binary], work, fixture.root / (log_label + "-run.log"), env=fixture.env
            )
            assert "scheme-value=7" in text
        fixture.verified.append(
            "unicode_shared_scheme_" + label + "_debug_release_consumers"
        )


def run_regressions(fixture):
    invalid_projects(fixture)
    invalid_inspection(fixture)
    invalid_hooks(fixture)
    invalid_inventory(fixture)
    valid_projects(fixture)
    valid_inventory(fixture)
    unicode_schemes(fixture)
