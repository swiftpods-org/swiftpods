"""Include paths are validated before URL conversion and optional-file checks."""

import json

from Tests.Integration.native_xcconfig_tests import create
from Tests.Regression.name_boundary_regressions import diagnostic
from Tests.Regression.project_path_regressions import builds, reinstall


def negative_paths(fixture):
    for optional in [False, True]:
        for existing_alias in [False, True]:
            for nested in [False, True]:
                label = (
                    ("optional" if optional else "required")
                    + ("-alias" if existing_alias else "-missing")
                    + ("-nested" if nested else "-direct")
                )
                work, selected = create(fixture.root / ("include-nul-" + label))
                base = selected.parent / "Configs/Base.xcconfig"
                invalid = base.with_name("Child.xcconfig") if nested else base
                if nested:
                    base.write_text(base.read_text() + '#include "Child.xcconfig"\n')
                invalid.write_text(
                    "// first line\n#include"
                    + ("?" if optional else "")
                    + ' "Leaf\0Ignored.xcconfig"\n'
                )
                alias = base.with_name("Leaf%00Ignored.xcconfig")
                if existing_alias:
                    alias.write_text("AUDIT_INCLUDE = wrong\n")
                podfile = work / "Podfile"
                podfile.write_text(
                    podfile.read_text()
                    + "pre_install { |_| File.write('pre-hook-ran', 'yes') }\n"
                )
                originals = {
                    p: p.read_bytes()
                    for p in [
                        podfile,
                        selected / "project.pbxproj",
                        work / "Kit/Kit.podspec.json",
                        base,
                        invalid,
                        *([alias] if existing_alias else []),
                    ]
                }
                result = fixture.cli(work, "install", succeeds=False)
                assert diagnostic(result, "SP-XCCONFIG-INCLUDE"), result
                assert any(
                    e.get("code") == "SP-XCCONFIG-INCLUDE"
                    and e.get("file") == str(invalid)
                    and e.get("line") == 2
                    for e in result["events"]
                ), result
                assert result["project_state"] == "failed_no_managed_changes", result
                assert all(p.read_bytes() == before for p, before in originals.items())
                assert not (work / "pre-hook-ran").exists()
                assert (
                    not (work / "Pods").exists()
                    and not (work / "Podfile.lock").exists()
                )
                fixture.verified.append(
                    "xcconfig_include_nul_" + label + "_early_rejection"
                )


def positive_paths(fixture):
    for optional in [False, True]:
        for spelling, name in [
            ("percent", "Leaf%00Ignored.xcconfig"),
            ("unicode", "\u0301Leaf東京.xcconfig"),
        ]:
            label = spelling + ("-optional" if optional else "-required")
            work, selected = create(fixture.root / ("include-valid-" + label))
            base = selected.parent / "Configs/Base.xcconfig"
            base.write_text(
                base.read_text()
                + "#include"
                + ("?" if optional else "")
                + ' "'
                + name
                + '"\n'
            )
            child = base.with_name(name)
            child.write_text("AUDIT_INCLUDE = selected\n")
            podfile = work / "Podfile"
            podfile.write_text(
                podfile.read_text().replace("'SDKROOT', true", "'AUDIT_INCLUDE', true")
            )
            originals = {p: p.read_bytes() for p in [base, child, podfile]}
            fixture.cli(work, "install")
            assert json.loads((work / "resolved-settings.json").read_text()) == {
                "Debug": "selected",
                "Release": "selected",
            }
            reinstall(fixture, work, selected)
            assert all(p.read_bytes() == before for p, before in originals.items())
            fixture.verified.append("xcconfig_include_valid_" + label + "_idempotent")
            builds(fixture, work, "include-valid-" + label)
            fixture.verified.append(
                "xcconfig_include_valid_" + label + "_debug_release_consumers"
            )


def run_regressions(fixture):
    negative_paths(fixture)
    positive_paths(fixture)
