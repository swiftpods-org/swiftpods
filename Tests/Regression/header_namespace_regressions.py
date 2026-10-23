"""Assert module uniqueness and fresh/reinstalled public-header equivalence."""

import json
import subprocess

from Tests.Integration.native_xcconfig_tests import create
from Tests.Regression.header_ownership_regressions import read_project, write_project
from Tests.Regression.project_path_regressions import builds


def module_fixture(parent, *, collision=True, frameworks=False, explicit=False):
    work, selected = create(parent)
    spec = work / "Kit/Kit.podspec.json"
    attributes = json.loads(spec.read_text())
    attributes["module_name"] = "Shared" if collision else "FirstModule"
    spec.write_text(json.dumps(attributes))
    (work / "Kit/Kit.h").write_text("#pragma once\n#define KIT_A 11\n")
    other = work / "Other"
    other.mkdir()
    peer = dict(
        attributes, name="Other", module_name="Shared" if collision else "SecondModule"
    )
    (other / "Other.podspec.json").write_text(json.dumps(peer))
    (other / "Other.h").write_text("#pragma once\n#define KIT_B 31\n")
    (other / "Other.c").write_text("int other_value(void) { return 31; }\n")
    podfile = work / "Podfile"
    body = podfile.read_text().split("post_install")[0]
    body = body.replace(
        "target 'Demo' do", "target 'Demo' do\n pod 'Other', :path => './Other'"
    )
    if explicit:
        body = body.replace(":path => './Kit'", ":path => './Kit', :modular_headers => true")
        body = body.replace(
            ":path => './Other'", ":path => './Other', :modular_headers => true"
        )
    else:
        body = "use_modular_headers!\n" + body
    if frameworks:
        body = "use_frameworks! :linkage => :static\n" + body
    podfile.write_text(body)
    graph = read_project(selected)
    for obj in graph["objects"].values():
        if obj.get("isa") == "XCBuildConfiguration":
            obj["buildSettings"]["CLANG_ENABLE_MODULES"] = "YES"
        if obj.get("isa") == "PBXFileReference" and obj.get("path") == "Sources/main.mm":
            obj["path"] = "Sources/main.m"
            obj["lastKnownFileType"] = "sourcecode.c.objc"
    write_project(selected, graph)
    old = selected.parent / "Sources/main.mm"
    old.unlink()
    old.with_suffix(".m").write_text(
        ("@import Shared;\n" if collision else "@import FirstModule;\n@import SecondModule;\n")
        + "#if KIT_A != 11 || KIT_B != 31\n#error Module API was lost\n#endif\n"
        + "int main(void) { return 0; }\n"
    )
    return work, selected


def public_fixture(parent, *, fresh):
    work, selected = create(parent)
    spec = work / "Kit/Kit.podspec.json"
    attributes = json.loads(spec.read_text())
    attributes["public_header_files"] = "Public*.h"
    spec.write_text(json.dumps(attributes))
    if fresh:
        (work / "Kit/PublicAPI.h").write_text("#pragma once\n#define PUBLIC_API 11\n")
    return work, selected


def compile_old_header(work, log):
    roots = [p for p in (work / "Pods/Headers/Public").rglob("Kit") if p.is_dir()]
    assert len(roots) == 1, roots
    source = work / "visibility-probe.c"
    source.write_text("#include <Kit/Kit.h>\nint probe(void) { return kit_value(); }\n")
    command = [
        "xcrun", "clang", "-fsyntax-only", "-Werror", "-I", str(roots[0].parent), str(source)
    ]
    result = subprocess.run(command, cwd=work, capture_output=True, text=True, timeout=60)
    log.write_text(result.stdout + result.stderr)
    assert result.returncode >= 0, log
    return result.returncode, roots[0]


def module_conflict(fixture, *, explicit=False, frameworks=False):
    label = "header-module-" + (
        "framework" if frameworks else "explicit" if explicit else "global"
    )
    work, selected = module_fixture(
        fixture.root / label, frameworks=frameworks, explicit=explicit
    )
    before = (selected / "project.pbxproj").read_bytes()
    rejected = fixture.cli(work, "install", succeeds=False)
    assert any(
        e.get("code") == "SP-XCODE-MODULE-CONFLICT" for e in rejected["events"]
    ), rejected
    assert (selected / "project.pbxproj").read_bytes() == before
    assert not (work / "Podfile.lock").exists()
    fixture.verified.append(label + "_rejected_before_consumer_write")


def distinct_modules(fixture):
    label = "header-modules-distinct"
    work, _ = module_fixture(fixture.root / label, collision=False)
    fixture.cli(work, "install")
    fixture.cli(work, "install", "--offline", "--deployment")
    builds(fixture, work, label)
    fixture.verified.append("distinct_modular_libraries_build_and_run_debug_release")


def public_selection(fixture, *, fresh=False):
    label = "public-selection-" + ("fresh" if fresh else "reinstall")
    work, selected = public_fixture(fixture.root / label, fresh=fresh)
    authored = (work / "Kit/Kit.h").read_bytes()
    spec = (work / "Kit/Kit.podspec.json").read_bytes()
    fixture.cli(work, "install")
    if not fresh:
        status, initial = compile_old_header(work, fixture.root / (label + "-initial.log"))
        assert status == 0
        (work / "Kit/PublicAPI.h").write_text("#pragma once\n#define PUBLIC_API 11\n")
        fixture.cli(work, "install", "--offline", "--deployment")
    status, public = compile_old_header(work, fixture.root / (label + "-final.log"))
    if not fresh:
        assert initial == public
    assert (public / "PublicAPI.h").exists()
    assert (work / "Kit/Kit.h").read_bytes() == authored
    assert (work / "Kit/Kit.podspec.json").read_bytes() == spec
    assert status != 0, "The current public-header selection still exposes Kit/Kit.h"
    assert "Kit/Kit.h" in (fixture.root / (label + "-final.log")).read_text()
    assert not (public / "Kit.h").is_symlink()
    before = (selected / "project.pbxproj").read_bytes()
    fixture.cli(work, "install", "--offline", "--deployment")
    assert (selected / "project.pbxproj").read_bytes() == before
    fixture.verified.append(label + "_hides_unselected_header")


def run_regressions(fixture):
    cases = [
        ("global-module-conflict", lambda: module_conflict(fixture)),
        ("explicit-module-conflict", lambda: module_conflict(fixture, explicit=True)),
        ("framework-module-control", lambda: module_conflict(fixture, frameworks=True)),
        ("distinct-module-control", lambda: distinct_modules(fixture)),
        ("fresh-public-selection", lambda: public_selection(fixture, fresh=True)),
        ("reinstalled-public-selection", lambda: public_selection(fixture)),
    ]
    results = []
    for name, run in cases:
        print("Header invariant:", name, flush=True)
        try:
            run()
            results.append({"case": name, "status": "passed"})
        except (AssertionError, RuntimeError) as error:
            results.append({"case": name, "status": "failed", "error": str(error)})
    (fixture.root / "header-invariants.json").write_text(
        json.dumps(results, indent=2) + "\n"
    )
    failed = [r["case"] for r in results if r["status"] == "failed"]
    assert not failed, "Header invariant failures: " + ", ".join(failed)


def main():
    from scripts.support.local_build import results_directory
    from Tests.Integration.native_lifecycle_tests import LifecycleFixture

    fixture = LifecycleFixture()
    print("Header invariant fixtures:", fixture.root, flush=True)
    run_regressions(fixture)
    (results_directory() / "native-header-invariants.json").write_text(
        json.dumps(
            {"status": "passed", "fixture": str(fixture.root), "verified": fixture.verified},
            indent=2,
        ) + "\n"
    )


if __name__ == "__main__":
    from scripts.support.reporting import execute

    execute(main, "native-header-invariants.json")
