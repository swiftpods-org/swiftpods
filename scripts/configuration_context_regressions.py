"""Configuration reference scopes and universal conditions match actual Xcode."""

import json
import platform
import shutil
import tempfile
from pathlib import Path

from native_integration import serialize
from native_xcconfig_tests import create
from processes import run_captured
from project_path_regressions import reinstall
from vendor_fixture import fixture_build_arguments, fixture_derived_data, run
from workspace_resource_regressions import read_project

REFERENCE_FORMS = [
    "project-pbx",
    "project-xcconfig",
    "project-chain",
    "project-condition",
    "project-group",
    "project-override-target",
    "project-dir",
    "project-srcroot",
    "project-target-name",
    "target-name",
    "project-configuration",
    "sdk-scope",
]
SDK_FORMS = [
    "mac",
    "empty",
    "omitted",
    "auto",
    "late-auto",
    "unknown",
    "missing",
    "bare",
    "direct-empty",
    "direct-auto",
    "project-auto",
    "target-empty",
    "late-empty",
]
BUILDABLE_SDK_FORMS = {
    "mac",
    "empty",
    "omitted",
    "direct-empty",
    "target-empty",
    "late-empty",
}
KEYS = [
    "CONTEXT_VALUE",
    "UNIVERSAL",
    "SDK_MATCH",
    "SDK_NONUNIVERSAL",
    "UNKNOWN_UNIVERSAL",
    "UNKNOWN_LITERAL",
]
EXPECTED_OUTPUT = "value=7 user=1 conditional=1 context=7 sdk=7 unknown=7"


def configurations(graph):
    project, target = [], []
    for obj in graph["objects"].values():
        if obj.get("isa") == "XCBuildConfiguration":
            (target if obj["buildSettings"].get("PRODUCT_NAME") else project).append(
                obj
            )
    return project, target


def save(selected, graph):
    (selected / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(graph))


def prepare(parent):
    work, selected = create(parent)
    base = selected.parent / "Configs/Base.xcconfig"
    base.write_text(
        base.read_text()
        + "\nCONTEXT_VALUE = 7\nUNIVERSAL[sdk=*] = 7\nSDK_MATCH[sdk=macosx*] = 7\nSDK_NONUNIVERSAL[sdk=**] = 7\nUNKNOWN_UNIVERSAL[flavor=*] = 7\nUNKNOWN_LITERAL[flavor=vanilla] = wrong\n"
    )
    return work, selected


def hook(work, *, implicit=False, custom_configuration=False):
    podfile = work / "Podfile"
    text = podfile.read_text()
    if implicit:
        text = text.replace("platform :osx, '13.0'\n", "")
    text = text[: text.index("post_install do |i|")]
    podfile.write_text(
        text
        + """post_install do |i|
 t = i.aggregate_targets.first.user_targets.first
 values = %w[CONTEXT_VALUE UNIVERSAL SDK_MATCH SDK_NONUNIVERSAL UNKNOWN_UNIVERSAL UNKNOWN_LITERAL SDKROOT TARGET_NAME CONFIGURATION].to_h { |key| [key, t.resolved_build_setting(key, true)] }
 File.write('context-values.json', JSON.generate(values))
 t.build_configurations.each do |c|
   c.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] = ['$(inherited)', 'NATIVE_CONTEXT_VALUE=' + values['CONTEXT_VALUE'].fetch(c.name, '0'), 'NATIVE_SDK_VALUE=' + values['SDK_MATCH'].fetch(c.name, '0'), 'NATIVE_UNKNOWN_VALUE=' + values['UNKNOWN_UNIVERSAL'].fetch(c.name, '0')]
 end
end
"""
    )
    if custom_configuration:
        # Keep the application's custom product directory aligned with its libraries.
        podfile.write_text(
            podfile.read_text().replace(
                "post_install do |i|\n",
                "post_install do |i|\n i.pods_project.build_configurations.each { |c| c.build_settings['CONFIGURATION'] = 'Custom' }\n",
            )
        )


def consumer_source(path):
    path.write_text(
        path.read_text()
        .replace("conditional=%d\\n", "conditional=%d context=%d sdk=%d unknown=%d\\n")
        .replace(
            "CONDITIONAL_CONFIG);",
            "CONDITIONAL_CONFIG, NATIVE_CONTEXT_VALUE, NATIVE_SDK_VALUE, NATIVE_UNKNOWN_VALUE);",
        )
    )


def consumers(fixture, work, label):
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
        # A project CONFIGURATION override can change the product folder's name.
        products = fixture_derived_data(build) / "Build/Products"
        binaries = list(products.glob("*/Demo.app/Contents/MacOS/Demo"))
        assert len(binaries) == 1, binaries
        output = fixture.root / (name + "-run.log")
        run([binaries[0]], work, output, env=fixture.env)
        assert output.read_text().strip() == EXPECTED_OUTPUT, output


def compare(fixture, work, selected, label, values, *, available=True):
    observations = {}
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
        output = result.stdout + result.stderr
        assert (
            result.returncode == 0
            and " warning:" not in output
            and "\nwarning:" not in output
        ), prefix
        reference = next(
            row["buildSettings"]
            for row in json.loads(result.stdout)
            if row["target"] == "Demo"
        )
        expected = {
            key: reference.get(key) for key in KEYS + ["TARGET_NAME", "CONFIGURATION"]
        }
        native = {key: values[key].get(configuration) for key in expected}
        assert native == expected, (label, configuration, native, expected)
        assert (
            native["CONTEXT_VALUE"]
            == native["UNIVERSAL"]
            == native["UNKNOWN_UNIVERSAL"]
            == "7"
        )
        assert (
            native["SDK_MATCH"]
            == native["SDK_NONUNIVERSAL"]
            == ("7" if available else None)
        )
        assert native["UNKNOWN_LITERAL"] is None
        observations[configuration] = {
            **expected,
            "SDK_NAME": reference.get("SDK_NAME"),
        }
    (fixture.root / (label + "-comparison.json")).write_text(
        json.dumps(observations, indent=2) + "\n"
    )


def reference_case(fixture, parent, form):
    label = "config-context-ref-" + form
    work, selected = prepare(parent / label)
    graph = read_project(selected)
    project, targets = configurations(graph)
    base = selected.parent / "Configs/Base.xcconfig"
    custom = selected.parent.parent / "Override"
    custom.mkdir()
    for name in ["Configs", "Sources"]:
        shutil.copytree(selected.parent / name, custom / name)
    copied = custom / "Configs/Base.xcconfig"
    copied.write_text(
        copied.read_text().replace("CONTEXT_VALUE = 7", "CONTEXT_VALUE = 99")
    )
    for obj in project:
        settings = obj["buildSettings"]
        settings["CONFIG_FOLDER"] = "$(PROJECT_DIR)/Configs"
        if form == "project-chain":
            settings.update(
                CONFIG_ANCHOR="${PROJECT_DIR}", CONFIG_FOLDER="$(CONFIG_ANCHOR)/Configs"
            )
        if form == "project-condition":
            settings.pop("CONFIG_FOLDER")
            settings["CONFIG_FOLDER[config=" + obj["name"] + "]"] = (
                "$(PROJECT_DIR)/Configs"
            )
        if form == "project-xcconfig":
            settings.pop("CONFIG_FOLDER")
            reference = "F00000000000000000000011"
            graph["objects"][reference] = {
                "isa": "PBXFileReference",
                "path": "Project.xcconfig",
                "sourceTree": "SOURCE_ROOT",
                "lastKnownFileType": "text.xcconfig",
            }
            obj["baseConfigurationReference"] = reference
            (selected.parent / "Project.xcconfig").write_text(
                "CONFIG_FOLDER = $(PROJECT_DIR)/Configs\n"
            )
        if form == "project-dir":
            settings["PROJECT_DIR"] = str(custom)
        if form == "project-srcroot":
            settings["SRCROOT"] = str(custom)
            settings["CONFIG_FOLDER"] = "$(SOURCE_ROOT)/Configs"
        if form == "project-target-name":
            settings["TARGET_NAME"] = "Different"
            settings["TARGET_NAME[config=*]"] = "ConditionalDifferent"
        if form == "project-configuration":
            settings["CONFIGURATION"] = "Custom"
        if form == "sdk-scope":
            settings.update(
                SDKROOT="iphoneos",
                **{
                    "CONFIG_FOLDER[sdk=macosx*]": "$(PROJECT_DIR)/Configs",
                    "CONFIG_FOLDER[sdk=iphoneos*]": str(custom / "Configs"),
                },
            )
            settings.pop("CONFIG_FOLDER")
    for obj in targets:
        settings = obj["buildSettings"]
        if form == "project-override-target":
            settings["CONFIG_FOLDER"] = str(custom / "Configs")
        if form == "target-name":
            settings["TARGET_NAME"] = "Different"
        if form == "sdk-scope":
            settings["SDKROOT"] = "macosx"
    if form in ["project-dir", "project-srcroot"]:
        copied.write_text(
            copied.read_text().replace("CONTEXT_VALUE = 99", "CONTEXT_VALUE = 7")
        )
        base.write_text(
            base.read_text().replace("CONTEXT_VALUE = 7", "CONTEXT_VALUE = 99")
        )
    if form in ["project-target-name", "target-name"]:
        destination = base.parent / "Demo"
        destination.mkdir()
        for name in ["Base.xcconfig", "Debug.xcconfig", "Release.xcconfig"]:
            (destination / name).write_text(
                (base.parent / name)
                .read_text()
                .replace('"../../work/', '"../../../work/')
            )
    if form == "project-configuration":
        (base.parent / "Custom.xcconfig").write_text(
            (base.parent / "Debug.xcconfig")
            .read_text()
            .replace("[config=Debug]", "[config=*]")
        )
    for obj in graph["objects"].values():
        if obj.get("isa") == "PBXFileReference" and obj.get("path") in [
            "Debug.xcconfig",
            "Release.xcconfig",
        ]:
            filename = (
                "${CONFIGURATION}.xcconfig"
                if form == "project-configuration"
                else obj["path"]
            )
            obj.update(
                path="${CONFIG_FOLDER}/"
                + (
                    "$(TARGET_NAME)/"
                    if form in ["project-target-name", "target-name"]
                    else ""
                )
                + filename,
                sourceTree="<absolute>",
            )
        if (
            form == "project-group"
            and obj.get("isa") == "PBXGroup"
            and obj.get("path") == "Configs"
        ):
            obj.update(path="$(CONFIG_FOLDER)", sourceTree="<absolute>")
    if form == "project-group":
        for obj in graph["objects"].values():
            if obj.get("isa") == "PBXFileReference" and obj.get("path", "").endswith(
                ("Debug.xcconfig", "Release.xcconfig")
            ):
                obj.update(path=Path(obj["path"]).name, sourceTree="<group>")
    save(selected, graph)
    hook(work, implicit=True, custom_configuration=form == "project-configuration")
    fixture.cli(work, "install")
    values = json.loads((work / "context-values.json").read_text())
    (fixture.root / (label + "-native.json")).write_text(
        json.dumps(values, indent=2) + "\n"
    )
    compare(fixture, work, selected, label, values)
    fixture.verified.append(label + "_project_reference_scope_matches_Xcode")
    expected_name = "Different" if form == "target-name" else "Demo"
    assert values["TARGET_NAME"] == {c: expected_name for c in ["Debug", "Release"]}
    assert values["CONFIGURATION"] == {
        c: "Custom" if form == "project-configuration" else c
        for c in ["Debug", "Release"]
    }
    fixture.verified.append(
        label + "_target_defaults_and_overrides_have_separate_scopes"
    )
    fixture.cli(selected.parent, "init")
    initialized = (selected.parent / "Podfile").read_text()
    assert "platform :osx, '13.0'" in initialized
    (fixture.root / (label + "-init.txt")).write_text(initialized)
    fixture.verified.append(label + "_implicit_install_and_init_read_the_selected_file")
    reinstall(fixture, work, selected)
    assert json.loads((work / "context-values.json").read_text()) == values
    fixture.verified.append(
        label + "_offline_deployment_preserves_graph_lock_and_settings"
    )
    source = (custom if form == "project-dir" else selected.parent) / "Sources/main.mm"
    consumer_source(source)
    consumers(fixture, work, label)
    fixture.verified.append(label + "_hook_values_execute_in_Debug_Release")


def sdk_case(fixture, parent, form):
    label = "config-context-sdk-" + form
    work, selected = prepare(parent / label)
    graph = read_project(selected)
    project, targets = configurations(graph)
    base = selected.parent / "Configs/Base.xcconfig"
    raw = {
        "mac": "macosx",
        "empty": "",
        "omitted": None,
        "auto": "auto",
        "late-auto": "auto",
        "unknown": "$(MISSING_SDK)/MacOSX.sdk",
        "missing": str(selected.parent / "Absent/MacOSX.sdk"),
        "bare": "SwiftPodsMissingSDK",
        "direct-empty": "",
        "direct-auto": "auto",
        "project-auto": "auto",
        "target-empty": "",
        "late-empty": "",
    }[form]
    text = base.read_text().replace("SDKROOT = macosx\n", "")
    if form not in [
        "omitted",
        "direct-empty",
        "direct-auto",
        "project-auto",
        "target-empty",
    ]:
        text = (
            text + "SDKROOT = " + raw + "\n"
            if form.startswith("late-")
            else "SDKROOT = " + raw + "\n" + text
        )
    if form in ["project-auto", "target-empty"]:
        for obj in project:
            obj["buildSettings"].update(
                SDKROOT="macosx" if form == "project-auto" else "iphoneos",
                **{"WRONG_PROJECT[sdk=iphoneos*]": "wrong"},
            )
    if form in ["direct-empty", "direct-auto", "project-auto", "target-empty"]:
        for obj in targets:
            obj["buildSettings"]["SDKROOT"] = raw
    base.write_text(text)
    save(selected, graph)
    hook(work)
    fixture.cli(work, "install")
    values = json.loads((work / "context-values.json").read_text())
    (fixture.root / (label + "-native.json")).write_text(
        json.dumps(values, indent=2) + "\n"
    )
    compare(
        fixture, work, selected, label, values, available=form in BUILDABLE_SDK_FORMS
    )
    fixture.verified.append(label + "_universal_and_SDK_conditions_match_Xcode")
    assert values["SDKROOT"] == (
        {} if raw is None else {c: raw for c in ["Debug", "Release"]}
    )
    fixture.verified.append(label + "_declared_SDKROOT_is_preserved")
    reinstall(fixture, work, selected)
    assert json.loads((work / "context-values.json").read_text()) == values
    fixture.verified.append(label + "_offline_deployment_preserves_settings")
    if form in BUILDABLE_SDK_FORMS:
        consumer_source(selected.parent / "Sources/main.mm")
        consumers(fixture, work, label)
        fixture.verified.append(
            label + "_default_and_universal_values_execute_in_Debug_Release"
        )


def rejection(fixture, parent, form):
    work, selected = prepare(parent / ("config-context-reject-" + form))
    graph = read_project(selected)
    project, targets = configurations(graph)
    for obj in targets if form == "target-only" else project:
        obj["buildSettings"]["CONFIG_FOLDER"] = (
            "$(PROJECT_DIR)/Configs" if form != "cycle" else "$(CONFIG_FOLDER)"
        )
    if form == "project-self":
        reference = "F00000000000000000000011"
        graph["objects"][reference] = {
            "isa": "PBXFileReference",
            "path": "$(CONFIG_FOLDER)/Base.xcconfig",
            "sourceTree": "<absolute>",
        }
        for obj in project:
            obj["baseConfigurationReference"] = reference
    else:
        for obj in graph["objects"].values():
            if obj.get("isa") == "PBXFileReference" and obj.get("path") in [
                "Debug.xcconfig",
                "Release.xcconfig",
            ]:
                obj.update(
                    path="$(CONFIG_FOLDER)/" + obj["path"], sourceTree="<absolute>"
                )
    save(selected, graph)
    podfile = work / "Podfile"
    podfile.write_text(
        podfile.read_text()
        + "pre_install { |_| File.write('context-hook-ran', 'yes') }\n"
    )
    original = (selected / "project.pbxproj").read_bytes()
    result = fixture.cli(work, "install", succeeds=False)
    code = "SP-XCCONFIG-CYCLE" if form == "cycle" else "SP-NATIVE-ERROR"
    assert any(event.get("code") == code for event in result["events"]), result
    assert (selected / "project.pbxproj").read_bytes() == original
    assert not any(
        (work / path).exists()
        for path in [
            "context-hook-ran",
            "Pods",
            "Podfile.lock",
            "resolved-settings.json",
        ]
    )
    fixture.verified.append(
        "config_context_" + form + "_fails_before_hooks_and_managed_writes"
    )


def run_regressions(fixture):
    with tempfile.TemporaryDirectory(
        prefix="configuration-context-", dir=fixture.root
    ) as temporary:
        parent = Path(temporary)
        for form in REFERENCE_FORMS:
            reference_case(fixture, parent, form)
        for form in SDK_FORMS:
            sdk_case(fixture, parent, form)
        for form in ["target-only", "project-self", "cycle"]:
            rejection(fixture, parent, form)
