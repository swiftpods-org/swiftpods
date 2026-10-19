#!/usr/bin/env python3
"""Exercise catalog selection, local VCS identity, compiler settings and modules."""

import json
import shutil
import subprocess

from consumer_build_regressions import update_spec
from input_contract_regressions import commit, diagnostic, git
from native_integration import serialize
from native_lifecycle_tests import LifecycleFixture
from native_linker_manifest_tests import application, fixture_project, podfile
from reporting import ROOT, execute
from vendor_fixture import fixture_derived_data, run
from workspace_resource_regressions import add_consumer, read_project


def mercurial(fixture):
    def hg(origin, *args):
        return subprocess.check_output(
            ["hg", *args],
            cwd=origin,
            env=fixture.env,
            stderr=subprocess.STDOUT,
            text=True,
        ).strip()

    fixture.env["HGRCPATH"] = ""
    for value in [1, 2]:
        work, _ = fixture_project(fixture, "local-hg-" + str(value))
        origin = work / "Kit"
        (origin / "Kit.c").write_text(
            "int kit_value(void) { return " + str(value) + "; }\n"
        )
        hg(origin, "init")
        hg(origin, "add")
        hg(origin, "commit", "-u", "Fixture <tests@example.invalid>", "-m", "Fixture")
        revision = hg(origin, "log", "-r", ".", "--template", "{node}")
        (work / "Podfile").write_text(
            podfile().replace(":path => './Kit'", ":hg => './Kit'")
        )
        child = work / "Sub"
        child.mkdir()
        fixture.cli(child, "install")
        report = json.loads((work / ".swiftpods/installation.json").read_text())
        assert report["specs"][0]["source"] == {"hg": "./Kit", "revision": revision}
        assert (work / "Pods/Kit/Kit.c").read_bytes() == (origin / "Kit.c").read_bytes()
        locked = (work / "Podfile.lock").read_bytes()
        shutil.rmtree(work / "Pods/Kit")
        fixture.cli(
            fixture.root,
            "install",
            "--project-directory",
            str(work),
            "--deployment",
            "--offline",
        )
        assert (work / "Podfile.lock").read_bytes() == locked
        assert (work / "Pods/Kit/Kit.c").read_bytes() == (origin / "Kit.c").read_bytes()
        if value == 2:
            (origin / "Kit.c").write_text("int kit_value(void) { return 3; }\n")
            hg(
                origin,
                "commit",
                "-u",
                "Fixture <tests@example.invalid>",
                "-m",
                "Update",
            )
            fixture.cli(child, "update", "Kit")
            assert "return 3;" in (work / "Pods/Kit/Kit.c").read_text()
    fixture.cli(work, "cache", "verify")
    fixture.verified += [
        "relative_hg_sources_resolve_from_manifest_and_isolate_shared_cache",
        "hg_raw_lock_identity_survives_offline_alias_reinstall_and_explicit_update",
    ]


def catalog_selection(fixture):
    work, selected = fixture_project(fixture, "catalog-selection")
    origin = work / "Kit"
    git(origin, "init", "-b", "main")
    revision = commit(origin, "Fixture")
    spec = json.loads((origin / "Kit.podspec.json").read_text())
    spec["source"] = {"git": str(origin), "commit": revision}
    for version in ["1.0", "2.0", "3.0"]:
        folder = work / "specs/Kit" / version
        folder.mkdir(parents=True)
        (folder / "Kit.podspec").write_text(
            "File.write('unselected-ruby-ran', 'yes'); raise 'Do not evaluate'\n"
        )
        if version != "3.0":
            (folder / "Kit.podspec.json").write_text(
                json.dumps(spec) if version == "1.0" else "{ invalid json"
            )
    pinned = "source './specs'\n" + podfile().replace(
        "pod 'Kit', :path => './Kit'", "pod 'Kit', '= 1.0'"
    )
    (work / "Podfile").write_text(pinned)
    fixture.cli(work, "install")
    locked = (work / "Podfile.lock").read_bytes()
    fixture.cli(work, "install", "--deployment", "--offline")
    assert (work / "Podfile.lock").read_bytes() == locked
    assert not (work / "unselected-ruby-ran").exists()
    report = fixture.cli(work, "outdated")
    pods = next(
        event["pods"] for event in report["events"] if event["kind"] == "outdated"
    )
    assert pods[0]["latest"] == "3.0" and pods[0]["available"] == "1.0"
    before = (selected / "project.pbxproj").read_bytes()
    (work / "Podfile").write_text(pinned.replace("'= 1.0'", "'= 2.0'"))
    fixture.cli(work, "update", succeeds=False)
    assert (work / "Podfile.lock").read_bytes() == locked
    assert (selected / "project.pbxproj").read_bytes() == before
    spec.update(name="Peer", version="2.0")
    (work / "specs/Kit/2.0/Kit.podspec.json").write_text(json.dumps(spec))
    diagnostic(fixture.cli(work, "update", succeeds=False), "SP-SOURCE-IDENTITY")
    assert not (work / "unselected-ruby-ran").exists()
    fixture.verified += [
        "catalog_pins_ignore_malformed_and_executable_unselected_specs_and_prefer_json",
        "selected_catalog_payload_errors_and_identity_mismatches_fail_before_consumer_changes",
    ]


def directory_podspec(fixture):
    work, selected = fixture_project(fixture, "directory-podspec")
    origin = work / "Kit"
    git(origin, "init", "-b", "main")
    revision = commit(origin, "Fixture")
    folder = work / "Metadata with spaces"
    folder.mkdir()
    (folder / "Kit.podspec").write_text(
        "Pod::Spec.new do |s|\n s.name='Kit'\n s.version='1.0'\n s.source={:git => "
        + repr(str(origin))
        + ", :commit => "
        + repr(revision)
        + "}\n s.source_files='*.{c,h}'\nend\n"
    )
    (work / "Podfile").write_text(
        podfile().replace(":path => './Kit'", ":podspec => './Metadata with spaces'")
    )
    (selected.parent / "Sources/main.mm").write_text(
        "#include <Kit/Kit.h>\nint main(void) { return kit_value() == 7 ? 0 : 1; }\n"
    )
    child = work / "Sub"
    child.mkdir()
    fixture.cli(child, "install")
    fixture.cli(child, "install", "--deployment", "--offline")
    label = "directory-podspec-consumer"
    fixture.build(work, "Demo", label)
    run(
        [application(fixture, label)],
        work,
        fixture.root / (label + "-run.log"),
        env=fixture.env,
    )
    fixture.verified.append(
        "directory_podspec_with_spaces_resolves_builds_and_executes_offline"
    )


def compiler_settings(fixture):
    for mode in ["library", "dynamic"]:
        work, selected = fixture_project(fixture, "compiler-settings-" + mode)
        update_spec(
            work,
            compiler_flags="-DLIB_ADDED=1",
            pod_target_xcconfig={"OTHER_CFLAGS": "$(inherited) -DLIB_KEPT=1"},
            appspecs=[
                {
                    "name": "Example",
                    "source_files": "Example/*.c",
                    "compiler_flags": "-DAPP_ADDED=1",
                    "pod_target_xcconfig": {
                        "OTHER_CFLAGS": "$(inherited) -DAPP_KEPT=1"
                    },
                }
            ],
        )
        (work / "Kit/Kit.c").write_text(
            "#if !defined(LIB_KEPT) || !defined(LIB_ADDED)\n#error Library_flags_were_lost\n#endif\nint kit_value(void) { return 7; }\n"
        )
        (work / "Kit/Example").mkdir()
        (work / "Kit/Example/main.c").write_text(
            "#if !defined(APP_KEPT) || !defined(APP_ADDED)\n#error App_flags_were_lost\n#endif\nextern int kit_value(void);\nint main(void) { return kit_value() == 7 ? 0 : 1; }\n"
        )
        text = podfile().replace(
            ":path => './Kit'", ":path => './Kit', :appspecs => ['Example']"
        )
        (work / "Podfile").write_text(
            ("use_frameworks!\n" if mode == "dynamic" else "") + text
        )
        (selected.parent / "Sources/main.mm").write_text(
            'extern "C" int kit_value(void);\nint main(void) { return kit_value() == 7 ? 0 : 1; }\n'
        )
        fixture.cli(work, "install")
        fixture.cli(work, "install", "--deployment", "--offline")
        label = "compiler-consumer-" + mode
        fixture.build(work, "Demo", label)
        run(
            [application(fixture, label)],
            work,
            fixture.root / (label + "-run.log"),
            env=fixture.env,
        )
        label = "compiler-example-" + mode
        # Xcode preview/debug linkers share a dependency-info path for this C
        # app. Serialize them to avoid concurrent writes; keep debug dylibs on.
        fixture.build(work, "Kit-Example", label, jobs=1)
        app = (
            fixture_derived_data(fixture.root / label)
            / "Build/Products/Debug/Kit-Example.app/Contents/MacOS/Kit-Example"
        )
        run([app], work, fixture.root / (label + "-run.log"), env=fixture.env)
        fixture.verified.append(
            "compiler_and_xcconfig_flags_both_compile_and_execute_library_and_app_"
            + mode
        )


def peer_spec(work):
    update_spec(work, module_name="Shared")
    (work / "Kit/Kit.c").write_text("int kit_value(void) { return 1; }\n")
    peer = work / "Peer"
    peer.mkdir()
    (peer / "Peer.c").write_text("int peer_value(void) { return 2; }\n")
    spec = json.loads((work / "Kit/Kit.podspec.json").read_text())
    spec.update(name="Peer", source_files="*.c")
    (peer / "Peer.podspec.json").write_text(json.dumps(spec))


def module_products(fixture):
    for mode in ["dynamic", "static"]:
        work, selected = fixture_project(fixture, "module-conflict-" + mode)
        peer_spec(work)
        before = (selected / "project.pbxproj").read_bytes()
        (work / "Podfile").write_text(
            "use_frameworks! :linkage => :"
            + mode
            + "\n"
            + podfile().replace(
                " pod 'Kit'", " pod 'Peer', :path => './Peer'\n pod 'Kit'"
            )
            + "pre_install { |_| File.write('hook-ran', 'yes') }\n"
        )
        diagnostic(
            fixture.cli(work, "install", succeeds=False), "SP-XCODE-MODULE-CONFLICT"
        )
        assert (selected / "project.pbxproj").read_bytes() == before
        assert not (work / "hook-ran").exists()
        work, selected = fixture_project(fixture, "independent-modules-" + mode)
        peer_spec(work)
        add_consumer(selected)
        graph = read_project(selected)
        objects = graph["objects"]
        other = next(
            v
            for v in objects.values()
            if v.get("isa") == "PBXNativeTarget" and v["name"] == "Other"
        )
        reference = "ABC000000000000000000003"
        source = selected.parent / "Sources/other.mm"
        source.write_text(
            'extern "C" int peer_value(void);\nint main(void) { return peer_value() == 2 ? 0 : 1; }\n'
        )
        objects[reference] = {
            "isa": "PBXFileReference",
            "path": str(source),
            "sourceTree": "<absolute>",
            "lastKnownFileType": "sourcecode.cpp.objcpp",
        }
        for phase in other["buildPhases"]:
            if objects[phase].get("isa") == "PBXSourcesBuildPhase":
                for build in objects[phase]["files"]:
                    objects[build]["fileRef"] = reference
        (selected / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(graph))
        (selected.parent / "Sources/main.mm").write_text(
            'extern "C" int kit_value(void);\nint main(void) { return kit_value() == 1 ? 0 : 1; }\n'
        )
        (work / "Podfile").write_text(
            "use_frameworks! :linkage => :"
            + mode
            + "\n"
            + podfile()
            + "target 'Other' do\n pod 'Peer', :path => './Peer'\nend\n"
        )
        fixture.cli(work, "install")
        fixture.cli(work, "install", "--deployment", "--offline")
        for scheme in ["Demo", "Other"]:
            label = "independent-" + mode + "-" + scheme
            fixture.build(work, scheme, label)
            app = fixture_derived_data(fixture.root / label) / (
                "Build/Products/Debug/" + scheme + ".app/Contents/MacOS/" + scheme
            )
            run([app], work, fixture.root / (label + "-run.log"), env=fixture.env)
        fixture.verified.append(
            "conflicting_modules_reject_before_hooks_and_independent_consumers_execute_"
            + mode
        )


def yaml_booleans(fixture):
    work, _ = fixture_project(fixture, "yaml-booleans")
    path = work / "Bad.podfile.yaml"
    for key in ["set_arc_compatibility_flag", "generate_bridge_support"]:
        path.write_text(key + ': "false"\ntarget_definitions:\n- name: Demo\n')
        diagnostic(
            fixture.cli(work, "ipc", "podfile", str(path), succeeds=False),
            "SP-DSL-ERROR",
        )
    fixture.verified.append("yaml_string_false_rejects_before_enabling_build_flags")


def main():
    fixture = LifecycleFixture()
    mercurial(fixture)
    catalog_selection(fixture)
    directory_podspec(fixture)
    compiler_settings(fixture)
    module_products(fixture)
    yaml_booleans(fixture)
    (ROOT / "test-results/native-catalog-module.json").write_text(
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
    print("Passed", len(fixture.verified), "catalog/module regressions", fixture.root)


if __name__ == "__main__":
    execute(main, "native-catalog-module.json")
