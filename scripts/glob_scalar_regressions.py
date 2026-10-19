"""Glob metacharacters are scalar syntax, even before combining marks."""

import json

from native_xcconfig_tests import create
from project_path_regressions import builds, reinstall

CASES = {
    "star": ("*\u0301.c", ["q\u0301.c"]),
    "question": ("?\u0301.c", ["q\u0301.c"]),
    "class-close": ("[q]\u0301.c", ["q\u0301.c"]),
    "class-open": ("[\u0301q].c", ["q.c", "\u0301.c"]),
    "brace": ("{\u0301Folder,Other}/*.c", ["\u0301Folder/q.c", "Other/q.c"]),
    "recursive": ("**/\u0301Kit.c", ["\u0301Kit.c", "Nested/\u0301Kit.c"]),
    "escape": ("\\\u0301q.c", ["\u0301q.c"]),
}

QUERY = """pre_install do |installer|
  accessor = installer.pod_targets.first.file_accessors.first
  File.write('scalar-glob.json', JSON.generate(accessor.source_files.map { |p| p.relative_path_from(accessor.root).to_s }.sort))
end
"""


def fixture_case(parent, case):
    pattern, names = CASES[case]
    work, selected = create(parent)
    library = work / "Kit"
    (library / "Kit.c").unlink()
    for index, name in enumerate(names):
        path = library / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("int fixture_" + str(index) + "(void) { return 7; }\n")
    support = library / "Support/Entry.c"
    support.parent.mkdir()
    support.write_text(
        "".join(
            "int fixture_" + str(index) + "(void);\n" for index in range(len(names))
        )
        + "int kit_value(void) { return "
        + " && ".join(
            "fixture_" + str(index) + "() == 7" for index in range(len(names))
        )
        + " ? 7 : -1; }\n"
    )
    (library / "Poison.c").write_text("#error Unselected_glob_source_was_compiled\n")
    spec = library / "Kit.podspec.json"
    attributes = json.loads(spec.read_text())
    attributes["source_files"] = ["Kit.h", "Support/Entry.c", pattern]
    spec.write_text(json.dumps(attributes))
    podfile = work / "Podfile"
    podfile.write_text(podfile.read_text() + QUERY)
    return work, selected, sorted(["Kit.h", "Support/Entry.c", *names])


def observation(work, expected):
    paths = json.loads((work / "scalar-glob.json").read_text())
    assert paths == expected, (paths, expected)
    return paths


def scalar_parity(parent, engines, native, reference):
    results = {}
    for case in CASES:
        results[case] = {}
        for engine in engines:
            work, _, expected = fixture_case(
                parent / ("scalar-glob-" + case + "-" + engine), case
            )
            spec = work / "Kit/Kit.podspec.json"
            original = spec.read_bytes()
            (native if engine == "native" else reference)(work, "install")
            results[case][engine] = observation(work, expected)
            assert spec.read_bytes() == original
        if "reference" in engines:
            assert results[case]["native"] == results[case]["reference"]
    return results


def run_regressions(fixture):
    for case in CASES:
        work, selected, expected = fixture_case(
            fixture.root / ("scalar-build-" + case), case
        )
        spec = work / "Kit/Kit.podspec.json"
        original = spec.read_bytes()
        fixture.cli(work, "install")
        observation(work, expected)
        reinstall(fixture, work, selected)
        assert spec.read_bytes() == original
        builds(fixture, work, "scalar-glob-" + case)
        fixture.verified.extend(
            [
                "scalar_glob_" + case + "_builds_and_executes_debug_release",
                "scalar_glob_"
                + case
                + "_offline_reinstall_preserves_inputs_and_projects",
            ]
        )
