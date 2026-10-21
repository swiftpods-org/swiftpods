"""Pod identity and CLI value separators before Unicode combining marks."""

import json

from scripts.support.bootstrap import project_state_directory
from Tests.Integration.native_xcconfig_tests import create
from Tests.Regression.project_path_regressions import builds, reinstall

CASES = ["direct", "nested", "default"]

QUERY = """pre_install do |installer|
  values = installer.pod_targets.flat_map(&:file_accessors).reject { |a| a.source_files.empty? }.map do |a|
    {'name' => a.spec.name, 'files' => a.source_files.map { |p| p.relative_path_from(a.root).to_s }.sort}
  end
  File.write('unicode-names.json', JSON.generate(values.sort_by { |v| v['name'] }))
end
"""


def name_fixture(parent, case):
    work, selected = create(parent)
    spec = work / "Kit/Kit.podspec.json"
    attributes = json.loads(spec.read_text())
    attributes.pop("source_files")
    child = {"name": "\u0301Core", "source_files": "*.{c,h}"}
    leaf = "Kit/\u0301Core"
    if case == "nested":
        child.pop("source_files")
        child["subspecs"] = [{"name": "\u0301Nested", "source_files": "*.{c,h}"}]
        leaf += "/\u0301Nested"
    attributes["subspecs"] = [child]
    if case == "default":
        attributes["default_subspecs"] = ["\u0301Core"]
    spec.write_text(json.dumps(attributes))
    podfile = work / "Podfile"
    declaration = podfile.read_text().replace(
        "pod 'Kit',", "pod '" + ("Kit" if case == "default" else leaf) + "',"
    )
    if case == "direct":
        declaration = (
            "install! 'cocoapods', :generate_multiple_pod_projects => true\n"
            + declaration.replace(
                ":path => './Kit'", ":path => './Kit', :project_name => '\u0301Library'"
            )
        )
    podfile.write_text(declaration + QUERY)
    return work, selected, leaf


def observation(work, leaf):
    actual = json.loads((work / "unicode-names.json").read_text())
    assert actual == [{"name": leaf, "files": ["Kit.c", "Kit.h"]}], actual
    return actual


def name_parity(parent, engines, native, reference):
    observations = {}
    for case in CASES:
        observations[case] = {}
        for engine in engines:
            work, _, leaf = name_fixture(
                parent / ("name-boundary-" + case + "-" + engine), case
            )
            spec = work / "Kit/Kit.podspec.json"
            original = spec.read_bytes()
            (native if engine == "native" else reference)(work, "install")
            observations[case][engine] = observation(work, leaf)
            assert spec.read_bytes() == original
        if "reference" in engines:
            assert observations[case]["native"] == observations[case]["reference"]
    return observations


def diagnostic(report, code):
    return any(
        event.get("code") == code
        for event in report.get("events", []) + [report.get("diagnostic", {})]
    )


def cli_directories(fixture):
    for label, inline, name in [
        ("ascii-inline", True, "work"),
        ("unicode-inline", True, "\u0301work"),
        ("unicode-split", False, "\u0301work"),
    ]:
        base = fixture.root / ("cli-directory-" + label)
        work, selected = create(base)
        (work / "Podfile").write_text(
            "platform :osx, '13.0'\ntarget('Demo') { pod 'Kit', :path => './Kit' }\n"
        )
        if name != "work":
            destination = base / name
            work.rename(destination)
            work = destination
        before = (selected / "project.pbxproj").read_bytes()
        options = (
            ["--project-directory=" + name] if inline else ["--project-directory", name]
        )
        fixture.cli(base, "install", "--no-integrate", *options)
        assert (project_state_directory(work) / "state.json").is_file()
        assert not project_state_directory(base).exists()
        lock = (work / "Podfile.lock").read_bytes()
        fixture.cli(
            base, "install", "--no-integrate", "--deployment", "--offline", *options
        )
        assert (work / "Podfile.lock").read_bytes() == lock
        assert (selected / "project.pbxproj").read_bytes() == before
    for label, options in [
        (
            "duplicate",
            ["--project-directory=\u0301work", "--project-directory", "work"],
        ),
        ("empty", ["--project-directory="]),
        ("missing", ["--project-directory"]),
    ]:
        base = fixture.root / ("cli-directory-invalid-" + label)
        work, selected = create(base)
        before = (selected / "project.pbxproj").read_bytes()
        rejected = fixture.cli(
            base, "install", "--no-integrate", *options, succeeds=False
        )
        assert diagnostic(rejected, "SP-CLI-ARGUMENT"), rejected
        assert not project_state_directory(base).exists()
        assert not project_state_directory(work).exists()
        assert (selected / "project.pbxproj").read_bytes() == before
    fixture.verified.extend(
        [
            "unicode_inline_and_split_project_directories_install_and_reinstall_without_wrong_directory_state",
            "invalid_project_directory_options_fail_before_state_creation",
        ]
    )


def run_regressions(fixture):
    cli_directories(fixture)
    for case in CASES:
        work, selected, leaf = name_fixture(fixture.root / ("name-build-" + case), case)
        spec = work / "Kit/Kit.podspec.json"
        original = spec.read_bytes()
        fixture.cli(work, "install")
        observation(work, leaf)
        if case == "direct":
            assert (work / "Pods/\u0301Library.xcodeproj/project.pbxproj").is_file()
        reinstall(fixture, work, selected)
        assert spec.read_bytes() == original
        builds(fixture, work, "name-boundary-" + case)
        fixture.verified.extend(
            [
                "unicode_subspec_" + case + "_builds_and_executes_debug_release",
                "unicode_subspec_"
                + case
                + "_offline_reinstall_preserves_inputs_and_projects",
            ]
        )
    work, _, _ = name_fixture(fixture.root / "name-lint-interface", "default")
    library = work / "Kit"
    (library / "LICENSE").write_text("MIT License\n")
    header = library / "Kit.h"
    original_header = header.read_bytes()
    header.write_text("#error Unicode_subspec_public_header_must_be_checked\n")
    failed = fixture.cli(
        work,
        "lib",
        "lint",
        str(library / "Kit.podspec.json"),
        "--platforms=osx",
        "--use-libraries",
        succeeds=False,
    )
    validation = next(
        event["data"] for event in failed["events"] if event["kind"] == "validation"
    )
    assert validation[
        "status"
    ] == "failed" and "Unicode_subspec_public_header_must_be_checked" in json.dumps(
        validation
    ), validation
    header.write_bytes(original_header)
    fixture.cli(
        work,
        "lib",
        "lint",
        str(library / "Kit.podspec.json"),
        "--platforms=osx",
        "--use-libraries",
    )
    fixture.verified.append(
        "unicode_subspec_lint_checks_public_headers_and_accepts_corrected_interface"
    )
    work, selected = create(fixture.root / "name-invalid-generated-project")
    podfile = work / "Podfile"
    podfile.write_text(
        "install! 'cocoapods', :generate_multiple_pod_projects => true\n"
        + podfile.read_text().replace(
            ":path => './Kit'",
            ":path => './Kit', :project_name => 'Library/\u0301Nested'",
        )
    )
    before = (selected / "project.pbxproj").read_bytes()
    rejected = fixture.cli(work, "install", succeeds=False)
    assert diagnostic(rejected, "SP-XCODE-PROJECT"), rejected
    assert (selected / "project.pbxproj").read_bytes() == before
    if rejected.get("project_state") == "recovery_required":
        fixture.cli(work, "recover")
    fixture.verified.append(
        "generated_project_names_reject_slash_before_combining_marks"
    )
