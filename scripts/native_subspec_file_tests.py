#!/usr/bin/env python3
"""Build subspecs with distinct compiler/ARC/header policies and scoped exclusions."""

import json

from consumer_build_regressions import update_spec
from native_integration import serialize
from native_lifecycle_tests import LifecycleFixture
from native_linker_manifest_tests import application, fixture_project, podfile
from reporting import ROOT, execute
from vendor_fixture import run
from workspace_resource_regressions import read_project


def create(fixture, mode):
    work, selected = fixture_project(fixture, "subspec-files-" + mode)
    (work / "Kit/Kit.c").unlink()
    (work / "Kit/Kit.h").unlink()
    children = []
    for name, value, extension, arc in [("A", 1, "m", True), ("B", 2, "M", False)]:
        root = work / "Kit" / name
        (root / "Include").mkdir(parents=True)
        (root / "Include" / (name + ".h")).write_text(
            '#ifdef __cplusplus\nextern "C" {\n#endif\nint '
            + name.lower()
            + "_value(void);\n#ifdef __cplusplus\n}\n#endif\n"
        )
        (root / (name + "." + extension)).write_text(
            "#if CHOICE != "
            + str(value)
            + " || ROOT_FLAG != 1\n#error Wrong_subspec_flags\n#endif\n"
            "#if "
            + ("!" if arc else "")
            + "__has_feature(objc_arc)\n#error Wrong_subspec_ARC\n#endif\n"
            '#include "'
            + name
            + '.h"\n'
            + ('extern "C" ' if extension == "M" else "")
            + "int "
            + name.lower()
            + "_value(void) { return "
            + str(value)
            + "; }\n"
        )
        (root / (name.lower() + ".txt")).write_text(name)
        (root / ("Bundle" + name + ".txt")).write_text("Bundle" + name)
        children.append(
            {
                "name": name,
                "source_files": name + "/**/*.{m,M,h}",
                "compiler_flags": "-DCHOICE=" + str(value),
                "requires_arc": arc,
                "header_mappings_dir": name,
                "header_dir": "Alpha" if name == "A" else "Beta",
                "resources": name + "/" + name.lower() + ".txt",
                "resource_bundles": {"SharedData": name + "/Bundle" + name + ".txt"},
            }
        )
    (work / "Kit/A/Excluded.m").write_text("#error Excluded_file_was_compiled\n")
    children[0]["exclude_files"] = ["A/Excluded.m", "B/B.M", "B/b.txt", "B/BundleB.txt"]
    if mode != "library":
        (work / "Kit/Internal.h").write_text("#define INTERNAL_VALUE 1\n")
        children[0]["source_files"] = [children[0]["source_files"], "Internal.h"]
        children[0]["project_header_files"] = "Internal.h"
        source_file = work / "Kit/A/A.m"
        source_file.write_text(
            '#include "Internal.h"\n#if INTERNAL_VALUE != 1\n#error Internal_header_missing\n#endif\n'
            + source_file.read_text()
        )
    update_spec(
        work, source_files=[], compiler_flags="-DROOT_FLAG=1", subspecs=children
    )
    (work / "Podfile").write_text(
        ("use_frameworks! :linkage => :" + mode + "\n" if mode != "library" else "")
        + podfile()
    )
    return work, selected


def source(mode, only_b=False):
    a = "Alpha" if mode == "library" else "Kit"
    b = "Beta" if mode == "library" else "Kit"
    return (
        (
            "#if __has_include(<Kit/Internal.h>)\n#error Project_header_published\n#endif\n"
            if mode != "library"
            else ""
        )
        + (
            "#include <" + a + "/Include/A.h>\n"
            if not only_b
            else "#if __has_include(<"
            + a
            + "/Include/A.h>)\n#error Unselected_header_visible\n#endif\n"
        )
        + "#include <"
        + b
        + "/Include/B.h>\nint main(void) { return "
        + ("a_value() == 1 && " if not only_b else "")
        + "b_value() == 2 ? 0 : 1; }\n"
    )


def resources(app, only_b=False):
    for name in ["B"] if only_b else ["A", "B"]:
        plain = list(app.rglob(name.lower() + ".txt"))
        bundles = [
            path
            for path in app.rglob("Bundle" + name + ".txt")
            if "SharedData.bundle" in path.parts
        ]
        assert plain and all(path.read_text() == name for path in plain)
        assert bundles and all(path.read_text() == "Bundle" + name for path in bundles)
    if only_b:
        assert not list(app.rglob("a.txt")) and not list(app.rglob("BundleA.txt"))


def custom_module_map(fixture):
    work, selected = fixture_project(fixture, "subspec-custom-map")
    (work / "Kit/Kit.c").unlink()
    (work / "Kit/Kit.h").unlink()
    child = work / "Kit/Child"
    child.mkdir()
    (child / "Feature.h").write_text("#define FEATURE_VALUE 7\n")
    (child / "Feature.c").write_text("int feature_value(void) { return 7; }\n")
    contents = 'framework module Kit { header "Feature.h" export * }\n'
    original = work / "Kit/Author.modulemap"
    original.write_text(contents)
    update_spec(
        work,
        source_files=[],
        module_map="Author.modulemap",
        subspecs=[
            {"name": "Child", "source_files": "Child/*.{c,h}", "header_dir": "Alias"}
        ],
    )
    (work / "Podfile").write_text(podfile().replace("pod 'Kit'", "pod 'Kit/Child'"))
    graph = read_project(selected)
    for obj in graph["objects"].values():
        if obj.get("isa") == "XCBuildConfiguration":
            obj["buildSettings"]["CLANG_ENABLE_MODULES"] = "YES"
        if obj.get("isa") == "PBXFileReference" and str(obj.get("path", "")).endswith(
            "main.mm"
        ):
            obj["path"] = obj["path"][:-3] + ".m"
            obj["lastKnownFileType"] = "sourcecode.c.objc"
    (selected / "project.pbxproj").write_text(serialize(graph))
    (selected.parent / "Sources/main.mm").unlink()
    (selected.parent / "Sources/main.m").write_text(
        "@import Kit;\n#if FEATURE_VALUE != 7\n#error Custom_module_map_header_missing\n#endif\n"
        "extern int feature_value(void);\n"
        "int main(void) { return feature_value() == FEATURE_VALUE ? 0 : 1; }\n"
    )
    fixture.cli(work, "install")
    fixture.cli(work, "install", "--deployment", "--offline")
    label = "subspec-custom-map-build"
    fixture.build(work, "Demo", label)
    run(
        [application(fixture, label)],
        work,
        fixture.root / (label + "-run.log"),
        env=fixture.env,
    )
    assert original.read_text() == contents
    fixture.verified.append(
        "framework_style_custom_map_builds_selected_child_namespace"
    )


def main():
    fixture = LifecycleFixture()
    for mode in ["library", "static", "dynamic"]:
        work, selected = create(fixture, mode)
        main_source = selected.parent / "Sources/main.mm"
        main_source.write_text(source(mode))
        fixture.cli(work, "install")
        locked = (work / "Podfile.lock").read_bytes()
        before = (selected / "project.pbxproj").read_bytes()
        fixture.cli(work, "install", "--deployment", "--offline")
        assert (work / "Podfile.lock").read_bytes() == locked
        assert (selected / "project.pbxproj").read_bytes() == before
        label = "subspec-files-build-" + mode
        fixture.build(work, "Demo", label)
        binary = application(fixture, label)
        run([binary], work, fixture.root / (label + "-run.log"), env=fixture.env)
        resources(binary.parents[2])
        fixture.verified += [
            "distinct_subspec_compiler_flags_and_arc_compile_and_execute_" + mode,
            "owner_exclusions_preserve_sibling_sources_resources_and_bundles_" + mode,
            "owner_header_mappings_and_namespaces_build_with_offline_reinstall_" + mode,
        ]
        update_spec(work, default_subspecs=["B"])
        main_source.write_text(source(mode, only_b=True))
        fixture.cli(work, "install")
        fixture.cli(work, "install", "--deployment", "--offline")
        label = "subspec-files-reselected-" + mode
        fixture.build(work, "Demo", label)
        binary = application(fixture, label)
        run([binary], work, fixture.root / (label + "-run.log"), env=fixture.env)
        resources(binary.parents[2], only_b=True)
        fixture.verified.append(
            "reselection_isolates_sources_resources_and_header_visibility_" + mode
        )
    custom_module_map(fixture)
    (ROOT / "test-results/native-subspec-files.json").write_text(
        json.dumps(
            {
                "status": "passed",
                "verified": fixture.verified,
                "fixture": str(fixture.root),
            },
            indent=2,
        )
        + "\n"
    )
    print("Passed", len(fixture.verified), "subspec file regressions", fixture.root)


if __name__ == "__main__":
    execute(main, "native-subspec-files.json")
