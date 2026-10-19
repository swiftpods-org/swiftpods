"""Malformed OS strings fail before hooks, preparation and project writes."""

import json

from name_boundary_regressions import diagnostic
from native_xcconfig_tests import create


def run_regressions(fixture):
    cases = [
        (key, {key: "Path\0Suffix"}, "SP-SPEC-PATH")
        for key in [
            "source_files",
            "exclude_files",
            "resources",
            "preserve_paths",
            "public_header_files",
            "private_header_files",
            "project_header_files",
            "vendored_frameworks",
            "vendored_libraries",
            "header_dir",
            "header_mappings_dir",
            "prefix_header_file",
            "module_map",
            "readme",
            "requires_arc",
        ]
    ]
    cases += [
        ("pattern-array", {"source_files": ["*.c", "Headers\0Suffix"]}, "SP-SPEC-PATH"),
        (
            "bundle-pattern",
            {"resource_bundles": {"Own": ["Assets\0Suffix"]}},
            "SP-SPEC-PATH",
        ),
        (
            "bundle-name",
            {"resource_bundles": {"Own\0Suffix": ["Assets"]}},
            "SP-SPEC-PATH",
        ),
        (
            "odr-pattern",
            {"on_demand_resources": {"tag": {"paths": ["Assets\0Suffix"]}}},
            "SP-SPEC-PATH",
        ),
        (
            "license-file",
            {"license": {"type": "MIT", "file": "LICENSE\0Suffix"}},
            "SP-SPEC-PATH",
        ),
        (
            "prepare-command",
            {"prepare_command": "printf ran > prepare-ran\0printf ignored"},
            "SP-SPEC-SCRIPT",
        ),
    ]
    cases += [
        (
            "phase-" + key,
            {
                "script_phases": [
                    {"name": "Phase", "script": "true", key: ["Path\r\nSuffix"]}
                ]
            },
            "SP-SCRIPT-SCHEMA",
        )
        for key in [
            "input_files",
            "output_files",
            "input_file_lists",
            "output_file_lists",
        ]
    ]
    for label, attributes, code in cases:
        work, selected = create(fixture.root / ("path-input-" + label))
        spec = work / "Kit/Kit.podspec.json"
        data = json.loads(spec.read_text())
        data["prepare_command"] = "printf ran > prepare-ran"
        data.update(attributes)
        spec.write_text(json.dumps(data))
        original_spec = spec.read_bytes()
        original_project = (selected / "project.pbxproj").read_bytes()
        podfile = work / "Podfile"
        podfile.write_text(
            podfile.read_text()
            + "pre_install { |_| File.write('pre-hook-ran', 'yes') }\n"
        )
        rejected = fixture.cli(work, "install", succeeds=False)
        assert diagnostic(rejected, code), (label, rejected)
        assert rejected["project_state"] == "failed_no_managed_changes", (
            label,
            rejected,
        )
        assert not (work / "pre-hook-ran").exists()
        assert not (work / "Kit/prepare-ran").exists()
        assert not (work / "Podfile.lock").exists() and not (work / "Pods").exists()
        assert (selected / "project.pbxproj").read_bytes() == original_project
        assert spec.read_bytes() == original_spec
        fixture.verified.append(
            "path_input_rejects_" + label + "_before_hooks_and_project_writes"
        )
