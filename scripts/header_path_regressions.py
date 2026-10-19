"""Header namespace and mapping paths retain filesystem separator boundaries."""

import json

from name_boundary_regressions import diagnostic
from native_xcconfig_tests import create
from project_path_regressions import builds, reinstall


def run_regressions(fixture):
    for field in ["header_dir", "header_mappings_dir"]:
        for mode, prefix in [("absolute", "/"), ("traversal", "../")]:
            for unicode in [False, True]:
                label = field + "-" + mode + ("-unicode" if unicode else "-ascii")
                work, selected = create(fixture.root / ("header-path-" + label))
                spec = work / "Kit/Kit.podspec.json"
                original = spec.read_bytes()
                attributes = json.loads(original)
                name = ("\u0301" if unicode else "") + "Headers"
                attributes[field] = prefix + name
                if field == "header_mappings_dir":
                    headers = work / "Kit" / name
                    headers.mkdir()
                    (work / "Kit/Kit.h").rename(headers / "Kit.h")
                    attributes["source_files"] = "**/*.{c,h}"
                spec.write_text(json.dumps(attributes))
                input_spec = spec.read_bytes()
                selected_bytes = (selected / "project.pbxproj").read_bytes()
                rejected = fixture.cli(work, "install", succeeds=False)
                assert diagnostic(rejected, "SP-SPEC-HEADER-MAPPING"), rejected
                assert (selected / "project.pbxproj").read_bytes() == selected_bytes
                if rejected.get("project_state") == "recovery_required":
                    fixture.cli(work, "recover")
                assert (selected / "project.pbxproj").read_bytes() == selected_bytes
                fixture.verified.append("header_path_rejects_" + label)
                assert spec.read_bytes() == input_spec
        work, selected = create(fixture.root / ("header-path-valid-" + field))
        spec = work / "Kit/Kit.podspec.json"
        attributes = json.loads(spec.read_text())
        attributes[field] = "\u0301Headers"
        if field == "header_mappings_dir":
            directory = work / "Kit/\u0301Headers"
            directory.mkdir()
            (work / "Kit/Kit.h").rename(directory / "Kit.h")
            attributes["source_files"] = "**/*.{c,h}"
        else:
            main = selected.parent / "Sources/main.mm"
            main.write_text(
                main.read_text().replace("<Kit/Kit.h>", "<\u0301Headers/Kit.h>")
            )
        spec.write_text(json.dumps(attributes))
        original = spec.read_bytes()
        fixture.cli(work, "install")
        reinstall(fixture, work, selected)
        assert spec.read_bytes() == original
        builds(fixture, work, "header-path-valid-" + field)
        fixture.verified.extend(
            [
                "unicode_" + field + "_builds_and_executes_debug_release",
                "unicode_" + field + "_offline_reinstall_preserves_inputs_and_projects",
            ]
        )
