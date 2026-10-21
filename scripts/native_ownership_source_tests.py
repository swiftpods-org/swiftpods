#!/usr/bin/env python3
"""Regressions for local Git identity, manifest discovery and owned project cleanup."""

import json
import shutil

from bootstrap import project_state_directory
from consumer_build_regressions import update_spec
from input_contract_regressions import commit, diagnostic, git
from native_integration import project, serialize
from native_lifecycle_tests import LifecycleFixture
from native_linker_manifest_tests import application, fixture_project, podfile
from reporting import ROOT, execute
from vendor_fixture import run
from workspace_resource_regressions import add_consumer, read_project


def local_git_sources(fixture):
    for value in [1, 2]:
        work, selected = fixture_project(fixture, "relative-git-" + str(value))
        origin = work / "Kit"
        (origin / "Kit.c").write_text(
            "int kit_value(void) { return " + str(value) + "; }\n"
        )
        git(origin, "init", "-b", "main")
        revision = commit(origin, "Fixture " + str(value))
        (work / "Podfile").write_text(
            podfile().replace(":path => './Kit'", ":git => './Kit'")
        )
        child = work / "Sub"
        child.mkdir()
        if value == 1:
            fixture.cli(child, "install")
        else:
            fixture.cli(fixture.root, "install", "--project-directory", str(work))
        assert (work / "Pods/Kit/Kit.c").read_bytes() == (origin / "Kit.c").read_bytes()
        report = json.loads(
            (project_state_directory(work) / "installation.json").read_text()
        )
        checkout = report["specs"][0]["source"]
        assert checkout["git"] == "./Kit" and checkout["commit"] == revision
        locked = (work / "Podfile.lock").read_bytes()
        shutil.rmtree(work / "Pods/Kit")
        fixture.cli(child, "install", "--deployment", "--offline")
        assert (work / "Podfile.lock").read_bytes() == locked
        assert (work / "Pods/Kit/Kit.c").read_bytes() == (origin / "Kit.c").read_bytes()
        if value == 2:
            (selected.parent / "Sources/main.mm").write_text(
                "#include <Kit/Kit.h>\n"
                "int main(void) { return kit_value() == 2 ? 0 : 1; }\n"
            )
            label = "relative-git-consumer"
            fixture.build(work, "Demo", label)
            run(
                [application(fixture, label)],
                work,
                fixture.root / (label + "-run.log"),
                env=fixture.env,
            )
            (origin / "Kit.c").write_text("int kit_value(void) { return 3; }\n")
            revision = commit(origin, "Explicit update")
            fixture.cli(child, "update", "Kit")
            assert "return 3;" in (work / "Pods/Kit/Kit.c").read_text()
            report = json.loads(
                (project_state_directory(work) / "installation.json").read_text()
            )
            assert report["specs"][0]["source"]["commit"] == revision
    fixture.verified += [
        "relative_git_uses_manifest_root_from_ancestor_and_explicit_directory",
        "relative_git_cache_isolated_across_projects_and_consumer_executes",
        "local_git_raw_lock_identity_survives_offline_reinstall_and_update",
    ]


def manifest_discovery(fixture):
    work, _ = fixture_project(fixture, "manifest-directories")
    child = work / "Sub"
    child.mkdir()
    for name in [
        "CocoaPods.podfile.yaml",
        "CocoaPods.podfile",
        "Podfile",
        "Podfile.rb",
    ]:
        (child / name).mkdir()
    fixture.cli(child, "install")
    assert (work / "Podfile.lock").is_file()
    assert not (child / "Pods").exists()
    fixture.verified.append("manifest_named_directories_do_not_stop_ancestor_search")


def deintegration(fixture):
    work, selected = fixture_project(fixture, "missing-generated-project")
    original = read_project(selected)["objects"]
    root = next(
        value for value in original.values() if value.get("isa") == "PBXProject"
    )
    root.setdefault("attributes", {})
    fixture.cli(work, "install")
    shutil.rmtree(work / "Pods/Pods.xcodeproj")
    fixture.cli(work, "deintegrate")
    assert read_project(selected)["objects"] == original
    assert not (work / "Pods/Target Support Files/SwiftPods-Integration.json").exists()
    fixture.cli(work, "deintegrate")
    fixture.verified.append(
        "deintegrate_without_generated_pods_project_restores_consumer"
    )

    work, selected = fixture_project(fixture, "invalid-workspace")
    fixture.cli(work, "install")
    project_before = (selected / "project.pbxproj").read_bytes()
    receipt = work / "Pods/Target Support Files/SwiftPods-Integration.json"
    receipt_before = receipt.read_bytes()
    workspace = next(work.glob("*.xcworkspace")) / "contents.xcworkspacedata"
    valid = workspace.read_bytes()
    workspace.write_text("<Invalid/>")
    for _ in range(2):
        report = fixture.cli(work, "deintegrate", succeeds=False)
        diagnostic(report, "SP-WORKSPACE")
        assert report["project_state"] == "failed_no_managed_changes"
        assert (selected / "project.pbxproj").read_bytes() == project_before
        assert receipt.read_bytes() == receipt_before
        assert workspace.read_text() == "<Invalid/>"
    workspace.write_bytes(valid)
    fixture.cli(work, "deintegrate")
    fixture.verified.append(
        "invalid_workspace_rejects_deintegrate_before_any_project_write"
    )


def omitted_project(fixture):
    for retained in [False, True]:
        work, selected = fixture_project(fixture, "deleted-target-" + str(retained))
        (work / "Podfile").write_text(
            podfile().replace(
                "target 'Demo' do\n",
                "target 'Demo' do\n spm 'Net', :git => 'https://example.invalid/Net.git', "
                ":exact => '1.0.0', :products => ['Net']\n",
            )
        )
        fixture.cli(work, "install")
        graph = read_project(selected)
        objects = graph["objects"]
        root = objects[graph["rootObject"]]
        target = next(
            k for k, v in objects.items() if v.get("isa") == "PBXNativeTarget"
        )
        objects.pop(target)
        root["targets"].remove(target)
        package = next(
            k
            for k, v in objects.items()
            if v.get("isa") == "XCRemoteSwiftPackageReference"
        )
        if retained:
            # A user-owned product keeps using the formerly managed package.
            objects["ABC000000000000000000001"] = {
                "isa": "XCSwiftPackageProductDependency",
                "package": package,
                "productName": "UserProduct",
            }
        (selected / "project.pbxproj").write_text(
            "// !$*UTF8*$!\n" + serialize(graph) + "\n"
        )
        replacement = selected.parent / "Other.xcodeproj"
        project(replacement)
        (work / "Podfile").write_text(
            podfile().replace("External.xcodeproj", "Other.xcodeproj")
        )
        for _ in range(2):
            fixture.cli(work, "install")
            objects = read_project(selected)["objects"]
            assert (package in objects) == retained
            products = [
                v["productName"]
                for v in objects.values()
                if v.get("isa") == "XCSwiftPackageProductDependency"
            ]
            assert products == (["UserProduct"] if retained else [])
            receipt = json.loads(
                (
                    work / "Pods/Target Support Files/SwiftPods-Integration.json"
                ).read_text()
            )
            assert not any(
                k.startswith(str(selected) + "/project.pbxproj:") for k in receipt
            )
    fixture.verified.append(
        "omitted_project_with_deleted_target_removes_owned_packages_and_preserves_user_uses"
    )


def deleted_target_in_selected_project(fixture):
    work, selected = fixture_project(fixture, "deleted-target-selected-project")
    add_consumer(selected)
    (work / "Podfile").write_text(
        podfile() + "target 'Other' do\n pod 'Kit', :path => './Kit'\nend\n"
    )
    fixture.cli(work, "install")
    graph = read_project(selected)
    objects = graph["objects"]
    target = next(
        k
        for k, v in objects.items()
        if v.get("isa") == "PBXNativeTarget" and v["name"] == "Other"
    )
    configlist = objects[target]["buildConfigurationList"]
    configs = objects[configlist]["buildConfigurations"]
    for key in [configlist, *configs, *objects[target]["buildPhases"]]:
        objects.pop(key)
    objects.pop(target)
    objects[graph["rootObject"]]["targets"].remove(target)
    (selected / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(graph))
    receipt = work / "Pods/Target Support Files/SwiftPods-Integration.json"
    legacy = json.loads(receipt.read_text())
    legacy.pop("_support_configurations")
    receipt.write_text(json.dumps(legacy))
    (work / "Podfile").write_text(podfile())
    for _ in range(2):
        fixture.cli(work, "install")
        records = json.loads(receipt.read_text())
        assert not any(any(k.endswith(":" + c) for c in configs) for k in records)
        objects = read_project(selected)["objects"]
        assert not any("Pods-Other." in v.get("path", "") for v in objects.values())
    fixture.verified.append(
        "deleted_target_in_selected_project_prunes_stale_configuration_records_and_refs"
    )


def support_configuration_cleanup(fixture):
    for adopted in [False, True]:
        work, selected = fixture_project(fixture, "support-config-" + str(adopted))
        fixture.cli(work, "install")
        receipt = work / "Pods/Target Support Files/SwiftPods-Integration.json"
        records = json.loads(receipt.read_text())
        references = set(records["_support_configurations"].values())
        graph = read_project(selected)
        retained = next(iter(references))
        if adopted:
            objects = graph["objects"]
            root = objects[graph["rootObject"]]
            config = "ABC000000000000000000002"
            objects[config] = {
                "isa": "XCBuildConfiguration",
                "name": "User",
                "baseConfigurationReference": retained,
                "buildSettings": {},
            }
            objects[root["buildConfigurationList"]]["buildConfigurations"].append(
                config
            )
            (selected / "project.pbxproj").write_text(
                "// !$*UTF8*$!\n" + serialize(graph) + "\n"
            )
        # Legacy receipts have no support-reference inventory.
        records.pop("_support_configurations")
        receipt.write_text(json.dumps(records))
        fixture.cli(work, "deintegrate")
        objects = read_project(selected)["objects"]
        assert references.intersection(objects) == ({retained} if adopted else set())
    fixture.verified.append(
        "generated_xcconfig_refs_remove_with_user_bases_and_legacy_receipts_but_preserve_adopted_refs"
    )


def workspace_migration(fixture):
    work, selected = fixture_project(fixture, "workspace-migration")
    fixture.cli(work, "install")
    old = next(work.glob("*.xcworkspace")) / "contents.xcworkspacedata"
    # The nested occurrence is user-owned even with the same raw location.
    text = old.read_text().replace(
        "</Workspace>",
        '<Group location="group:Sub"><FileRef location="group:Pods/Pods.xcodeproj"/></Group>'
        '<FileRef location="group:User.xcodeproj"/></Workspace>',
    )
    old.write_text(text)
    (work / "Podfile").write_text("workspace 'Renamed'\n" + podfile())
    fixture.cli(work, "install")
    assert old.read_text().count('location="group:Pods/Pods.xcodeproj"') == 1
    assert 'location="group:User.xcodeproj"' in old.read_text()
    assert str(selected) in old.read_text()
    new = work / "Renamed.xcworkspace/contents.xcworkspacedata"
    assert 'location="group:Pods/Pods.xcodeproj"' in new.read_text()
    receipt = json.loads(
        (work / "Pods/Target Support Files/SwiftPods-Integration.json").read_text()
    )
    assert list(receipt["_workspaces"]) == [str(new)]
    old_before = old.read_bytes()
    fixture.cli(work, "install", "--deployment", "--offline")
    assert old.read_bytes() == old_before
    fixture.cli(work, "deintegrate")
    assert old.read_bytes() == old_before
    assert "Pods/Pods.xcodeproj" not in new.read_text()
    fixture.verified.append("workspace_rename_removes_only_previous_owned_references")


def selected_graph(fixture):
    for field in ["subspecs", "testspecs", "appspecs"]:
        work, _ = fixture_project(fixture, "selected-graph-" + field)
        update_spec(work, **{field: [{"name": "Extra", "source_files": "Kit.c"}]})
        (work / "Podfile").write_text(
            podfile().replace(
                ":path => './Kit'", ":path => './Kit', :" + field + " => ['Extra']"
            )
        )
        fixture.cli(work, "install")
        graph = fixture.cli(work, "why", "Kit/Extra")
        assert graph["chains_status"] == "recorded_direct_dependencies"
        assert len(graph["dependency_chains"]) == 1
        chain = graph["dependency_chains"][0]
        assert chain["target"] == "Demo" and chain["nodes"][-1]["name"] == "Kit/Extra"
    fixture.verified.append("why_records_explicit_subspec_test_and_app_selections")
    work, _ = fixture_project(fixture, "search-paths-graph")
    (work / "Podfile").write_text(
        "platform :osx, '13.0'\nproject '../Apps/External.xcodeproj'\n"
        "target 'Demo' do\n pod 'Kit', :path => './Kit'\n"
        " target 'Child' do\n  inherit! :search_paths\n end\nend\n"
    )
    fixture.cli(work, "install", "--no-integrate")
    graph = fixture.cli(work, "why", "Kit")
    assert len(graph["dependency_chains"]) == 2
    assert {chain["target"] for chain in graph["dependency_chains"]} == {
        "Demo",
        "Child",
    }
    fixture.verified.append("why_records_search_path_inherited_dependencies")


def main():
    fixture = LifecycleFixture()
    local_git_sources(fixture)
    manifest_discovery(fixture)
    deintegration(fixture)
    omitted_project(fixture)
    deleted_target_in_selected_project(fixture)
    support_configuration_cleanup(fixture)
    workspace_migration(fixture)
    selected_graph(fixture)
    (ROOT / "test-results/native-ownership-source.json").write_text(
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
    print("Passed", len(fixture.verified), "ownership/source regressions", fixture.root)


if __name__ == "__main__":
    execute(main, "native-ownership-source.json")
