"""Source strings cannot alias literal percent paths through embedded NUL."""

import json
import shutil

from input_contract_regressions import commit, git
from name_boundary_regressions import diagnostic
from native_xcconfig_tests import create
from project_path_regressions import builds, reinstall

DEPENDENCY_KEYS = [
    "path",
    "podspec",
    "git",
    "http",
    "svn",
    "hg",
    "branch",
    "tag",
    "commit",
    "revision",
    "folder",
    "source",
    "project_name",
    "sha1",
    "sha256",
    "type",
]
SPEC_KEYS = [
    "git",
    "http",
    "svn",
    "hg",
    "branch",
    "tag",
    "commit",
    "revision",
    "folder",
    "sha1",
    "sha256",
    "type",
]


def ruby(value):
    if isinstance(value, dict):
        return (
            "{"
            + ", ".join(
                json.dumps(key, ensure_ascii=False) + " => " + ruby(item)
                for key, item in value.items()
            )
            + "}"
        )
    return json.dumps(value, ensure_ascii=False)


def headers_cases():
    return [
        ("header-name", {"headers": {"X-Field\0Ignored": "value"}}),
        ("header-value", {"headers": {"X-Field": "before\0after"}}),
    ]


def assert_rejected(fixture, work, selected, spec, arguments, action):
    inputs = [work / "Podfile", spec, selected / "project.pbxproj"]
    originals = {p: p.read_bytes() for p in inputs}
    result = fixture.cli(work, *arguments, succeeds=False)
    assert diagnostic(result, "SP-DSL-POD-OPTION"), result
    assert result["project_state"] == (
        "untracked" if action == "quick" else "failed_no_managed_changes"
    ), result
    assert all(p.read_bytes() == before for p, before in originals.items())
    assert not (work / "pre-hook-ran").exists()
    assert not (spec.parent / "prepare-ran").exists()
    assert not (work / "Pods").exists() and not (work / "Podfile.lock").exists()


def negative_declarations(fixture):
    cases = [(key, {key: "before\0after"}) for key in DEPENDENCY_KEYS] + headers_cases()
    for label, options in cases:
        work, selected = create(fixture.root / ("source-option-nul-" + label))
        library = work / "Kit"
        if label == "path":
            library = work / "Kit%00Ignored"
            (work / "Kit").rename(library)
            options = {"path": "./Kit\0Ignored"}
        spec = library / "Kit.podspec.json"
        attributes = json.loads(spec.read_text())
        attributes["prepare_command"] = "printf ran > prepare-ran"
        spec.write_text(json.dumps(attributes))
        actual = {"path": "./Kit"}
        actual.update(options)
        declaration = "pod 'Kit', " + ", ".join(
            ":" + key + " => " + ruby(value) for key, value in actual.items()
        )
        podfile = work / "Podfile"
        podfile.write_text(
            podfile.read_text().replace("pod 'Kit', :path => './Kit'", declaration)
            + "pre_install { |_| File.write('pre-hook-ran', 'yes') }\n"
        )
        assert_rejected(fixture, work, selected, spec, ["install"], "install")
        fixture.verified.append(
            "source_option_nul_" + label + "_rejected_before_hooks_and_writes"
        )
    for label, options in [
        (key, {key: "before\0after"}) for key in SPEC_KEYS
    ] + headers_cases():
        work, selected = create(fixture.root / ("source-spec-nul-" + label))
        spec = work / "Kit/Kit.podspec.json"
        attributes = json.loads(spec.read_text())
        source = {"git": "https://example.invalid/Kit.git"}
        source.update(options)
        attributes.update(source=source, prepare_command="printf ran > prepare-ran")
        spec.write_text(json.dumps(attributes))
        podfile = work / "Podfile"
        podfile.write_text(
            podfile.read_text()
            + "pre_install { |_| File.write('pre-hook-ran', 'yes') }\n"
        )
        for action, arguments in [
            ("quick", ["spec", "lint", str(spec), "--quick"]),
            ("install", ["install"]),
        ]:
            assert_rejected(fixture, work, selected, spec, arguments, action)
            fixture.verified.append(
                "source_spec_nul_"
                + label
                + "_"
                + action
                + "_rejected_before_hooks_and_writes"
            )


def catalog_fixture(parent, nul):
    work, selected = create(parent)
    library = work / "Kit"
    spec = library / "Kit.podspec.json"
    data = json.loads(spec.read_text())
    data["source"] = {"git": str(library), "tag": "1.0"}
    spec.write_text(json.dumps(data))
    git(library, "init", "-b", "main")
    commit(library, "literal percent catalog")
    git(library, "tag", "1.0")
    target = work / "Specs%00Ignored/Kit/1.0"
    target.mkdir(parents=True)
    shutil.copy2(spec, target / spec.name)
    source = "./Specs\0Ignored" if nul else "./Specs%00Ignored"
    podfile = work / "Podfile"
    podfile.write_text(
        "source "
        + ruby(source)
        + "\n"
        + podfile.read_text().replace(", :path => './Kit'", "")
    )
    return work, selected, target / spec.name


def catalog_boundary(fixture):
    work, selected, spec = catalog_fixture(fixture.root / "global-source-nul", True)
    podfile = work / "Podfile"
    podfile.write_text(
        podfile.read_text() + "pre_install { |_| File.write('pre-hook-ran', 'yes') }\n"
    )
    assert_rejected(fixture, work, selected, spec, ["install"], "install")
    fixture.verified.append("global_source_nul_cannot_select_literal_percent_catalog")


def positive_paths(fixture):
    for label in ["percent", "unicode", "catalog"]:
        if label == "catalog":
            work, selected, spec = catalog_fixture(
                fixture.root / "source-valid-catalog", False
            )
        else:
            work, selected = create(fixture.root / ("source-valid-" + label))
            name = "Kit%00Ignored" if label == "percent" else "\u0301Kit"
            library = work / name
            (work / "Kit").rename(library)
            spec = library / "Kit.podspec.json"
            podfile = work / "Podfile"
            podfile.write_text(
                podfile.read_text().replace("'./Kit'", ruby("./" + name))
            )
        original = spec.read_bytes()
        fixture.cli(work, "install")
        reinstall(fixture, work, selected)
        assert spec.read_bytes() == original
        fixture.verified.append(
            "source_valid_" + label + "_offline_reinstall_preserves_inputs_and_projects"
        )
        builds(fixture, work, "source-valid-" + label)
        fixture.verified.append(
            "source_valid_" + label + "_debug_release_consumers_execute"
        )


def run_regressions(fixture):
    negative_declarations(fixture)
    catalog_boundary(fixture)
    positive_paths(fixture)
