"""Project variables and relative SDK paths agree with the selected Xcode project."""

import json
import shutil
import subprocess
import tempfile
from pathlib import Path

from native_integration import serialize
from native_xcconfig_tests import create
from processes import run_captured
from project_path_regressions import builds, reinstall
from workspace_resource_regressions import read_project

VARIABLES = [
    "SRCROOT",
    "SOURCE_ROOT",
    "PROJECT_DIR",
    "PROJECT_NAME",
    "PROJECT_FILE_PATH",
    "CONFIGURATION",
    "TARGET_NAME",
]
FORMS = [
    "srcroot",
    "source-braces",
    "project-dir",
    "project-name",
    "project-file",
    "target-config",
    "relative-dot",
    "relative-bare",
    "redirected",
    "override-project-dir",
    "override-relative",
    "override-srcroot",
    "project-layer",
    "pbx-direct",
    "late-include",
    "ref-project-braces",
    "ref-source-root",
    "ref-project-name",
    "ref-configuration",
    "ref-target",
]


def sdk_path(fixture, name):
    return Path(
        subprocess.check_output(
            ["/usr/bin/xcrun", "--sdk", name, "--show-sdk-path"],
            env=fixture.env,
            text=True,
        ).strip()
    )


def configure(work, selected, form, sdk, other):
    graph = read_project(selected)
    app = selected.parent
    source = app
    if form == "redirected":
        source = app.parent / "\u0301Source%2FRoot"
        source.mkdir()
        for name in ["Configs", "Sources"]:
            shutil.copytree(app / name, source / name)
        graph["objects"][graph["rootObject"]]["projectDirPath"] = "../" + source.name
    custom = app.parent / "Custom"
    custom.mkdir()
    for directory in [source, custom]:
        for name in [
            "SelectedSDK.sdk",
            "External.sdk",
            "Demo-Debug.sdk",
            "Demo-Release.sdk",
        ]:
            (directory / name).symlink_to(sdk, target_is_directory=True)
    # A conflicting cwd alias must not affect a project-relative SDK.
    (work / "SelectedSDK.sdk").symlink_to(other, target_is_directory=True)
    raw = {
        "srcroot": "$(SRCROOT)/SelectedSDK.sdk",
        "source-braces": "${SOURCE_ROOT}/SelectedSDK.sdk",
        "project-dir": "$(PROJECT_DIR)/SelectedSDK.sdk",
        "project-name": "$(PROJECT_DIR)/$(PROJECT_NAME).sdk",
        "project-file": "$(PROJECT_FILE_PATH)/../SelectedSDK.sdk",
        "target-config": "$(PROJECT_DIR)/$(TARGET_NAME)-$(CONFIGURATION).sdk",
        "relative-dot": "./SelectedSDK.sdk",
        "relative-bare": "SelectedSDK.sdk",
        "redirected": "$(SOURCE_ROOT)/SelectedSDK.sdk",
        "override-project-dir": "$(PROJECT_DIR)/SelectedSDK.sdk",
        "override-relative": "SelectedSDK.sdk",
        "override-srcroot": "$(SOURCE_ROOT)/SelectedSDK.sdk",
        "project-layer": "$(PROJECT_DIR)/SelectedSDK.sdk",
        "pbx-direct": "$(SRCROOT)/SelectedSDK.sdk",
        "late-include": "$(SDK_CHOICE)",
        **{name: "macosx" for name in FORMS if name.startswith("ref-")},
    }[form]
    if form == "override-relative":
        (custom / "SelectedSDK.sdk").unlink()
        (custom / "SelectedSDK.sdk").symlink_to(other, target_is_directory=True)
    for obj in graph["objects"].values():
        if obj.get("isa") != "XCBuildConfiguration":
            continue
        values = obj["buildSettings"]
        target = bool(values.get("PRODUCT_NAME"))
        if target and form in ["override-project-dir", "override-relative"]:
            values["PROJECT_DIR"] = str(custom)
        if target and form == "override-srcroot":
            values["SRCROOT"] = str(custom)
        if form == "pbx-direct" and target or form == "project-layer" and not target:
            values["SDKROOT"] = raw
    base = source / "Configs/Base.xcconfig"
    text = base.read_text().replace("SDKROOT = macosx", "SDKROOT = " + raw)
    if form in ["project-layer", "pbx-direct"]:
        text = text.replace("SDKROOT = " + raw + "\n", "")
    if form == "late-include":
        (base.parent / "SDK.xcconfig").write_text(
            "SDK_CHOICE = $(PROJECT_DIR)/SelectedSDK.sdk\n"
        )
        text += '#include "SDK.xcconfig"\n'
    canonical = json.loads((sdk / "SDKSettings.json").read_text())["CanonicalName"]
    text += (
        "\nSDK_VALUE[sdk=" + canonical + "] = 7\nSDK_UNVERSIONED[sdk=macosx] = wrong\n"
    )
    base.write_text(text)
    if form in ["override-srcroot", "override-project-dir", "override-relative"]:
        for name in ["Configs", "Sources"]:
            shutil.copytree(source / name, custom / name)
    if form.startswith("ref-"):
        folder = None
        if form in ["ref-project-name", "ref-target"]:
            folder = "External" if form == "ref-project-name" else "Demo"
            destination = base.parent / folder
            destination.mkdir()
            for name in ["Base.xcconfig", "Debug.xcconfig", "Release.xcconfig"]:
                content = (
                    (base.parent / name)
                    .read_text()
                    .replace('"../../work/', '"../../../work/')
                )
                (destination / name).write_text(content)
        for obj in graph["objects"].values():
            if obj.get("isa") != "PBXFileReference" or obj.get("path") not in [
                "Debug.xcconfig",
                "Release.xcconfig",
            ]:
                continue
            filename = obj["path"]
            if form == "ref-project-braces":
                reference = "${PROJECT_DIR}/Configs/" + filename
            elif form == "ref-source-root":
                reference = "$(SOURCE_ROOT)/Configs/" + filename
            elif form == "ref-project-name":
                reference = "$(PROJECT_DIR)/Configs/$(PROJECT_NAME)/" + filename
            elif form == "ref-target":
                reference = "$(PROJECT_DIR)/Configs/$(TARGET_NAME)/" + filename
            else:
                reference = "$(PROJECT_DIR)/Configs/${CONFIGURATION}.xcconfig"
            obj.update(path=reference, sourceTree="<absolute>")
    (selected / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(graph))
    return source, raw


def hook(work, implicit=True):
    podfile = work / "Podfile"
    text = podfile.read_text()
    if implicit:
        text = text.replace("platform :osx, '13.0'\n", "")
    text = text[: text.index("post_install do |i|")]
    text += """post_install do |i|
 t = i.aggregate_targets.first.user_targets.first
 values = %w[SRCROOT SOURCE_ROOT PROJECT_DIR PROJECT_NAME PROJECT_FILE_PATH CONFIGURATION TARGET_NAME SDKROOT SDK_VALUE SDK_UNVERSIONED].to_h { |key| [key, t.resolved_build_setting(key, true)] }
 File.write('project-values.json', JSON.generate(values))
 t.build_configurations.each do |c|
   c.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] = ['$(inherited)', 'PROJECT_SDK_VALUE=' + values['SDK_VALUE'].fetch(c.name, '0').to_s]
 end
end
"""
    podfile.write_text(text)


def compare(fixture, work, selected, label, native, expected="7"):
    rows = {}
    for configuration in ["Debug", "Release"]:
        prefix = fixture.root / (label + "-" + configuration + "-settings")
        result = run_captured(
            [
                "xcodebuild",
                "-project",
                selected,
                "-target",
                "Demo",
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
        text = result.stdout + result.stderr
        assert (
            result.returncode == 0
            and " warning:" not in text
            and "\nwarning:" not in text
        ), prefix
        values = next(
            row["buildSettings"]
            for row in json.loads(result.stdout)
            if row["target"] == "Demo"
        )
        keys = [*VARIABLES, "SDK_VALUE", "SDK_UNVERSIONED"]
        reference = {key: values.get(key) for key in keys}
        actual = {key: native[key].get(configuration) for key in keys}
        assert actual == reference, (label, configuration, actual, reference)
        assert actual["SDK_VALUE"] == expected and actual["SDK_UNVERSIONED"] is None
        rows[configuration] = {**reference, "SDK_NAME": values.get("SDK_NAME")}
    (fixture.root / (label + "-comparison.json")).write_text(
        json.dumps(rows, indent=2) + "\n"
    )


def positive(fixture, parent, form, sdk, other):
    label = "project-var-" + form
    work, selected = create(parent / label)
    _source, raw = configure(work, selected, form, sdk, other)
    hook(work)
    fixture.cli(work, "install")
    values = json.loads((work / "project-values.json").read_text())
    (fixture.root / (label + "-native.json")).write_text(
        json.dumps(values, indent=2) + "\n"
    )
    compare(fixture, work, selected, label, values)
    fixture.verified.append(label + "_project_variables_match_Xcode_in_Debug_Release")
    assert values["SDKROOT"] == {"Debug": raw, "Release": raw}
    fixture.verified.append(
        label + "_SDK_condition_uses_expansion_without_rewriting_declaration"
    )
    fixture.cli(selected.parent, "init")
    initialized = (selected.parent / "Podfile").read_text()
    assert "platform :osx, '13.0'" in initialized
    (fixture.root / (label + "-init.txt")).write_text(initialized)
    fixture.verified.append(label + "_install_and_init_infer_platform_from_SDK")
    reinstall(fixture, work, selected)
    assert json.loads((work / "project-values.json").read_text()) == values
    fixture.verified.append(
        label + "_offline_deployment_preserves_graph_lock_and_values"
    )
    source = selected.parent / "Sources/main.mm"
    if form == "redirected":
        source = selected.parent.parent / "\u0301Source%2FRoot/Sources/main.mm"
    elif form in ["override-project-dir", "override-relative"]:
        source = selected.parent.parent / "Custom/Sources/main.mm"
    source.write_text(
        source.read_text()
        .replace("conditional=%d\\n", "conditional=%d project_sdk=%d\\n")
        .replace("CONDITIONAL_CONFIG);", "CONDITIONAL_CONFIG, PROJECT_SDK_VALUE);")
    )
    builds(fixture, work, label)
    for configuration in ["Debug", "Release"]:
        log = fixture.root / (label + "-" + configuration + "-run.log")
        assert (
            log.read_text().strip() == "value=7 user=1 conditional=1 project_sdk=7"
        ), log
    fixture.verified.append(label + "_hook_value_executes_as_7_in_Debug_Release")


def unavailable(fixture, parent, kind):
    label = "project-var-unavailable-" + kind
    work, selected = create(parent / label)
    raw = (
        "$(MISSING_SDK_DIRECTORY)/MacOSX.sdk"
        if kind == "unknown"
        else str(selected.parent / "Absent/MacOSX.sdk")
    )
    base = selected.parent / "Configs/Base.xcconfig"
    base.write_text(
        base.read_text().replace("SDKROOT = macosx", "SDKROOT = " + raw)
        + "\nSDK_VALUE[sdk=macosx*] = wrong\nSDK_UNVERSIONED[sdk=macosx] = wrong\n"
    )
    hook(work, implicit=False)
    fixture.cli(work, "install")
    values = json.loads((work / "project-values.json").read_text())
    compare(fixture, work, selected, label, values, expected=None)
    assert values["SDKROOT"] == {"Debug": raw, "Release": raw}
    fixture.verified.append(label + "_does_not_match_SDK_conditions_by_basename")


def early_rejection(fixture, parent):
    work, selected = create(parent / "project-var-unresolved-platform")
    base = selected.parent / "Configs/Base.xcconfig"
    base.write_text(
        base.read_text().replace(
            "SDKROOT = macosx", "SDKROOT = $(MISSING_SDK_DIRECTORY)/MacOSX.sdk"
        )
    )
    podfile = work / "Podfile"
    podfile.write_text(
        podfile.read_text().replace("platform :osx, '13.0'\n", "")
        + "pre_install { |_| File.write('project-hook-ran', 'yes') }\n"
    )
    project = selected / "project.pbxproj"
    original = project.read_bytes()
    result = fixture.cli(work, "install", succeeds=False)
    assert any(e.get("code") == "SP-PLATFORM-MISSING" for e in result["events"])
    assert (
        project.read_bytes() == original
        and not (work / "Pods").exists()
        and not (work / "Podfile.lock").exists()
    )
    assert not (work / "project-hook-ran").exists()
    fixture.verified.append(
        "project_var_unresolved_SDK_rejected_before_hook_and_managed_writes"
    )


def run_regressions(fixture):
    sdk, other = sdk_path(fixture, "macosx"), sdk_path(fixture, "iphoneos")
    with tempfile.TemporaryDirectory(
        prefix="project-variables-", dir=fixture.root
    ) as temporary:
        parent = Path(temporary)
        for form in FORMS:
            positive(fixture, parent, form, sdk, other)
        for kind in ["unknown", "missing"]:
            unavailable(fixture, parent, kind)
        early_rejection(fixture, parent)
