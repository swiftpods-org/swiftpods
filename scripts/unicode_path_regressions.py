"""Filesystem component boundaries before Unicode combining marks."""

import json
import platform
import unicodedata

from input_contract_regressions import commit, git
from native_xcconfig_tests import create
from vendor_fixture import fixture_build_arguments, fixture_derived_data, run
from workspace_resource_regressions import read_project

PARITY_CASES = ["exclude", "directory", "header", "clean", "symlink"]

FILE_QUERY = """post_install do |installer|
  accessor = installer.pod_targets.first.file_accessors.first
  files = accessor.source_files.map { |path| path.relative_path_from(accessor.root).to_s }.sort
  File.write('unicode-paths.json', JSON.generate(files))
end
"""


def path_fixture(parent, case):
    work, selected = create(parent)
    library = work / "Kit"
    spec = library / "Kit.podspec.json"
    attributes = json.loads(spec.read_text())
    expected = ["Kit.c", "Kit.h"]

    def write(name, content):
        path = library / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    if case == "exclude":
        write("Skip/\u0301Poison.c", "#error Excluded_source_was_compiled\n")
        write(
            "Skip/\u0301Nested/Poison.c", "#error Excluded_nested_source_was_compiled\n"
        )
        attributes.update(source_files="**/*.{c,h}", exclude_files="Skip")
    elif case == "directory":
        (library / "Kit.c").unlink()
        write("\u0301Folder/Kit.c", "int kit_value(void) { return 7; }\n")
        attributes.update(source_files=["Kit.h", "\u0301Folder"])
        expected = ["Kit.h", "\u0301Folder/Kit.c"]
    elif case == "header":
        (library / "Headers").mkdir()
        (library / "Kit.h").rename(library / "Headers/\u0301Kit.h")
        attributes.update(
            source_files=["*.c", "Headers/*.h"], header_mappings_dir="Headers"
        )
        main = selected.parent / "Sources/main.mm"
        main.write_text(main.read_text().replace("<Kit/Kit.h>", "<Kit/\u0301Kit.h>"))
        expected = ["Headers/\u0301Kit.h", "Kit.c"]
    elif case == "clean":
        (library / "Kit.c").unlink()
        write("Folder/\u0301Kit.c", "int kit_value(void) { return 7; }\n")
        write("Assets/\u0301payload.txt", "preserved directory payload\n")
        write("unused.txt", "must be cleaned\n")
        attributes.update(source_files=["Kit.h", "Folder/*.c"], preserve_paths="Assets")
        expected = ["Folder/\u0301Kit.c", "Kit.h"]
    elif case == "symlink":
        (library / "Kit.c").rename(library / "\u0301Kit.c")
        (library / "Alias.c").symlink_to("\u0301Kit.c")
        attributes.update(
            source_files=["Kit.h", "Alias.c"], preserve_paths="\u0301Kit.c"
        )
        expected = ["Alias.c", "Kit.h"]
    elif case == "resources":
        write("Folder/\u0301payload.txt", "opaque directory payload\n")
        attributes.update(
            resource_bundles={"Opaque": ["Folder", "Folder/*"]},
            frameworks=["Foundation"],
        )
        (selected.parent / "Sources/main.mm").write_text(
            "#import <Foundation/Foundation.h>\n#include <Kit/Kit.h>\n"
            "int main(void) { @autoreleasepool {\n"
            'NSBundle *bundle = [NSBundle bundleWithPath:[[NSBundle mainBundle] pathForResource:@"Opaque" ofType:@"bundle"]];\n'
            "if (!bundle || kit_value() != 7) return 1;\n"
            "NSString *root = [bundle resourcePath];\n"
            'NSString *path = [root stringByAppendingPathComponent:@"Folder/\u0301payload.txt"];\n'
            "NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];\n"
            'if (![text isEqualToString:@"opaque directory payload\\n"]) return 2;\n'
            'if ([[NSFileManager defaultManager] fileExistsAtPath:[root stringByAppendingPathComponent:@"\u0301payload.txt"]]) return 3;\n'
            "return 0; } }\n"
        )
    else:
        raise AssertionError(case)
    spec.write_text(json.dumps(attributes))
    podfile = (work / "Podfile").read_text().split("post_install")[0]
    if case in ("clean", "symlink"):
        git(library, "init", "-b", "main")
        revision = commit(library, "Unicode path boundaries")
        podfile = podfile.replace(
            ":path => './Kit'",
            ":git => " + repr(str(library)) + ", :commit => " + repr(revision),
        )
    (work / "Podfile").write_text(podfile + FILE_QUERY)
    return work, selected, sorted(expected)


def observed_paths(work, expected):
    raw = json.loads((work / "unicode-paths.json").read_text())
    actual = sorted(unicodedata.normalize("NFC", value) for value in raw)
    assert actual == expected, (actual, expected)
    return {"paths": actual, "raw_paths": raw}


def check_source_contents(work, case):
    if case == "clean":
        root = work / "Pods/Kit"
        assert (root / "Folder/\u0301Kit.c").is_file()
        assert (
            root / "Assets/\u0301payload.txt"
        ).read_text() == "preserved directory payload\n"
        assert not (root / "unused.txt").exists()
    elif case == "symlink":
        root = work / "Pods/Kit"
        assert (root / "Alias.c").is_symlink()
        assert (root / "Alias.c").read_bytes() == (root / "\u0301Kit.c").read_bytes()


def path_parity(parent, engines, native, reference):
    observations = {}
    for case in PARITY_CASES:
        observations[case] = {}
        for engine in engines:
            work, _, expected = path_fixture(
                parent / ("unicode-path-" + case + "-" + engine), case
            )
            source = work / "Kit/Kit.podspec.json"
            original = source.read_bytes()
            (native if engine == "native" else reference)(work, "install")
            observations[case][engine] = observed_paths(work, expected)
            check_source_contents(work, case)
            assert source.read_bytes() == original
    return observations


def path_builds(fixture):
    for case in [*PARITY_CASES, "resources"]:
        work, selected, expected = path_fixture(
            fixture.root / ("unicode-build-" + case), case
        )
        source = work / "Kit/Kit.podspec.json"
        original = source.read_bytes()
        fixture.cli(work, "install")
        observed_paths(work, expected)
        check_source_contents(work, case)
        if case == "directory":
            objects = read_project(work / "Pods/Pods.xcodeproj")["objects"]
            assert any(
                o.get("isa") == "PBXGroup" and o.get("path") == "\u0301Folder"
                for o in objects.values()
            )
        locked = (work / "Podfile.lock").read_bytes()
        projects = {
            path: path.read_bytes()
            for path in [
                selected / "project.pbxproj",
                work / "Pods/Pods.xcodeproj/project.pbxproj",
            ]
        }
        fixture.cli(work, "install", "--deployment", "--offline")
        assert (work / "Podfile.lock").read_bytes() == locked
        assert all(path.read_bytes() == before for path, before in projects.items())
        assert source.read_bytes() == original
        for configuration in ["Debug", "Release"]:
            label = "unicode-" + case + "-" + configuration
            build_root = fixture.root / label
            build_root.mkdir()
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
                    *fixture_build_arguments(build_root),
                    "CODE_SIGNING_ALLOWED=NO",
                    "build",
                ],
                work,
                fixture.root / (label + "-build.log"),
                env=fixture.env,
            )
            binary = (
                fixture_derived_data(build_root)
                / "Build/Products"
                / configuration
                / "Demo.app/Contents/MacOS/Demo"
            )
            run([binary], work, fixture.root / (label + "-run.log"), env=fixture.env)
        fixture.verified.extend(
            [
                "unicode_path_" + case + "_builds_and_executes_debug_release",
                "unicode_path_"
                + case
                + "_offline_reinstall_preserves_inputs_and_projects",
            ]
        )
