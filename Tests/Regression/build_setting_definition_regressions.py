"""Definition ancestry, anonymous paths, SDK validation and legacy path upgrades."""

import hashlib
import json
import platform
import plistlib
import re
import tempfile
from pathlib import Path

from scripts.support.processes import run_captured
from Tests.Fixtures.vendor_fixture import (
    fixture_build_arguments,
    fixture_derived_data,
    run,
)
from Tests.Integration.native_integration import project
from Tests.Integration.native_xcconfig_tests import create
from Tests.Regression.build_setting_expression_regressions import reference
from Tests.Regression.configuration_context_regressions import configurations, save
from Tests.Regression.project_path_regressions import assert_restored, reinstall
from Tests.Regression.workspace_resource_regressions import read_project

FORMS = [
    "self-base",
    "self-base-modifier",
    "self-project",
    "self-none",
    "self-xcconfig",
    "self-choice",
    "ancestor-default",
    "project-choice-base",
    "conditional-choice",
    "private-reference",
    "private-nested-reference",
    "unknown-key-control",
    "short-known",
    "short-unknown",
    "short-suffix",
    "prefix-path",
    "prefix-path-control",
    "prefix-short",
]
UNAVAILABLE = {
    "short-unknown",
    "short-suffix",
    "prefix-path",
    "prefix-path-control",
    "prefix-short",
}
PATHS = [r"Root-\Folder", r"Root-\$(SDKROOT)", r"Root-\$NAME", r"Root-\\$(SDKROOT)"]


def prepare(parent, form, *, implicit=False):
    work, selected = create(parent / ("definition-" + form))
    graph = read_project(selected)
    projects, targets = configurations(graph)
    base = selected.parent / "Configs/Base.xcconfig"
    text = base.read_text() + "\nSDK_VALUE[sdk=macosx*] = 7\nFILE_SENTINEL = 17\n"
    if form in {"self-base", "self-base-modifier", "self-project", "self-none"}:
        for config in targets:
            config["buildSettings"]["SDKROOT"] = (
                "$(SDKROOT:lower)" if form == "self-base-modifier" else "$(SDKROOT)"
            )
        if form in {"self-project", "self-none"}:
            text = text.replace("SDKROOT = macosx\n", "")
        if form == "self-project":
            for config in projects:
                config["buildSettings"]["SDKROOT"] = "macosx"
    if form == "self-xcconfig":
        text += "SDKROOT = $(SDKROOT)\n"
    if form == "self-choice":
        text += "SDK_CHOICE = MACOSX\n"
        for config in targets:
            config["buildSettings"].update(
                SDK_CHOICE="$(SDK_CHOICE:lower)", SDKROOT="$(SDK_CHOICE)"
            )
    if form == "ancestor-default":
        text = (
            text.replace("SDKROOT = macosx", "SDKROOT = $(SDK_CHOICE)")
            + "SDK_CHOICE = $(SDKROOT)\n"
        )
    if form == "project-choice-base":
        text = text.replace("SDKROOT = macosx\n", "") + "SDK_CHOICE = macosx\n"
        for config in projects:
            config["buildSettings"].update(
                SDKROOT="$(SDK_CHOICE)", SDK_CHOICE="$(SDK_CHOICE:lower)"
            )
    if form == "conditional-choice":
        text = text.replace("SDKROOT = macosx\n", "")
        for config in targets:
            config["buildSettings"].update(
                {
                    "SDKROOT": "$(SDK_CHOICE)",
                    "SDK_CHOICE": "$(SDK_CHOICE)",
                    "SDK_CHOICE[config=*]": "macosx",
                }
            )
    if form in {"private-reference", "private-nested-reference", "unknown-key-control"}:
        for config in projects:
            config["buildSettings"].update(
                PREFIX=".SwiftPods.xcconfig", SUFFIX=".reference."
            )
        key = {
            "private-reference": ".SwiftPods.xcconfig.reference.",
            "private-nested-reference": "$(PREFIX)$(SUFFIX)",
            "unknown-key-control": "MISSING_FOLDER",
        }[form]
        for obj in graph["objects"].values():
            if obj.get("isa") == "PBXFileReference" and obj.get("path") in {
                "Debug.xcconfig",
                "Release.xcconfig",
            }:
                obj.update(
                    path="$(" + key + ":default=$(PROJECT_DIR))/Configs/" + obj["path"],
                    sourceTree="<absolute>",
                )
    raw = {
        "short-known": "$SDK_CHOICE",
        "short-unknown": "$MISSING",
        "short-suffix": "macosx$MISSING",
        "prefix-path": "macosx$(MISSING)/Custom.sdk",
        "prefix-path-control": "macosx/Custom.sdk",
        "prefix-short": "macosx$MISSING/Custom.sdk",
    }.get(form)
    if raw:
        text = text.replace("SDKROOT = macosx", "SDKROOT = " + raw)
        if form == "short-known":
            text += "SDK_CHOICE = macosx\n"
    if form.startswith("nul-"):
        text = text.replace("SDKROOT = macosx\n", "")
        for config in targets:
            config["buildSettings"]["SDKROOT"] = (
                "$(SDK_CHOICE)" if "indirect" in form else "macosx\0ignored"
            )
            if "indirect" in form:
                config["buildSettings"]["SDK_CHOICE"] = "macosx\0ignored"
    base.write_text(text)
    if form.startswith("nul-"):
        (selected / "project.pbxproj").write_bytes(
            plistlib.dumps(graph, fmt=plistlib.FMT_BINARY)
        )
    else:
        save(selected, graph)
    podfile = work / "Podfile"
    code = podfile.read_text().split("post_install do |i|", 1)[0]
    if implicit:
        code = code.replace("platform :osx, '13.0'\n", "")
    podfile.write_text(
        code
        + """pre_install { |_| File.write('definition-hook-ran', 'yes') }
post_install do |i|
 t=i.aggregate_targets.first.user_targets.first
 values=%w[SDKROOT SDK_VALUE FILE_SENTINEL SDK_CHOICE].to_h { |key| [key,t.resolved_build_setting(key,true)] }
 File.write('definition-values.json',JSON.generate(values))
end
"""
    )
    return work, selected


def reject(fixture, work, selected, code, label):
    original = (selected / "project.pbxproj").read_bytes()
    report = fixture.cli(work, "install", succeeds=False)
    assert report["project_state"] == "failed_no_managed_changes", report
    assert any(e.get("code") == code for e in report["events"]), report
    assert (selected / "project.pbxproj").read_bytes() == original
    assert not any(
        (work / name).exists()
        for name in [
            "Pods",
            "Podfile.lock",
            "definition-hook-ran",
            "definition-values.json",
        ]
    )
    fixture.verified.append(label + "_rejects_before_hooks_and_managed_writes")


def definitions(fixture, parent):
    for form in FORMS:
        work, selected = prepare(parent, form)
        label = "definition-" + form
        fixture.cli(work, "install")
        values = json.loads((work / "definition-values.json").read_text())
        observations = {}
        for config in ["Debug", "Release"]:
            expected = reference(fixture, work, selected, "Demo", config, label)
            actual = {
                key: values[key].get(config) for key in ["SDK_VALUE", "FILE_SENTINEL"]
            }
            assert actual == {key: expected.get(key) for key in actual}, (
                form,
                config,
                actual,
                expected,
            )
            assert actual == {
                "SDK_VALUE": None if form in UNAVAILABLE else "7",
                "FILE_SENTINEL": "17",
            }
            observations[config] = {
                **actual,
                "SDKROOT": expected.get("SDKROOT"),
                "SDK_NAME": expected.get("SDK_NAME"),
            }
        (fixture.root / (label + "-comparison.json")).write_text(
            json.dumps(observations, indent=2) + "\n"
        )
        fixture.verified.append(label + "_matches_Xcode_Debug_Release")
        reinstall(fixture, work, selected)
        fixture.verified.append(label + "_offline_reinstall_stable")
        if form in UNAVAILABLE:
            # Missing or malformed SDK names must not acquire a platform from their prefix.
            rejected_work, rejected_project = prepare(
                parent / "implicit", form, implicit=True
            )
            reject(
                fixture,
                rejected_work,
                rejected_project,
                "SP-PLATFORM-MISSING",
                label + "-implicit",
            )
    # Xcode aborts on NUL SDKROOT. Do not repeatedly crash it in the regression suite.
    for indirect in [False, True]:
        for implicit in [False, True]:
            form = (
                "nul-"
                + ("indirect" if indirect else "direct")
                + ("-implicit" if implicit else "-explicit")
            )
            work, selected = prepare(parent, form, implicit=implicit)
            reject(fixture, work, selected, "SP-XCCONFIG-PATH", "definition-" + form)


def build(fixture, work, selected, label, *, standalone=False):
    for config in ["Debug", "Release"]:
        name = label + "-" + config
        derived = fixture.root / name
        derived.mkdir()
        selection = (
            ["-project", selected]
            if standalone
            else ["-workspace", next(work.glob("*.xcworkspace"))]
        )
        run(
            [
                "xcodebuild",
                *selection,
                "-scheme",
                "Demo",
                "-configuration",
                config,
                "-destination",
                "platform=macOS,arch=" + platform.machine(),
                *fixture_build_arguments(derived),
                "CLANG_USE_RESPONSE_FILE=NO",
                "CODE_SIGNING_ALLOWED=NO",
                "build",
            ],
            work,
            fixture.root / (name + "-build.log"),
            env=fixture.env,
        )
        binary = (
            fixture_derived_data(derived)
            / "Build/Products"
            / config
            / "Demo.app/Contents/MacOS/Demo"
        )
        run([binary], work, fixture.root / (name + "-run.log"), env=fixture.env)
        assert (fixture.root / (name + "-run.log")).read_text().strip() == (
            "independent=23" if standalone else "value=7 user=1 conditional=1"
        )


def response_control(fixture, parent):
    """Measure the Xcode/LLVM response-file boundary without invoking SwiftPods."""
    root = parent / "independent-response" / r"Root-\Folder"
    (root / "Sources").mkdir(parents=True)
    (root / "Includes").mkdir()
    (root / "Includes/Independent.h").write_text("#define INDEPENDENT 23\n")
    (root / "Sources/main.mm").write_text(
        '#include <Independent.h>\n#include <stdio.h>\nint main(void) { printf("independent=%d\\n", INDEPENDENT); return 0; }\n'
    )
    selected = root / "Independent.xcodeproj"
    project(selected)
    graph = read_project(selected)
    _, targets = configurations(graph)
    for config in targets:
        config["buildSettings"]["ALWAYS_SEARCH_USER_PATHS"] = "NO"
        config["buildSettings"]["HEADER_SEARCH_PATHS"] = (
            '"' + str(root / "Includes").replace("\\", "\\\\") + '"'
        )
    save(selected, graph)
    derived = fixture.root / "definition-independent-response"
    derived.mkdir()
    result = run_captured(
        [
            "xcodebuild",
            "-project",
            selected,
            "-scheme",
            "Demo",
            "-configuration",
            "Debug",
            "-destination",
            "platform=macOS,arch=" + platform.machine(),
            *fixture_build_arguments(derived),
            "CODE_SIGNING_ALLOWED=NO",
            "build",
        ],
        root,
        fixture.root / "definition-independent-response",
        env=fixture.env,
        timeout=120,
    )
    if result.returncode:
        assert "'Independent.h' file not found" in result.stdout + result.stderr
    assert not re.search(r"\bwarning:", result.stdout + result.stderr)
    (fixture.root / "definition-response-boundary.json").write_text(
        json.dumps(
            {
                "default_status": result.returncode,
                "swiftpods_invoked": False,
                "consumer_override": "CLANG_USE_RESPONSE_FILE=NO",
            },
            indent=2,
        )
        + "\n"
    )
    build(fixture, root, selected, "definition-independent", standalone=True)
    fixture.verified.append(
        "definition_independent_Xcode_response_boundary_and_direct_arguments"
    )


def literal_paths(fixture, parent):
    for index, name in enumerate(PATHS):
        work, selected = create(parent / ("path-" + str(index)) / name)
        original = read_project(selected)
        label = "definition-path-" + str(index)
        fixture.cli(work, "install")
        reinstall(fixture, work, selected)
        build(fixture, work, selected, label)
        fixture.verified.append(
            label + "_builds_executes_Debug_Release_with_direct_arguments"
        )
        fixture.verified.append(label + "_offline_reinstall_stable")
        for suffix in ["", "-twice"]:
            fixture.cli(work, "deintegrate")
            assert_restored(fixture, selected, original, label + suffix)
        fixture.verified.append(label + "_deintegration_restores_user_graph_twice")


def legacy_paths(fixture, parent):
    for index, name in enumerate(["Root-$(SDKROOT)", "Root-$$Money", "Root-normal"]):
        work, selected = create(parent / ("legacy-" + str(index)) / name)
        graph = read_project(selected)
        _, targets = configurations(graph)
        for config in targets:
            config.pop("baseConfigurationReference", None)
            config["buildSettings"].update(
                SDKROOT="macosx",
                MACOSX_DEPLOYMENT_TARGET="13.0",
                GCC_PREPROCESSOR_DEFINITIONS=[
                    "$(inherited)",
                    "USER_CONFIG=1",
                    "CONDITIONAL_CONFIG=1",
                ],
            )
            if index == 2:
                config["name"] += "-$$Cash"
        save(selected, graph)
        original = read_project(selected)
        fixture.cli(work, "install")
        # Recreate the historical writer's raw paths and deterministic ownership IDs.
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
                old_id = (
                    hashlib.sha256(("swiftpods:xcconfig:" + raw).encode())
                    .hexdigest()[:24]
                    .upper()
                )
                mapping[identifier] = old_id
                obj["path"] = raw

        def replace(value):
            if isinstance(value, dict):
                return {
                    mapping.get(key, key): replace(child)
                    for key, child in value.items()
                }
            if isinstance(value, list):
                return [replace(child) for child in value]
            return mapping.get(value, value) if isinstance(value, str) else value

        save(selected, replace(graph))
        receipt = work / "Pods/Target Support Files/SwiftPods-Integration.json"
        settings = replace(json.loads(receipt.read_text()))
        # Historical writers did not declare literal path encoding. Keep the
        # producer graph in that same format instead of creating a mixed fixture.
        settings.pop("_configuration_path_encoding", None)
        receipt.write_text(json.dumps(settings, indent=2) + "\n")
        pods = work / "Pods/Pods.xcodeproj"
        producer = read_project(pods)
        for obj in producer["objects"].values():
            if obj.get("isa") == "PBXFileReference" and isinstance(
                obj.get("path"), str
            ):
                obj["path"] = obj["path"].replace("$$", "$")
        save(pods, producer)
        fixture.cli(work, "install")
        reinstall(fixture, work, selected)
        label = "definition-legacy-" + str(index)
        fixture.verified.append(
            label + "_raw_paths_upgrade_hooks_and_offline_reinstall"
        )
        for suffix in ["", "-twice"]:
            fixture.cli(work, "deintegrate")
            assert_restored(fixture, selected, original, label + suffix)
        fixture.verified.append(label + "_deintegration_restores_user_graph_twice")


def run_regressions(fixture):
    with tempfile.TemporaryDirectory(
        prefix="definition-regressions-", dir=fixture.root
    ) as temporary:
        parent = Path(temporary)
        definitions(fixture, parent)
        response_control(fixture, parent)
        literal_paths(fixture, parent)
        legacy_paths(fixture, parent)
