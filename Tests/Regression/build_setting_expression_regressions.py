"""Xcode expression evaluation, literal defaults and generated filesystem paths."""

import json
import platform
import subprocess
import tempfile
from pathlib import Path

from scripts.support.bootstrap import ROOT
from scripts.support.processes import run_captured
from Tests.Fixtures.vendor_fixture import (
    fixture_build_arguments,
    fixture_derived_data,
    run,
)
from Tests.Integration.native_xcconfig_tests import create
from Tests.Regression.configuration_context_regressions import configurations, save
from Tests.Regression.project_path_regressions import assert_restored, reinstall
from Tests.Regression.workspace_resource_regressions import read_project

FORMS = [
    "control",
    "bare-unknown",
    "nested-unknown",
    "suffix-unknown",
    "invalid-path",
    "lower-sdk",
    "standardize-sdk",
    "standardize-reference",
    "lower-reference",
    "literal-root-control",
    "literal-root-sdk",
    "literal-unknown-root",
    "literal-project-name",
    "literal-config-name",
    "literal-target-name",
    "implicit-unknown",
    "literal-inherited-root",
    "literal-braced-root",
    "literal-short-root",
]
KEYS = [
    "SDK_VALUE",
    "FILE_SENTINEL",
    "SOURCE_ROOT",
    "PROJECT_NAME",
    "CONFIGURATION",
    "TARGET_NAME",
]
EXPECTED_OUTPUT = "value=7 user=1 conditional=1 expansion=7"
BUILD_FORMS = {
    "bare-unknown",
    "nested-unknown",
    "suffix-unknown",
    "lower-sdk",
    "standardize-sdk",
    "standardize-reference",
    "lower-reference",
    "literal-root-control",
    "literal-root-sdk",
    "literal-unknown-root",
    "literal-project-name",
    "literal-config-name",
    "literal-target-name",
    "implicit-unknown",
    "literal-inherited-root",
    "literal-braced-root",
    "literal-short-root",
}


def hook(work, *, implicit=False):
    podfile = work / "Podfile"
    text = podfile.read_text().split("post_install do |i|", 1)[0]
    if implicit:
        text = text.replace("platform :osx, '13.0'\n", "")
    podfile.write_text(
        text
        + """post_install do |i|
 t=i.aggregate_targets.first.user_targets.first
 values=%w[SDK_VALUE FILE_SENTINEL SDKROOT SOURCE_ROOT PROJECT_NAME CONFIGURATION TARGET_NAME].to_h { |key| [key,t.resolved_build_setting(key,true)] }
 File.write('expression-values.json',JSON.generate(values))
 File.write('../Apps/Sources/Expression.h', '#define EXPRESSION_VALUE ' + (values['SDK_VALUE'].values.first || '0') + 10.chr)
end
"""
    )


def prepare(parent, form):
    container = parent / ("expression-" + form)
    literal = {
        "literal-root-control": "Root-$(SDKROOT)",
        "literal-root-sdk": "Root-$(SDKROOT)",
        "literal-unknown-root": "Root-$(UNDECLARED)",
        "literal-inherited-root": "Root-$(inherited)",
        "literal-braced-root": "Root-${SDKROOT}",
        "literal-short-root": "Root-$SDKROOT-$$",
    }.get(form)
    if literal:
        container = container / literal
    work, selected = create(container)
    graph = read_project(selected)
    target, debug = "Demo", "Debug"
    if form == "literal-project-name":
        replacement = selected.with_name("External-$(CONFIGURATION).xcodeproj")
        selected.rename(replacement)
        podfile = work / "Podfile"
        podfile.write_text(podfile.read_text().replace(selected.name, replacement.name))
        selected = replacement
    if form == "literal-target-name":
        target = "Demo$(SDKROOT)"
        for obj in graph["objects"].values():
            if obj.get("isa") == "PBXNativeTarget" and obj.get("name") == "Demo":
                obj["name"] = target
        podfile = work / "Podfile"
        podfile.write_text(
            podfile.read_text().replace("target 'Demo'", "target '" + target + "'")
        )
    if form == "literal-config-name":
        debug = "Debug$(SDKROOT)"
        for obj in graph["objects"].values():
            if obj.get("isa") == "XCBuildConfiguration" and obj.get("name") == "Debug":
                obj["name"] = debug
    sdk_path = Path(
        subprocess.check_output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
        ).strip()
    )
    for name in {
        "SelectedSDK.sdk",
        "FixtureProducts.sdk",
        selected.stem + ".sdk",
        debug + ".sdk",
        "Release.sdk",
        *[target + "-" + c + ".sdk" for c in [debug, "Release"]],
    }:
        (selected.parent / name).symlink_to(sdk_path, target_is_directory=True)
    raw = {
        "control": "macosx",
        "bare-unknown": "$(UNDECLARED_SDK)",
        "nested-unknown": "${SDK_CHOICE}",
        "suffix-unknown": "macosx$(UNDECLARED_SDK)",
        "invalid-path": "$(UNDECLARED_SDK)/MacOSX.sdk",
        "lower-sdk": "$(SDK_CHOICE:lower)",
        "standardize-sdk": "$(SDK_FOLDER:standardizepath)",
        "standardize-reference": "macosx",
        "lower-reference": "macosx",
        "literal-root-control": "macosx",
        "literal-project-name": "$(PROJECT_DIR)/$(PROJECT_NAME).sdk",
        "literal-config-name": "$(PROJECT_DIR)/$(CONFIGURATION).sdk",
        "literal-target-name": "$(PROJECT_DIR)/$(TARGET_NAME)-$(CONFIGURATION).sdk",
        "implicit-unknown": "$(UNDECLARED_SDK)",
    }.get(form, "$(SRCROOT)/SelectedSDK.sdk")
    base = selected.parent / "Configs/Base.xcconfig"
    text = base.read_text().replace("SDKROOT = macosx", "SDKROOT = " + raw)
    text += "\nSDK_VALUE[sdk=macosx*] = 7\nFILE_SENTINEL = 17\n"
    text += {
        "nested-unknown": "SDK_CHOICE = $(UNDECLARED_SDK)\n",
        "lower-sdk": "SDK_CHOICE = MACOSX\n",
        "standardize-sdk": "SDK_FOLDER = $(SRCROOT)/Configs/../SelectedSDK.sdk\n",
    }.get(form, "")
    base.write_text(text)
    for configuration, actual in [("Debug", debug), ("Release", "Release")]:
        file = base.parent / (configuration + ".xcconfig")
        file.write_text(
            file.read_text()
            .replace("Pods-Demo", "Pods-" + target)
            .replace("[config=" + configuration + "]", "[config=*]")
            .replace(
                "." + configuration.lower() + ".xcconfig",
                "." + actual.lower() + ".xcconfig",
            )
        )
    reference_paths(graph, selected, form)
    save(selected, graph)
    hook(work, implicit=form == "implicit-unknown")
    source = selected.parent / "Sources/main.mm"
    source.write_text(
        ('#include "Expression.h"\n' + source.read_text())
        .replace("conditional=%d\\n", "conditional=%d expansion=%d\\n")
        .replace("CONDITIONAL_CONFIG);", "CONDITIONAL_CONFIG, EXPRESSION_VALUE);")
    )
    return work, selected, target, [debug, "Release"], raw


def reference_paths(graph, selected, form):
    if form not in {"standardize-reference", "lower-reference"}:
        return
    project, _ = configurations(graph)
    for obj in project:
        obj["buildSettings"].update(
            CONFIG_FOLDER="$(PROJECT_DIR)/Configs/../Configs",
            CONFIG_FILE=obj["name"].upper(),
        )
    for obj in graph["objects"].values():
        if obj.get("isa") != "PBXFileReference" or obj.get("path") not in {
            "Debug.xcconfig",
            "Release.xcconfig",
        }:
            continue
        name = obj["path"]
        if form == "standardize-reference":
            path = "$(CONFIG_FOLDER:standardizepath)/" + name
        else:
            folder = selected.parent / "Configs"
            (folder / name.lower()).write_text((folder / name).read_text())
            path = "$(PROJECT_DIR)/Configs/$(CONFIG_FILE:lower).xcconfig"
        obj.update(path=path, sourceTree="<absolute>")


def reference(fixture, work, selected, target, configuration, label):
    prefix = fixture.root / (label + "-" + configuration + "-settings")
    result = run_captured(
        [
            "xcodebuild",
            "-project",
            selected,
            "-target",
            target,
            "-configuration",
            configuration,
            "-showBuildSettings",
            "-json",
        ],
        work,
        prefix,
        env=fixture.env,
        timeout=120,
    )
    output = result.stdout + result.stderr
    assert (
        result.returncode == 0
        and " warning:" not in output
        and "\nwarning:" not in output
    ), prefix
    return next(
        row["buildSettings"]
        for row in json.loads(result.stdout)
        if row["target"] == target
    )


def compare(fixture, work, selected, target, configs, label, values, available):
    observations = {}
    for config in configs:
        expected = reference(fixture, work, selected, target, config, label)
        actual = {key: values[key].get(config) for key in KEYS}
        assert actual == {key: expected.get(key) for key in KEYS}, (
            label,
            config,
            actual,
            expected,
        )
        assert actual["FILE_SENTINEL"] == "17"
        assert actual["SDK_VALUE"] == ("7" if available else None)
        observations[config] = {**actual, "SDK_NAME": expected.get("SDK_NAME")}
    (fixture.root / (label + "-comparison.json")).write_text(
        json.dumps(observations, indent=2) + "\n"
    )


def consumers(fixture, work, target, configs, label, *, filtered_resources=False):
    for config in configs:
        name = label + "-" + config
        build = fixture.root / name
        build.mkdir()
        run(
            [
                "xcodebuild",
                "-workspace",
                next(work.glob("*.xcworkspace")),
                "-scheme",
                target,
                "-configuration",
                config,
                "-destination",
                "platform=macOS,arch=" + platform.machine(),
                *fixture_build_arguments(build),
                "CODE_SIGNING_ALLOWED=NO",
                # Xcode reparses literal macro text in its built-in linker directories.
                # Compare original names above; use a safe product folder for this build.
                *(["CONFIGURATION=FixtureProducts"] if "$(" in config else []),
                "build",
            ],
            work,
            fixture.root / (name + "-build.log"),
            env=fixture.env,
        )
        folder = "FixtureProducts" if "$(" in config else config
        binary = (
            fixture_derived_data(build)
            / "Build/Products"
            / folder
            / "Demo.app/Contents/MacOS/Demo"
        )
        if filtered_resources:
            resources = binary.parent.parent / "Resources"
            expected = config == "Debug"
            assert (resources / "ExtraAsset-$(SDKROOT).txt").exists() == expected
            assert (resources / "ExtraAssets.bundle").exists() == expected
        output = fixture.root / (name + "-run.log")
        run([binary], work, output, env=fixture.env)
        assert output.read_text().strip() == EXPECTED_OUTPUT, output


def case(fixture, parent, form):
    work, selected, target, configs, raw = prepare(parent, form)
    label = "expression-" + form
    original = read_project(selected)
    fixture.cli(work, "install")
    values = json.loads((work / "expression-values.json").read_text())
    (fixture.root / (label + "-native.json")).write_text(
        json.dumps(values, indent=2) + "\n"
    )
    assert values["SDKROOT"] == {c: raw for c in configs}
    fixture.verified.append(label + "_raw_declarations_are_preserved")
    compare(
        fixture, work, selected, target, configs, label, values, form != "invalid-path"
    )
    fixture.verified.append(
        label + "_conditions_paths_and_literal_defaults_match_Xcode"
    )
    reinstall(fixture, work, selected)
    assert json.loads((work / "expression-values.json").read_text()) == values
    fixture.verified.append(label + "_offline_deployment_is_byte_stable")
    if form in BUILD_FORMS:
        consumers(fixture, work, target, configs, label)
        fixture.verified.append(
            label + "_Debug_Release_consumers_execute_expected_values"
        )
    if form != "invalid-path":
        fixture.cli(selected.parent, "init")
        initialized = (selected.parent / "Podfile").read_text()
        assert "platform :osx, '13.0'" in initialized
        (fixture.root / (label + "-init.txt")).write_text(initialized)
        fixture.verified.append(label + "_init_infers_platform")
    fixture.cli(work, "deintegrate")
    assert_restored(fixture, selected, original, label)
    fixture.cli(work, "deintegrate")
    assert_restored(fixture, selected, original, label + "-twice")
    fixture.verified.append(label + "_deintegration_restores_user_graph_twice")


def recorded_expressions(fixture, parent):
    observations = json.loads(
        (ROOT / "Tests/Fixtures/BuildSettingExpressions.json").read_text()
    )
    for scalar_sdk in [False, True]:
        label = "expression-operators-" + ("scalar" if scalar_sdk else "list")
        work, selected = create(parent / label)
        graph = read_project(selected)
        records = [
            row
            for row in observations
            if (row["name"] == "sdk-source-escape") == scalar_sdk
        ]
        _, targets = configurations(graph)
        for obj in targets:
            obj["buildSettings"].update(records[0]["settings"])
            for index, row in enumerate(records):
                obj["buildSettings"]["OBS_" + str(index)] = row["expression"]
        save(selected, graph)
        for config in ["Debug", "Release"]:
            values = reference(fixture, work, selected, "Demo", config, label)
            for index, row in enumerate(records):
                assert values.get("OBS_" + str(index), "") == row["expected"], (
                    config,
                    row,
                    values,
                )
        for row in records:
            fixture.verified.append(
                "expression_operator_" + row["name"] + "_matches_recorded_Xcode"
            )


def relocated_literal(fixture, parent):
    work, selected, target, configs, _ = prepare(parent, "literal-root-sdk")
    original = read_project(selected)
    fixture.cli(work, "install")
    # Move the whole sibling layout; the generated references must follow it.
    destination = parent / "Relocated-${SDKROOT}-$NAME"
    selected.parent.parent.rename(destination)
    work, selected = destination / "work", destination / "Apps" / selected.name
    fixture.cli(work, "install", "--offline", "--deployment")
    reinstall(fixture, work, selected)
    consumers(fixture, work, target, configs, "expression-relocated")
    fixture.cli(work, "deintegrate")
    assert_restored(fixture, selected, original, "expression-relocated")
    fixture.verified.append(
        "expression_literal_paths_relocate_reinstall_build_and_deintegrate"
    )


def filtered_literal_resources(fixture, parent):
    work, selected, target, configs, raw = prepare(
        parent / "filtered-resources", "literal-root-sdk"
    )
    label = "expression-filtered-resources"
    extra = work / "Extra"
    extra.mkdir()
    (extra / "Extra.c").write_text("int extra(void) { return 1; }\n")
    (extra / "ExtraAsset-$(SDKROOT).txt").write_text("direct\n")
    (extra / "Bundle.txt").write_text("bundle\n")
    (extra / "Extra.podspec.json").write_text(
        json.dumps(
            {
                "name": "Extra",
                "version": "1.0",
                "source_files": "Extra.c",
                "resources": "ExtraAsset-$(SDKROOT).txt",
                "resource_bundles": {"ExtraAssets": "Bundle.txt"},
                "platforms": {"osx": "13.0"},
            }
        )
    )
    podfile = work / "Podfile"
    token = " pod 'Kit', :path => './Kit'"
    assert token in podfile.read_text()
    podfile.write_text(
        podfile.read_text().replace(
            token,
            token + "\n pod 'Extra', :path => './Extra', :configurations => ['Debug']",
        )
    )
    original = read_project(selected)
    fixture.cli(work, "install")
    values = json.loads((work / "expression-values.json").read_text())
    (fixture.root / (label + "-native.json")).write_text(
        json.dumps(values, indent=2) + "\n"
    )
    assert values["SDKROOT"] == {c: raw for c in configs}
    compare(fixture, work, selected, target, configs, label, values, True)
    fixture.verified.append(label + "_original_context_matches_Xcode")
    graph = read_project(selected)
    _, targets = configurations(graph)
    release = next(obj["buildSettings"] for obj in targets if obj["name"] == "Release")
    exclusions = release["EXCLUDED_SOURCE_FILE_NAMES"]
    (fixture.root / (label + "-exclusions.json")).write_text(
        json.dumps(exclusions, indent=2) + "\n"
    )
    assert any(
        "ExtraAssets.bundle" in value
        and any(prefix in value for prefix in ["$(BUILD_DIR)", "$(BUILT_PRODUCTS_DIR)"])
        and "$$(BUILD_DIR)" not in value
        and "$$(BUILT_PRODUCTS_DIR)" not in value
        for value in exclusions
    )
    assert any("ExtraAsset-$$(SDKROOT).txt" in value for value in exclusions)
    fixture.verified.append(
        label + "_filesystem_and_product_exclusions_keep_distinct_syntax"
    )
    reinstall(fixture, work, selected)
    fixture.verified.append(label + "_offline_deployment_is_byte_stable")
    consumers(fixture, work, target, configs, label, filtered_resources=True)
    fixture.verified.append(
        label + "_Debug_copies_and_Release_excludes_literal_file_and_bundle"
    )
    for suffix in ["", "-twice"]:
        fixture.cli(work, "deintegrate")
        assert_restored(fixture, selected, original, label + suffix)
    fixture.verified.append(label + "_deintegration_restores_user_graph_twice")


def rejecting_expression(fixture, parent, form):
    work, selected = create(parent / ("expression-reject-" + form))
    base = selected.parent / "Configs/Base.xcconfig"
    expression = "$(FIRST:lower)" if form == "cycle" else "$(FIRST:lower"
    base.write_text(
        base.read_text().replace("SDKROOT = macosx", "SDKROOT = " + expression)
        + "FIRST = ${SECOND:upper}\nSECOND = $(FIRST)\n"
    )
    podfile = work / "Podfile"
    podfile.write_text(
        podfile.read_text()
        + "pre_install { |_| File.write('expression-hook-ran', 'yes') }\n"
    )
    original = (selected / "project.pbxproj").read_bytes()
    result = fixture.cli(work, "install", succeeds=False)
    code = "SP-XCCONFIG-CYCLE" if form == "cycle" else "SP-XCCONFIG-EXPRESSION"
    assert result["project_state"] == "failed_no_managed_changes"
    assert any(event.get("code") == code for event in result["events"]), result
    assert (selected / "project.pbxproj").read_bytes() == original
    assert not any(
        (work / name).exists()
        for name in [
            "Pods",
            "Podfile.lock",
            "resolved-settings.json",
            "expression-hook-ran",
        ]
    )
    fixture.verified.append(
        "expression_" + form + "_fails_before_hooks_and_managed_writes"
    )


def run_regressions(fixture):
    with tempfile.TemporaryDirectory(
        prefix="build-setting-expressions-", dir=fixture.root
    ) as temporary:
        parent = Path(temporary)
        for form in FORMS:
            case(fixture, parent, form)
        recorded_expressions(fixture, parent)
        filtered_literal_resources(fixture, parent)
        for form in ["cycle", "unterminated"]:
            rejecting_expression(fixture, parent, form)
        # The original case has been deintegrated; create a fresh layout for moving.
        relocation = parent / "relocation"
        relocation.mkdir()
        relocated_literal(fixture, relocation)
