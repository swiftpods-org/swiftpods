"""Installed Xcode declaration types and unambiguous generated configuration paths."""

import hashlib
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

from Tests.Integration.native_xcconfig_tests import create
from Tests.Regression.build_setting_expression_regressions import reference
from Tests.Regression.configuration_context_regressions import configurations, save
from Tests.Regression.project_path_regressions import assert_restored, builds, reinstall
from Tests.Regression.workspace_resource_regressions import read_project

SCALARS = [
    "PRODUCT_NAME",
    "EXECUTABLE_NAME",
    "SYMROOT",
    "OBJROOT",
    "INFOPLIST_FILE",
    "MODULEMAP_FILE",
    "CURRENT_PROJECT_VERSION",
    "GENERATE_INFOPLIST_FILE",
    "GCC_TREAT_WARNINGS_AS_ERRORS",
    "MACH_O_TYPE",
    "SWIFT_OPTIMIZATION_LEVEL",
    "CODE_SIGN_IDENTITY",
    "DEVELOPMENT_TEAM",
    "PROVISIONING_PROFILE_SPECIFIER",
    "TOOLCHAIN_DIR",
]
# These declarations vary between Xcode versions. Their installed Xcode output
# remains the oracle instead of assuming that every toolchain declares strings.
TOOLCHAIN_OPTIONS = [
    "LD_ADDRESS_SANITIZER",
    "LD_ADDRESS_SANITIZER_clang",
    "LD_ADDRESS_SANITIZER_swiftc",
    "LD_FUZZER",
    "LD_FUZZER_clang",
    "LD_FUZZER_swiftc",
    "LD_OBJC_RUNTIME_ARGS",
    "LD_OBJC_RUNTIME_ARGS_clang",
    "LD_OBJC_RUNTIME_ARGS_swiftc",
]
LISTS = ["CUSTOM_SDK_CHOICE", "HEADER_SEARCH_PATHS"]
ARRAYS = ["PRODUCT_NAME", "CUSTOM_SDK_CHOICE", "HEADER_SEARCH_PATHS", "SDKROOT"]
BUILD_KEYS = {"CODE_SIGN_IDENTITY", "DEVELOPMENT_TEAM"}


def hook(work):
    podfile = work / "Podfile"
    code = podfile.read_text().split("post_install do |i|", 1)[0]
    podfile.write_text(code + """pre_install { |_| File.write('typed-pre-hook', 'ran') }
post_install do |i|
 t=i.aggregate_targets.first.user_targets.first
 values=%w[SDKROOT SDK_VALUE FILE_SENTINEL].to_h { |key| [key,t.resolved_build_setting(key,true)] }
 File.write('typed-values.json',JSON.generate(values))
 File.write('../Apps/Sources/Typed.h', '#define TYPE_SELECTION ' + values['SDK_VALUE'].values.first.to_i.to_s + 10.chr)
end
""")
    source = work.parent / "Apps/Sources/main.mm"
    source.write_text(
        '#include "Typed.h"\n#if TYPE_SELECTION != 7\n#error Incorrect typed SDK selection\n#endif\n'
        + source.read_text()
        .replace("conditional=%d\\n", "conditional=%d typed=%d\\n")
        .replace(
            "USER_CONFIG, CONDITIONAL_CONFIG);",
            "USER_CONFIG, CONDITIONAL_CONFIG, TYPE_SELECTION);",
        )
    )


def compare(fixture, work, selected, label, available):
    values = json.loads((work / "typed-values.json").read_text())
    rows = {}
    for configuration in ["Debug", "Release"]:
        expected = reference(fixture, work, selected, "Demo", configuration, label)
        actual = {
            key: values[key].get(configuration)
            for key in ["SDK_VALUE", "FILE_SENTINEL"]
        }
        assert actual == {key: expected.get(key) for key in actual}, (
            label,
            configuration,
            actual,
            expected,
        )
        assert actual["FILE_SENTINEL"] == "17"
        if available is None:
            assert actual["SDK_VALUE"] in {"7", None}
        else:
            assert actual["SDK_VALUE"] == ("7" if available else None)
        rows[configuration] = {
            **actual,
            "SDKROOT": expected.get("SDKROOT"),
            "SDK_NAME": expected.get("SDK_NAME"),
        }
    (fixture.root / (label + "-comparison.json")).write_text(
        json.dumps(rows, indent=2) + "\n"
    )


def sdk_types(fixture, parent):
    sdk = Path(
        subprocess.check_output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
        ).strip()
    )
    for array in [False, True]:
        for key in ARRAYS if array else SCALARS + LISTS + TOOLCHAIN_OPTIONS:
            label = "typed-" + ("array-" if array else "scalar-") + key
            work, selected = create(parent / label)
            graph = read_project(selected)
            original = read_project(selected)
            _, targets = configurations(graph)
            alias = selected.parent / ("SDK Root.sdk" if array else r"SDK\Selected.sdk")
            alias.symlink_to(sdk, target_is_directory=True)
            base = selected.parent / "Configs/Base.xcconfig"
            base.write_text(
                base.read_text().replace(
                    "SDKROOT = macosx", "SDKROOT = $(PROJECT_DIR)/$(" + key + ").sdk"
                )
                + "\nSUFFIX = Selected\nSDK_VALUE[sdk=macosx*] = 7\nFILE_SENTINEL = 17\n"
            )
            for config in targets:
                config["buildSettings"][key] = (
                    (
                        ["$(PROJECT_DIR)/SDK Root.sdk"]
                        if key == "SDKROOT"
                        else ["SDK Root"]
                    )
                    if array
                    else r"SDK\$(SUFFIX)"
                )
            save(selected, graph)
            original = read_project(selected)
            hook(work)
            fixture.cli(work, "install")
            available = None if key in TOOLCHAIN_OPTIONS else array or key in SCALARS
            compare(fixture, work, selected, label, available)
            fixture.verified.append(label + "_matches_Xcode_Debug_Release")
            reinstall(fixture, work, selected)
            fixture.verified.append(label + "_offline_reinstall_is_stable")
            if not array and key in BUILD_KEYS:
                builds(fixture, work, label)
                for config in ["Debug", "Release"]:
                    assert (
                        fixture.root / (label + "-" + config + "-run.log")
                    ).read_text().strip() == "value=7 user=1 conditional=1 typed=7"
                fixture.verified.append(label + "_builds_executes_Debug_Release")
            for suffix in ["", "-twice"]:
                fixture.cli(work, "deintegrate")
                assert_restored(fixture, selected, original, label + suffix)
            fixture.verified.append(label + "_deintegration_restores_user_graph_twice")


def configuration_path(fixture, parent):
    label = "typed-configuration-reference"
    work, selected = create(parent / label)
    original_directory = selected.parent / "Configs"
    directory = selected.parent / r"Configs\Selected"
    original_directory.rename(directory)
    base = directory / "Base.xcconfig"
    base.write_text(
        base.read_text() + "\nSDK_VALUE[sdk=macosx*] = 7\nFILE_SENTINEL = 17\n"
    )
    graph = read_project(selected)
    projects, _ = configurations(graph)
    for config in projects:
        config["buildSettings"].update(
            PROVISIONING_PROFILE_SPECIFIER=r"$(PROJECT_DIR)/Configs\$(SUFFIX)",
            SUFFIX="Selected",
        )
    for obj in graph["objects"].values():
        if obj.get("isa") == "PBXFileReference" and obj.get("path") in [
            "Debug.xcconfig",
            "Release.xcconfig",
        ]:
            obj.update(
                path="$(PROVISIONING_PROFILE_SPECIFIER)/" + obj["path"],
                sourceTree="<absolute>",
            )
    save(selected, graph)
    original = read_project(selected)
    hook(work)
    fixture.cli(work, "install")
    compare(fixture, work, selected, label, True)
    reinstall(fixture, work, selected)
    builds(fixture, work, label)
    for config in ["Debug", "Release"]:
        assert (
            fixture.root / (label + "-" + config + "-run.log")
        ).read_text().strip() == "value=7 user=1 conditional=1 typed=7"
    for suffix in ["", "-twice"]:
        fixture.cli(work, "deintegrate")
        assert_restored(fixture, selected, original, label + suffix)
    fixture.verified.extend(
        [
            label + "_matches_Xcode_Debug_Release",
            label + "_offline_reinstall_is_stable",
            label + "_builds_executes_Debug_Release",
            label + "_deintegration_restores_user_graph_twice",
        ]
    )


def historical_paths(work, selected):
    """Recreate the pre-escaping writer in both graphs and ownership IDs."""
    graph = read_project(selected)
    mapping = {}
    for identifier, obj in list(graph["objects"].items()):
        path = obj.get("path", "")
        if (
            obj.get("isa") == "PBXFileReference"
            and identifier
            == hashlib.sha256(("swiftpods:xcconfig:" + path).encode())
            .hexdigest()[:24]
            .upper()
        ):
            raw = path.replace("$$", "$")
            mapping[identifier] = (
                hashlib.sha256(("swiftpods:xcconfig:" + raw).encode())
                .hexdigest()[:24]
                .upper()
            )
            obj["path"] = raw

    def replace(value):
        if isinstance(value, dict):
            return {
                mapping.get(key, key): replace(child) for key, child in value.items()
            }
        if isinstance(value, list):
            return [replace(child) for child in value]
        return mapping.get(value, value) if isinstance(value, str) else value

    save(selected, replace(graph))
    receipt = work / "Pods/Target Support Files/SwiftPods-Integration.json"
    receipt.write_text(
        json.dumps(replace(json.loads(receipt.read_text())), indent=2) + "\n"
    )
    pods = work / "Pods/Pods.xcodeproj"
    graph = read_project(pods)
    for obj in graph["objects"].values():
        if obj.get("isa") == "PBXFileReference" and isinstance(obj.get("path"), str):
            obj["path"] = obj["path"].replace("$$", "$")
    save(pods, graph)


def missing_configurations(fixture, parent):
    for form in [
        "encoded-old",
        "encoded-current",
        "encoded-random",
        "raw-legacy",
        "missing-project",
        "relocated",
    ]:
        label = "typed-missing-" + form
        container = parent / label
        work, selected = create(container)
        graph = read_project(selected)
        _, targets = configurations(graph)
        for config in graph["objects"].values():
            if config.get("isa") == "XCBuildConfiguration":
                config["name"] = (
                    "Debug-$Cash" if config["name"] == "Debug" else "Debug-$$Cash"
                )
        for config in targets:
            config.pop("baseConfigurationReference", None)
            config["buildSettings"].update(
                SDKROOT="macosx", MACOSX_DEPLOYMENT_TARGET="13.0"
            )
            config["buildSettings"].pop("SWIFT_VERSION", None)
            if config["name"] == "Debug-$$Cash":
                config["buildSettings"]["SWIFT_VERSION"] = "5.0"
        save(selected, graph)
        original = read_project(selected)
        if form == "encoded-random":
            podfile = work / "Podfile"
            podfile.write_text(
                "install! 'cocoapods', :deterministic_uuids => false\n"
                + podfile.read_text()
            )
        fixture.cli(work, "install")
        receipt = work / "Pods/Target Support Files/SwiftPods-Integration.json"
        if form != "encoded-current":
            settings = json.loads(receipt.read_text())
            settings.pop("_configuration_path_encoding", None)
            receipt.write_text(json.dumps(settings, indent=2) + "\n")
        if form == "raw-legacy":
            historical_paths(work, selected)
        support = work / "Pods/Target Support Files/Pods-Demo"
        missing = support / "Pods-Demo.debug-$cash.xcconfig"
        neighbor = support / "Pods-Demo.debug-$$cash.xcconfig"
        missing.unlink()
        neighbor.write_text(neighbor.read_text() + "SWIFT_VERSION = 99.0\n")
        if form == "missing-project":
            shutil.rmtree(work / "Pods/Pods.xcodeproj")
        if form == "relocated":
            destination = parent / (label + "-copy")
            shutil.copytree(container, destination, symlinks=True)
            work, selected = (
                destination / "work",
                destination / "Apps/External.xcodeproj",
            )
            support = work / "Pods/Target Support Files/Pods-Demo"
        fixture.cli(work, "install")
        assert (support / "Pods-Demo.debug-$cash.xcconfig").exists()
        assert "99.0" not in (support / "Pods-Demo.debug-$cash.xcconfig").read_text()
        fixture.verified.append(label + "_regenerates_its_own_missing_configuration")
        if form != "encoded-random":
            reinstall(fixture, work, selected)
            fixture.verified.append(label + "_offline_reinstall_is_stable")
        else:
            fixture.cli(work, "install", "--offline", "--deployment")
            fixture.verified.append(
                label + "_offline_reinstall_succeeds_with_random_UUIDs"
            )
        for suffix in ["", "-twice"]:
            fixture.cli(work, "deintegrate")
            assert_restored(fixture, selected, original, label + suffix)
        fixture.verified.append(label + "_deintegration_restores_user_graph_twice")


def missing_literal_label(fixture, parent):
    label = "typed-missing-literal-label"
    work, selected = create(parent / label)
    graph = read_project(selected)
    _, targets = configurations(graph)
    for obj in graph["objects"].values():
        if obj.get("isa") == "PBXNativeTarget" and obj.get("name") == "Demo":
            obj["name"] = "Demo-$Cash"
    for config in targets:
        config.pop("baseConfigurationReference", None)
        config["buildSettings"].update(
            SDKROOT="macosx", MACOSX_DEPLOYMENT_TARGET="13.0"
        )
        config["buildSettings"].pop("SWIFT_VERSION", None)
        if config["name"] == "Release":
            config["buildSettings"]["SWIFT_VERSION"] = "5.0"
    save(selected, graph)
    original = read_project(selected)
    podfile = work / "Podfile"
    podfile.write_text(
        podfile.read_text()
        .replace("target 'Demo'", "target 'Demo-$Cash'")
        .replace("t.name == 'Pods-Demo'", "t.name == 'Pods-Demo-$Cash'")
    )
    fixture.cli(work, "install")
    receipt = work / "Pods/Target Support Files/SwiftPods-Integration.json"
    settings = json.loads(receipt.read_text())
    settings.pop("_configuration_path_encoding", None)
    receipt.write_text(json.dumps(settings, indent=2) + "\n")
    shutil.rmtree(work / "Pods/Pods.xcodeproj")
    physical = (
        work
        / "Pods/Target Support Files/Pods-Demo-$Cash/Pods-Demo-$Cash.debug.xcconfig"
    )
    physical.unlink()
    decoy = (
        work
        / "Pods/Target Support Files/Pods-Demo-$$Cash/Pods-Demo-$$Cash.debug.xcconfig"
    )
    decoy.parent.mkdir(parents=True)
    decoy.write_text("SWIFT_VERSION = 99.0\n")
    fixture.cli(work, "install")
    assert physical.exists() and "99.0" not in physical.read_text()
    assert decoy.read_text() == "SWIFT_VERSION = 99.0\n"
    fixture.verified.append(
        label + "_preserves_PBX_encoding_when_all_producer_evidence_is_missing"
    )
    reinstall(fixture, work, selected)
    fixture.verified.append(label + "_offline_reinstall_is_stable")
    for suffix in ["", "-twice"]:
        fixture.cli(work, "deintegrate")
        assert_restored(fixture, selected, original, label + suffix)
    fixture.verified.append(label + "_deintegration_restores_user_graph_twice")


def unsupported_encoding(fixture, parent):
    label = "typed-unsupported-encoding"
    work, selected = create(parent / label)
    original = read_project(selected)
    fixture.cli(work, "install")
    receipt = work / "Pods/Target Support Files/SwiftPods-Integration.json"
    valid = receipt.read_bytes()
    settings = json.loads(valid)
    settings["_configuration_path_encoding"] = 2
    receipt.write_text(json.dumps(settings, indent=2) + "\n")
    project_before = (selected / "project.pbxproj").read_bytes()
    lock_before = (work / "Podfile.lock").read_bytes()
    (work / "resolved-settings.json").unlink()
    podfile = work / "Podfile"
    podfile.write_text(
        podfile.read_text()
        + "pre_install { |_| File.write('typed-pre-hook', 'ran') }\n"
    )
    result = fixture.cli(work, "install", succeeds=False)
    assert result["project_state"] == "failed_no_managed_changes", result
    assert any(e.get("code") == "SP-INTEGRATION-LOCATION" for e in result["events"])
    assert (selected / "project.pbxproj").read_bytes() == project_before
    assert (work / "Podfile.lock").read_bytes() == lock_before
    assert (
        not (work / "typed-pre-hook").exists()
        and not (work / "resolved-settings.json").exists()
    )
    fixture.verified.append(label + "_rejects_before_hooks_or_managed_changes")
    receipt.write_bytes(valid)
    fixture.cli(work, "install")
    fixture.verified.append(
        label + "_restored_supported_metadata_installs_successfully"
    )
    reinstall(fixture, work, selected)
    fixture.verified.append(label + "_offline_reinstall_is_stable")
    for suffix in ["", "-twice"]:
        fixture.cli(work, "deintegrate")
        assert_restored(fixture, selected, original, label + suffix)
    fixture.verified.append(label + "_deintegration_restores_user_graph_twice")


def run_regressions(fixture):
    with tempfile.TemporaryDirectory(
        prefix="type-regressions-", dir=fixture.root
    ) as temporary:
        parent = Path(temporary)
        sdk_types(fixture, parent)
        configuration_path(fixture, parent)
        missing_configurations(fixture, parent)
        missing_literal_label(fixture, parent)
        unsupported_encoding(fixture, parent)
