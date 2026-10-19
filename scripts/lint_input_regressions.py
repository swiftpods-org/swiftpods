"""Real lint consumers, optional interfaces, Unicode modules and xcconfig inputs."""

import json

from consumer_build_regressions import install_twice, podfile, update_spec
from input_contract_regressions import save_project
from native_xcconfig_tests import create
from workspace_resource_regressions import read_project


def validation(report):
    return next(
        event["data"] for event in report["events"] if event["kind"] == "validation"
    )


def lint_consumers(fixture):
    work, _ = create(fixture.root / "lint-name-collision")
    library = work / "Kit"
    spec = library / "Lint.podspec.json"
    data = json.loads((library / "Kit.podspec.json").read_text())
    data["name"] = "Lint"
    (library / "Kit.podspec.json").unlink()
    spec.write_text(json.dumps(data))
    (library / "LICENSE").write_text("MIT License\n")
    header = library / "Kit.h"
    original = header.read_bytes()
    for flags in [[], ["--use-libraries"]]:
        header.write_text("#error Invalid colliding module interface\n")
        report = validation(
            fixture.cli(
                work,
                "lib",
                "lint",
                str(spec),
                "--platforms=osx",
                *flags,
                succeeds=False,
            )
        )
        assert report[
            "status"
        ] == "failed" and "Invalid colliding module interface" in json.dumps(report), (
            report
        )
        header.write_bytes(original)
        fixture.cli(work, "lib", "lint", str(spec), "--platforms=osx", *flags)
    fixture.verified.append(
        "lint_name_collision_checks_the_actual_consumer_in_both_modes"
    )

    work, _ = create(fixture.root / "lint-optional-interfaces")
    library = work / "Kit"
    (library / "LICENSE").write_text("MIT License\n")
    update_spec(
        work,
        source_files=["Kit.c", "Kit.h"],
        default_subspecs=["Core"],
        subspecs=[
            {"name": "Core", "source_files": "Core.c"},
            {
                "name": "Extra",
                "source_files": "Extra.c",
                "subspecs": [{"name": "Nested", "source_files": "Nested.c"}],
            },
        ],
    )
    (library / "Core.c").write_text("int core(void) { return 1; }\n")
    (library / "Extra.c").write_text("#error Invalid optional interface\n")
    (library / "Nested.c").write_text("#error Invalid nested interface\n")
    spec = library / "Kit.podspec.json"
    report = validation(
        fixture.cli(work, "lib", "lint", str(spec), "--platforms=osx", succeeds=False)
    )
    failures = {error["specification"] for error in report["errors"]}
    assert {"Kit/Extra", "Kit/Extra/Nested"}.issubset(failures), report
    report = validation(
        fixture.cli(
            work,
            "lib",
            "lint",
            str(spec),
            "--platforms=osx",
            "--fail-fast",
            succeeds=False,
        )
    )
    assert (
        len(report["errors"]) == 1
        and report["errors"][0]["specification"] == "Kit/Extra"
    ), report
    (library / "Extra.c").write_text("int extra(void) { return 1; }\n")
    (library / "Nested.c").write_text("int nested(void) { return 1; }\n")
    report = validation(fixture.cli(work, "lib", "lint", str(spec), "--platforms=osx"))
    assert set(report["specifications"][0]["built_interfaces"]) == {
        "osx:Kit",
        "osx:Kit/Core",
        "osx:Kit/Extra",
        "osx:Kit/Extra/Nested",
    }, report
    fixture.verified.append(
        "lint_compiles_nondefault_nested_subspecs_and_honors_fail_fast"
    )


def unicode_and_ui_hooks(fixture):
    work, selected = create(fixture.root / "unicode-module-input")
    update_spec(work, header_dir="École")
    graph = read_project(selected)
    for obj in graph["objects"].values():
        if obj.get("isa") == "XCBuildConfiguration":
            obj["buildSettings"]["CLANG_ENABLE_MODULES"] = "YES"
        if obj.get("isa") == "PBXFileReference" and str(obj.get("path", "")).endswith(
            "main.mm"
        ):
            obj.update(
                path=obj["path"][:-3] + ".m", lastKnownFileType="sourcecode.c.objc"
            )
    save_project(selected, graph)
    (selected.parent / "Sources/main.m").write_text(
        "@import Ecole;\nint main(void) { return kit_value() == 7 ? 0 : 1; }\n"
    )
    (work / "Podfile").write_text(
        "use_frameworks! :linkage => :static\n"
        + podfile(work)
        + """post_install do |installer|
  target = installer.pod_targets.first
  raise 'Unicode module identity changed' unless target.root_spec.module_name == 'Ecole' && target.product_module_name == 'Ecole'
end
"""
    )
    install_twice(fixture, work)
    fixture.build(work, "Demo", "unicode-module-consumer-build")
    fixture.verified.append(
        "unicode_header_directory_has_one_module_identity_in_hooks_and_compiler"
    )

    work, _ = create(fixture.root / "ui-type-input")
    update_spec(
        work,
        platforms={"osx": "14.0"},
        testspecs=[
            {
                "name": "UI",
                "test_type": "ui",
                "requires_app_host": True,
                "source_files": "UI.m",
            }
        ],
    )
    (work / "Kit/UI.m").write_text(
        "#import <XCTest/XCTest.h>\n@interface Probe : XCTestCase @end\n@implementation Probe\n- (void)testPass { XCTAssertTrue(YES); }\n@end\n"
    )
    (work / "Podfile").write_text(
        podfile(work)
        .replace("'13.0'", "'14.0'")
        .replace(":path => './Kit'", ":path => './Kit', :testspecs => ['UI']")
        + """post_install do |installer|
  pod = installer.pod_targets.first
  spec = pod.test_specs.first
  raise 'UI type is not a Symbol' unless spec.test_type == :ui
  label = pod.test_target_label(spec)
  target = installer.pods_project.targets.find { |entry| entry.name == label }
  raise 'UI label does not identify a target' unless target && label == 'Kit-UI-UI'
  target.build_configurations.each { |config| config.build_settings['UI_TYPE_HOOK'] = 'YES' }
end
"""
    )
    install_twice(fixture, work)
    graph = read_project(work / "Pods/Pods.xcodeproj")
    values = [
        obj["buildSettings"]
        for obj in graph["objects"].values()
        if obj.get("isa") == "XCBuildConfiguration"
        and obj.get("buildSettings", {}).get("PRODUCT_NAME") == "Kit-UI-UI"
    ]
    assert values and all(value.get("UI_TYPE_HOOK") == "YES" for value in values), (
        values
    )
    fixture.verified.append(
        "ui_type_and_label_hooks_find_and_mutate_the_created_target"
    )


def xcconfig_inputs(fixture):
    for scenario in ["quoted-comment", "crlf"]:
        work, selected = create(fixture.root / ("xcconfig-input-" + scenario))
        for name in ["Debug", "Release"]:
            path = selected.parent / "Configs" / (name + ".xcconfig")
            text = path.read_text()
            if scenario == "quoted-comment":
                text = text.replace(
                    '#include "Base.xcconfig"',
                    '#include "Base.xcconfig" // Keep "defaults"',
                )
            else:
                text = text.replace(
                    "$(inherited) CONDITIONAL_CONFIG=1",
                    "$(inherited) \\\n CONDITIONAL_CONFIG",
                ).replace("\n", "\r\n")
            path.write_bytes(text.encode())
        (work / "Podfile").write_text(
            podfile(work)
            + """post_install do |installer|
  target = installer.aggregate_targets.first.user_targets.first
  settings = target.resolved_build_setting('GCC_PREPROCESSOR_DEFINITIONS', true)
  raise 'Consumer definitions changed' unless settings.values.all? { |value| value.to_s.include?('USER_CONFIG=1') && value.to_s.include?('CONDITIONAL_CONFIG') }
end
"""
        )
        install_twice(fixture, work)
        fixture.build(work, "Demo", "xcconfig-" + scenario + "-consumer-build")
        fixture.verified.append(
            "xcconfig_" + scenario + "_is_shared_by_analysis_hooks_and_xcode"
        )


def run(fixture):
    lint_consumers(fixture)
    unicode_and_ui_hooks(fixture)
    xcconfig_inputs(fixture)
