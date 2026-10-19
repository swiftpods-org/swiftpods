"""Glob character classes, path boundaries and complete-name selection."""

import json
import platform
import unicodedata

from native_xcconfig_tests import create
from vendor_fixture import fixture_build_arguments, fixture_derived_data, run

GRID_FILES = [
    "a.c",
    "b.c",
    "c.c",
    "d.c",
    "1.c",
    "&.c",
    "].c",
    "z.c",
    "-.c",
    "[Source.c",
    "]Source.c",
    "AqPoison.c",
    "AXPoison.c",
    "A/Poison.c",
    "Tail.c",
    "Tail.c\n",
    "Tail.c\r",
    "Tail.c\r\n",
    "Tail.c\u2028",
    "AqHeader.h",
    "A/Header.h",
    "payload.txt",
    "payload.txt\n",
    "payload.txt\r\n",
    "é.c",
    "ê.c",
    "\u0301.c",
    "Folderé/\u0301Source.c",
]

CLASS_CASES = [
    ("negated", "A[!X]Poison.c", ["AqPoison.c"], []),
    ("caret-negated", "A[^X]Poison.c", ["AqPoison.c"], []),
    ("positive-slash", "A[/q]Poison.c", ["AqPoison.c"], []),
    ("literal-opening", "[[]Source.c", ["[Source.c"], ["]Source.c"]),
    ("literal-set", "[a&&b].c", ["&.c", "a.c", "b.c"], ["].c"]),
    ("escaped-letter", r"[\d].c", ["d.c"], ["].c"]),
    ("escaped-closing", r"[a\]b].c", ["].c", "a.c", "b.c"], []),
    ("empty-positive", "[]].c", [], []),
    (
        "empty-negated",
        "[!].c",
        [
            "&.c",
            "-.c",
            "1.c",
            "].c",
            "a.c",
            "b.c",
            "c.c",
            "d.c",
            "z.c",
            "é.c",
            "ê.c",
            "\u0301.c",
        ],
        [],
    ),
    ("descending-range", "[z-a].c", ["a.c", "z.c"], []),
    ("ordinary-range", "[a-c].c", ["a.c", "b.c", "c.c"], []),
    ("complete-name", "Tail.c", ["Tail.c"], []),
    ("unicode-literal", "é.c", ["é.c"], []),
    ("unicode-class", "[é].c", ["é.c"], ["].c"]),
    ("unicode-range", "[é-ê].c", ["é.c", "ê.c"], []),
    ("unicode-components", "Folderé/*", ["Folderé/\u0301Source.c"], []),
]

FILE_QUERY = """post_install do |installer|
  accessor = installer.pod_targets.first.file_accessors.first
  values = %w[source_files public_headers private_headers resources].to_h do |key|
    [key, accessor.public_send(key).map { |path| path.relative_path_from(accessor.root).to_s }.sort]
  end
  File.write('glob-files.json', JSON.generate(values))
end
"""


def spec_values(work, values):
    path = work / "Kit/Kit.podspec.json"
    data = json.loads(path.read_text())
    data.update(values)
    path.write_text(json.dumps(data))
    return path


def character_class_parity(parent, engines, native, reference):
    cases = []
    for label, pattern, selected, extra in CLASS_CASES:
        expected = {
            "source_files": sorted(["Kit.h", *selected]),
            "public_headers": ["Kit.h"],
            "private_headers": [],
            "resources": [],
        }
        reference_expected = dict(
            expected, source_files=sorted([*expected["source_files"], *extra])
        )
        cases.append(
            (label, {"source_files": ["Kit.h", pattern]}, expected, reference_expected)
        )
    for label, pattern, selected, reference_selected in [
        ("literal-casefold", "[A].c", ["a.c"], ["].c"]),
        (
            "mixed-ascending",
            "[A-z].c",
            ["a.c", "b.c", "c.c", "d.c", "z.c"],
            ["a.c", "b.c", "c.c", "d.c", "z.c"],
        ),
        ("mixed-descending", "[Z-a].c", ["a.c", "z.c"], ["a.c"]),
        ("mixed-descending-other", "[z-A].c", ["a.c", "z.c"], ["z.c"]),
    ]:
        expected = {
            "source_files": sorted(["Kit.h", *selected]),
            "public_headers": ["Kit.h"],
            "private_headers": [],
            "resources": [],
        }
        reference_expected = dict(
            expected, source_files=sorted(["Kit.h", *reference_selected])
        )
        cases.append(
            (label, {"source_files": ["Kit.h", pattern]}, expected, reference_expected)
        )
    cases += [
        (
            "exclusions",
            {
                "source_files": ["Kit.h", "AqPoison.c", "A/Poison.c"],
                "exclude_files": "A[!X]Poison.c",
            },
            {
                "source_files": ["A/Poison.c", "Kit.h"],
                "public_headers": ["Kit.h"],
                "private_headers": [],
                "resources": [],
            },
            None,
        ),
        (
            "visibility",
            {
                "source_files": ["Kit.h", "AqHeader.h", "A/Header.h"],
                "private_header_files": "A[!X]Header.h",
            },
            {
                "source_files": ["A/Header.h", "AqHeader.h", "Kit.h"],
                "public_headers": ["A/Header.h", "Kit.h"],
                "private_headers": ["AqHeader.h"],
                "resources": [],
            },
            None,
        ),
        (
            "resource-name",
            {"source_files": ["Kit.h", "Kit.c"], "resources": "payload.txt"},
            {
                "source_files": ["Kit.c", "Kit.h"],
                "public_headers": ["Kit.h"],
                "private_headers": [],
                "resources": ["payload.txt"],
            },
            None,
        ),
    ]
    observations = {}
    for label, attributes, expected, reference_expected in cases:
        row = {"input": attributes, "expected": expected}
        for engine in engines:
            work, _ = create(parent / ("glob-" + label + "-" + engine))
            for name in GRID_FILES:
                file = work / "Kit" / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text("")
            source = spec_values(work, attributes)
            original = source.read_bytes()
            (work / "Podfile").write_text(
                "platform :osx, '13.0'\ninstall! 'cocoapods', :integrate_targets => false\n"
                "target('Demo') { pod 'Kit', :path => './Kit' }\n" + FILE_QUERY
            )
            (native if engine == "native" else reference)(work, "install")
            assert source.read_bytes() == original
            raw = json.loads((work / "glob-files.json").read_text())
            # Compare canonical filesystem identities; retain the raw hook paths.
            actual = {
                key: sorted(unicodedata.normalize("NFC", value) for value in values)
                for key, values in raw.items()
            }
            wanted = (
                (reference_expected or expected) if engine == "reference" else expected
            )
            assert actual == wanted, (label, engine, actual, wanted)
            row[engine] = actual
            row[engine + "_raw"] = raw
        observations[label] = row
    return observations


def build_fixture(parent, case):
    work, selected = create(parent)
    library = work / "Kit"
    values = {}
    if case == "source-boundary":
        (library / "Kit.c").rename(library / "AqPoison.c")
        (library / "A").mkdir()
        (library / "A/Poison.c").write_text("#error Glob_crossed_directory_separator\n")
        values = {"source_files": ["Kit.h", "A[!X]Poison.c"]}
    elif case == "exclude-boundary":
        (library / "Skip").mkdir()
        (library / "Kit.c").write_text(
            "extern int nested_value(void);\nint kit_value(void) { return nested_value(); }\n"
        )
        (library / "Skip/Poison.c").write_text("int nested_value(void) { return 7; }\n")
        (library / "SkipqPoison.c").write_text(
            "#error Explicitly_excluded_source_was_compiled\n"
        )
        values = {
            "source_files": ["Kit.h", "Kit.c", "Skip/*.c", "SkipqPoison.c"],
            "exclude_files": "Skip[!X]Poison.c",
        }
    elif case == "literal-opening":
        (library / "Kit.c").rename(library / "[Source.c")
        (library / "]Source.c").write_text(
            "#error Closing_delimiter_is_not_a_class_member\n"
        )
        values = {"source_files": ["Kit.h", "[[]Source.c"]}
    elif case == "mixed-range":
        (library / "Kit.c").rename(library / "aSource.c")
        (library / "_Source.c").write_text(
            "#error Mixed_case_range_selected_punctuation\n"
        )
        values = {"source_files": ["Kit.h", "[A-z]Source.c"]}
    elif case == "unicode-name":
        (library / "Kit.c").rename(library / "éSource.c")
        values = {"source_files": ["Kit.h", "[é]Source.c"]}
    elif case == "resource-name":
        for suffix in ["", "\n", "\r\n", "\u2028"]:
            (library / ("payload.txt" + suffix)).write_text(
                "selected" if not suffix else "unwanted"
            )
        values = {"resources": "payload.txt", "frameworks": ["Foundation"]}
        (selected.parent / "Sources/main.mm").write_text(
            "#import <Foundation/Foundation.h>\n#include <Kit/Kit.h>\n"
            "int main(void) { @autoreleasepool {\n"
            "NSString *root = [[NSBundle mainBundle] resourcePath];\n"
            "NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:root error:NULL];\n"
            'if (kit_value() != 7 || ![names containsObject:@"payload.txt"]) return 1;\n'
            'NSData *data = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"payload.txt"]];\n'
            'if (![data isEqualToData:[@"selected" dataUsingEncoding:NSUTF8StringEncoding]]) return 3;\n'
            "for (NSString *name in names) {\n"
            ' if ([name hasPrefix:@"payload.txt"] && ![name isEqualToString:@"payload.txt"]) return 2;\n'
            "}\nreturn 0; } }\n"
        )
    else:
        raise AssertionError(case)
    spec_values(work, values)
    return work, selected


def character_class_builds(fixture):
    for case in [
        "source-boundary",
        "exclude-boundary",
        "literal-opening",
        "mixed-range",
        "unicode-name",
        "resource-name",
    ]:
        work, selected = build_fixture(fixture.root / ("glob-build-" + case), case)
        fixture.cli(work, "install")
        locked = (work / "Podfile.lock").read_bytes()
        project = (selected / "project.pbxproj").read_bytes()
        fixture.cli(work, "install", "--deployment", "--offline")
        assert (work / "Podfile.lock").read_bytes() == locked
        assert (selected / "project.pbxproj").read_bytes() == project
        for configuration in ["Debug", "Release"]:
            label = "glob-" + case + "-" + configuration
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
        fixture.verified += [
            "glob_" + case + "_builds_and_executes_debug_release",
            "glob_" + case + "_offline_reinstall_preserves_project_and_lock",
        ]
