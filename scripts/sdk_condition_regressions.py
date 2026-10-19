"""SDK conditions use the selected bundle identity in native and Xcode settings."""

import json
import subprocess
import tempfile
from pathlib import Path

from native_integration import serialize
from native_xcconfig_tests import create
from project_path_regressions import builds, reinstall
from workspace_resource_regressions import read_project

PLATFORMS = [
    ("macosx", "osx", "MACOSX_DEPLOYMENT_TARGET", "macOS"),
    ("iphoneos", "ios", "IPHONEOS_DEPLOYMENT_TARGET", "iOS"),
    ("iphonesimulator", "ios", "IPHONEOS_DEPLOYMENT_TARGET", "iOS Simulator"),
    ("appletvos", "tvos", "TVOS_DEPLOYMENT_TARGET", "tvOS"),
    ("appletvsimulator", "tvos", "TVOS_DEPLOYMENT_TARGET", "tvOS Simulator"),
    ("watchos", "watchos", "WATCHOS_DEPLOYMENT_TARGET", "watchOS"),
    ("watchsimulator", "watchos", "WATCHOS_DEPLOYMENT_TARGET", "watchOS Simulator"),
    ("xros", "visionos", "XROS_DEPLOYMENT_TARGET", "visionOS"),
    ("xrsimulator", "visionos", "XROS_DEPLOYMENT_TARGET", "visionOS Simulator"),
]
KEYS = ["SDK_VALUE", "SDK_UNVERSIONED", "SDK_WILDCARD", "SDK_MIXED", "SDK_WRONG"]


def selected_sdk(fixture, name):
    result = subprocess.run(
        ["/usr/bin/xcrun", "--sdk", name, "--show-sdk-path"],
        env=fixture.env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stderr
    path = Path(result.stdout.strip())
    metadata = json.loads((path / "SDKSettings.json").read_text())
    return path, metadata["CanonicalName"], metadata["Version"]


def hook(work):
    podfile = work / "Podfile"
    original = podfile.read_text()
    end = original.index("post_install do |i|")
    podfile.write_text(
        original[:end]
        + """post_install do |i|
 t = i.aggregate_targets.find { |v| v.name == 'Pods-Demo' }.user_targets.first
 values = %w[SDK_VALUE SDK_UNVERSIONED SDK_WILDCARD SDK_MIXED SDK_WRONG SDKROOT].to_h { |key| [key, t.resolved_build_setting(key, true)] }
 File.write('sdk-values.json', JSON.generate(values))
 t.build_configurations.each do |c|
   c.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] = ['$(inherited)', 'NATIVE_SDK_VALUE=' + values['SDK_VALUE'].fetch(c.name, '0').to_s]
 end
end
"""
    )


def reference(fixture, work, selected, label, native, canonical):
    observations = {}
    for configuration in ["Debug", "Release"]:
        log = fixture.root / (label + "-" + configuration + "-settings.log")
        result = subprocess.run(
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
            cwd=work,
            env=fixture.env,
            capture_output=True,
            text=True,
            timeout=120,
        )
        text = result.stdout + result.stderr
        log.write_text(text)
        assert (
            result.returncode == 0
            and " warning:" not in text
            and "\nwarning:" not in text
        ), log
        settings = next(
            row["buildSettings"]
            for row in json.loads(result.stdout)
            if row["target"] == "Demo"
        )
        assert settings["SDK_NAME"] == canonical, log
        expected = {key: settings.get(key) for key in KEYS}
        actual = {key: native[key].get(configuration) for key in KEYS}
        assert actual == expected, (actual, expected, log)
        assert actual == {
            "SDK_VALUE": "7",
            "SDK_UNVERSIONED": None,
            "SDK_WILDCARD": "8",
            "SDK_MIXED": "9" if configuration == "Debug" else "10",
            "SDK_WRONG": None,
        }
        observations[configuration] = {"SDK_NAME": canonical, **expected}
    (fixture.root / (label + "-settings.json")).write_text(
        json.dumps(observations, indent=2) + "\n"
    )


def case(fixture, parent, sdk, form):
    name, platform_name, deployment_key, _destination = sdk
    path, canonical, version = selected_sdk(fixture, name)
    label = "sdk-condition-" + name + "-" + form
    work, selected = create(parent / label)
    if platform_name != "osx":
        graph = read_project(selected)
        for obj in graph["objects"].values():
            if obj.get("isa") == "PBXNativeTarget":
                obj["productType"] = "com.apple.product-type.library.static"
                product = graph["objects"][obj["productReference"]]
                product.update(path="libDemo.a", explicitFileType="archive.ar")
        (selected / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(graph))
    if form == "canonical":
        raw = canonical
    elif form == "absolute":
        raw = str(path)
    elif form == "physical":
        raw = str(path.resolve())
    elif form == "alias":
        alias = work / "\u0301SDK%2FAlias.sdk"
        alias.symlink_to(path, target_is_directory=True)
        raw = str(alias)
    elif form == "late-include":
        raw = "$(SELECTED_SDK)"
    else:
        raw = name
    minimum = "13.0" if platform_name == "osx" else version
    base = selected.parent / "Configs/Base.xcconfig"
    text = base.read_text().replace("SDKROOT = macosx", "SDKROOT = " + raw)
    if platform_name != "osx":
        text += "\n" + deployment_key + " = " + minimum + "\n"
    assignments = {
        "SDK_VALUE[sdk=" + canonical + "]": "7",
        "SDK_UNVERSIONED[sdk=" + name + "]": "wrong",
        "SDK_WILDCARD[sdk=" + name + "*]": "8",
        "SDK_MIXED[sdk=" + canonical + "][config=Debug]": "9",
        "SDK_MIXED[sdk=" + canonical + "][config=Release]": "10",
        "SDK_WRONG[sdk=" + canonical + "-unselected]": "wrong",
    }
    if form in ["pbx-direct", "target-override"]:
        graph = read_project(selected)
        for obj in graph["objects"].values():
            if obj.get("isa") != "XCBuildConfiguration":
                continue
            settings = obj["buildSettings"]
            if form == "pbx-direct" or not settings.get("PRODUCT_NAME"):
                settings.update(assignments)
            if form == "target-override":
                settings["SDKROOT"] = (
                    name if settings.get("PRODUCT_NAME") else "iphoneos"
                )
        (selected / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(graph))
        if form == "target-override":
            text = text.replace("SDKROOT = " + raw + "\n", "")
    else:
        text += (
            "\n"
            + "\n".join(key + " = " + value for key, value in assignments.items())
            + "\n"
        )
    if form == "late-include":
        (base.parent / "SDK.xcconfig").write_text("SELECTED_SDK = " + name + "\n")
        text += '#include "SDK.xcconfig"\n'
    base.write_text(text)
    specification = work / "Kit/Kit.podspec.json"
    spec = json.loads(specification.read_text())
    spec["platforms"] = {platform_name: minimum}
    specification.write_text(json.dumps(spec))
    podfile = work / "Podfile"
    podfile.write_text(podfile.read_text().replace("platform :osx, '13.0'\n", ""))
    hook(work)
    fixture.cli(work, "install")
    native = json.loads((work / "sdk-values.json").read_text())
    assert native["SDKROOT"] == {"Debug": raw, "Release": raw}
    (fixture.root / (label + "-native.json")).write_text(
        json.dumps(native, indent=2) + "\n"
    )
    reference(fixture, work, selected, label, native, canonical)
    fixture.verified.append(
        label + "_canonical_conditions_match_native_and_Xcode_Debug_Release"
    )
    fixture.cli(selected.parent, "init")
    initialized = (selected.parent / "Podfile").read_text()
    assert "platform :" + platform_name + ", '" + minimum + "'" in initialized
    (fixture.root / (label + "-init.txt")).write_text(initialized)
    fixture.verified.append(label + "_install_and_init_infer_the_selected_platform")
    lock = (work / "Podfile.lock").read_bytes()
    reinstall(fixture, work, selected)
    assert (work / "Podfile.lock").read_bytes() == lock
    assert json.loads((work / "sdk-values.json").read_text()) == native
    fixture.verified.append(
        label + "_offline_deployment_keeps_raw_SDKROOT_and_hook_values"
    )
    if platform_name == "osx":
        main = selected.parent / "Sources/main.mm"
        main.write_text(
            main.read_text()
            .replace("conditional=%d\\n", "conditional=%d sdkhook=%d\\n")
            .replace("CONDITIONAL_CONFIG);", "CONDITIONAL_CONFIG, NATIVE_SDK_VALUE);")
        )
        builds(fixture, work, label)
        for configuration in ["Debug", "Release"]:
            log = fixture.root / (label + "-" + configuration + "-run.log")
            assert (
                log.read_text().strip() == "value=7 user=1 conditional=1 sdkhook=7"
            ), log
        fixture.verified.append(label + "_hook_value_executes_as_7_in_Debug_Release")


def invalid_sdk(fixture, parent):
    work, selected = create(parent / "sdk-condition-unknown")
    base = selected.parent / "Configs/Base.xcconfig"
    base.write_text(
        base.read_text().replace(
            "SDKROOT = macosx", "SDKROOT = unrecognized_sdk_fixture"
        )
    )
    podfile = work / "Podfile"
    podfile.write_text(
        podfile.read_text().replace("platform :osx, '13.0'\n", "")
        + "pre_install { |_| File.write('sdk-hook-ran', 'yes') }\n"
    )
    project = selected / "project.pbxproj"
    original = project.read_bytes()
    result = fixture.cli(work, "install", succeeds=False)
    assert any(e.get("code") == "SP-PLATFORM-MISSING" for e in result["events"])
    assert project.read_bytes() == original
    assert not (work / "Pods").exists() and not (work / "Podfile.lock").exists()
    assert not (work / "sdk-hook-ran").exists()
    fixture.verified.append(
        "sdk_condition_unknown_identity_rejected_before_hook_and_managed_writes"
    )


def run_regressions(fixture):
    with tempfile.TemporaryDirectory(
        prefix="sdk-conditions-", dir=fixture.root
    ) as temporary:
        parent = Path(temporary)
        for form in [
            "symbolic",
            "canonical",
            "absolute",
            "physical",
            "alias",
            "late-include",
            "pbx-direct",
            "target-override",
        ]:
            case(fixture, parent, PLATFORMS[0], form)
        for sdk in PLATFORMS[1:]:
            case(fixture, parent, sdk, "symbolic")
        invalid_sdk(fixture, parent)
