"""CLI regressions for hook ownership, SDK contexts and shared Git checkouts."""

import hashlib
import json
import shutil
import subprocess

from Tests.Fixtures.swift_package_fixture import create as create_package
from Tests.Integration.native_integration import project, serialize
from Tests.Integration.native_xcconfig_tests import create
from Tests.Regression.source_revision_regressions import concurrent_source_refresh, deleted_svn_path


def read_project(path):
    return json.loads(
        subprocess.check_output(
            ["plutil", "-convert", "json", "-o", "-", str(path / "project.pbxproj")]
        )
    )


def write_project(path, graph):
    (path / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(graph))


def target(graph, name="Demo"):
    return next(
        value
        for value in graph["objects"].values()
        if value.get("isa") == "PBXNativeTarget" and value["name"] == name
    )


def diagnostics(result):
    return [
        event.get("code") for event in result["events"] if event["kind"] == "diagnostic"
    ]


def package_hooks_and_deintegration(fixture):
    for explicit_save in [False, True]:
        work, selected = create(fixture.root / ("package-hook-" + str(explicit_save)))
        manual_url = create_package(work / "ManualPackage", name="Manual")
        net_url = create_package(work / "NetPackage")
        graph = read_project(selected)
        objects = graph["objects"]
        manual = {
            "A" * 24: {
                "isa": "XCRemoteSwiftPackageReference",
                "repositoryURL": manual_url,
                "requirement": {"kind": "exactVersion", "version": "1.0.0"},
            },
            "B" * 24: {
                "isa": "XCSwiftPackageProductDependency",
                "package": "A" * 24,
                "productName": "Manual",
            },
            "C" * 24: {"isa": "PBXBuildFile", "productRef": "B" * 24},
        }
        objects.update(manual)
        objects[graph["rootObject"]]["packageReferences"] = ["A" * 24]
        target(graph)["packageProductDependencies"] = ["B" * 24]
        phase = next(
            objects[key]
            for key in target(graph)["buildPhases"]
            if objects[key]["isa"] == "PBXFrameworksBuildPhase"
        )
        phase["files"].append("C" * 24)
        write_project(selected, graph)
        body = (work / "Podfile").read_text().split("post_install")[0]
        body = body.replace(
            "target 'Demo' do\n",
            "target 'Demo' do\n"
            " spm 'Net', :git => " + repr(net_url) + ", :exact => '1.0.0', :products => ['Net']\n",
        )
        hook = """post_integrate do |installer|
  installer.aggregate_targets.each do |aggregate|
    aggregate.user_targets.each do |target|
      target.frameworks_build_phase.files.each do |file|
        next unless file.product_ref&.product_name == 'Net'
        file.settings = { 'ATTRIBUTES' => ['Weak'], 'COMPILER_FLAGS' => nil }
      end
    end
    SAVE_PROJECT
  end
end
""".replace("SAVE_PROJECT", "aggregate.user_project.save" if explicit_save else "")
        (work / "Podfile").write_text(body + hook)
        for _ in range(2):
            fixture.cli(work, "install")
            graph = read_project(selected)
            objects = graph["objects"]
            product = next(
                key
                for key, value in objects.items()
                if value.get("isa") == "XCSwiftPackageProductDependency"
                and value["productName"] == "Net"
            )
            build = next(
                key
                for key, value in objects.items()
                if value.get("productRef") == product
            )
            assert objects[build]["settings"] == {
                "ATTRIBUTES": ["Weak"],
                "COMPILER_FLAGS": "",
            }
        # A real external edit must fail before managed writes and remain intact.
        objects[build]["settings"]["ATTRIBUTES"].append("ExternalEdit")
        write_project(selected, graph)
        failure = fixture.cli(work, "install", succeeds=False)
        assert "SP-SPM-CONFLICT" in diagnostics(failure)
        assert failure["project_state"] == "failed_no_managed_changes"
        assert read_project(selected)["objects"][build]["settings"]["ATTRIBUTES"] == [
            "Weak",
            "ExternalEdit",
        ]
        objects[build]["settings"]["ATTRIBUTES"].remove("ExternalEdit")
        write_project(selected, graph)
        # Removing a consumer can leave an empty ownership record for a project
        # that the user later deletes. It no longer needs to be opened or edited.
        archive = work / "Pods/Target Support Files/SwiftPods-Integration.json"
        records = json.loads(archive.read_text())
        removed_project = str(work / "Removed.xcodeproj/project.pbxproj")
        records["_swift_packages"][removed_project] = {
            "objects": {},
            "targets": {},
            "phases": {},
        }
        archive.write_text(json.dumps(records))
        fixture.cli(work, "deintegrate")
        graph = read_project(selected)
        objects = graph["objects"]
        assert all(objects[key] == value for key, value in manual.items())
        assert objects[graph["rootObject"]]["packageReferences"] == ["A" * 24]
        assert target(graph)["packageProductDependencies"] == ["B" * 24]
        assert not any(
            value.get("productName") == "Net"
            or value.get("repositoryURL") == net_url
            or value.get("productRef") == product
            for value in objects.values()
        )
        assert not (
            work / "Pods/Target Support Files/SwiftPods-Integration.json"
        ).exists()
    fixture.verified += [
        "package_hook_changes_survive_reinstall_and_explicit_save",
        "package_hook_nil_compiler_flags_survive_reinstall_and_deintegration",
        "external_package_edits_rejected_before_managed_changes",
        "deintegrate_removes_owned_packages_preserves_manual_packages",
    ]


def late_sdk_context(fixture):
    work, selected = create(fixture.root / "late-sdk")
    graph = read_project(selected)
    for value in graph["objects"].values():
        if value.get("isa") == "XCBuildConfiguration":
            for key in ["SDKROOT", "MACOSX_DEPLOYMENT_TARGET"]:
                value["buildSettings"].pop(key, None)
    write_project(selected, graph)
    configs = selected.parent / "Configs"
    (configs / "Minimum.xcconfig").write_text(
        "MACOSX_DEPLOYMENT_TARGET = 13.0\nMACOSX_DEPLOYMENT_TARGET[sdk=macosx*] = 14.0\n"
    )
    (configs / "Base.xcconfig").write_text(
        '#include "Minimum.xcconfig"\nSDKROOT = macosx\nGCC_PREPROCESSOR_DEFINITIONS = $(inherited) USER_CONFIG=1\n'
    )
    spec = work / "Kit/Kit.podspec.json"
    data = json.loads(spec.read_text())
    data["platforms"]["osx"] = "14.0"
    spec.write_text(json.dumps(data))
    body = (
        (work / "Podfile")
        .read_text()
        .split("post_install")[0]
        .replace("platform :osx, '13.0'\n", "")
    )
    (work / "Podfile").write_text(
        body
        + """post_install do |installer|
  aggregate = installer.aggregate_targets.first
  raise 'wrong inferred platform' unless aggregate.platform.deployment_target.to_s == '14.0'
  values = aggregate.user_targets.first.resolved_build_setting('MACOSX_DEPLOYMENT_TARGET', true)
  raise 'wrong hook settings' unless values.values.uniq == ['14.0']
end
"""
    )
    fixture.cli(work, "install")
    result = subprocess.run(
        [
            "xcodebuild",
            "-project",
            str(selected),
            "-target",
            "Demo",
            "-configuration",
            "Debug",
            "-showBuildSettings",
            "-json",
        ],
        cwd=work,
        env=fixture.env,
        capture_output=True,
        text=True,
        timeout=90,
    )
    (fixture.root / "late-sdk-settings.log").write_text(result.stdout + result.stderr)
    assert result.returncode == 0
    assert (
        json.loads(result.stdout)[0]["buildSettings"]["MACOSX_DEPLOYMENT_TARGET"]
        == "14.0"
    )
    fixture.build(work, "Demo", "late-sdk-build")
    fixture.verified.append("late_sdk_include_matches_xcode_hooks_and_build")


def package_module_scope(fixture):
    work, selected = create(fixture.root / "package-scope")
    other = selected.parent / "Other.xcodeproj"
    project(other)
    graph = read_project(other)
    target(graph)["name"] = "Other"
    for value in graph["objects"].values():
        if value.get("isa") == "XCBuildConfiguration":
            value["buildSettings"]["ALWAYS_SEARCH_USER_PATHS"] = "NO"
    write_project(other, graph)
    body = (work / "Podfile").read_text().split("post_install")[0]
    (work / "Podfile").write_text(
        body
        + """target 'Other' do
 project '../Apps/Other.xcodeproj'
 spm 'Net', :git => 'https://example.invalid/Net.git', :exact => '1.0.0', :products => ['Kit']
end
"""
    )
    fixture.cli(work, "install")
    fixture.cli(work, "install")
    assert any(
        value.get("productName") == "Kit"
        and value.get("isa") == "XCSwiftPackageProductDependency"
        for value in read_project(other)["objects"].values()
    )
    for attribute in ["header_dir", "module_name"]:
        for product_name, selected in [
            ("Shared", "Other"), ("Shared", "Shared"),
            ("Tools", "Other"), ("Tools", "Shared"),
        ]:
            work, _ = create(
                fixture.root / ("duplicate-" + attribute + "-" + product_name + "-" + selected)
            )
            spec = work / "Kit/Kit.podspec.json"
            data = json.loads(spec.read_text())
            data[attribute] = "Shared"
            spec.write_text(json.dumps(data))
            package_url = create_package(work / "Package", name=product_name, module=selected)
            body = (work / "Podfile").read_text().split("post_install")[0]
            body = body.replace(
                "target 'Demo' do\n",
                "use_frameworks! :linkage => :static\ntarget 'Demo' do\n"
                " spm 'Net', :git => " + repr(package_url)
                + ", :exact => '1.0.0', :products => [" + repr(product_name) + "]\n",
            )
            (work / "Podfile").write_text(body)
            if selected == "Shared":
                assert "SP-DUPLICATE-SDK" in diagnostics(fixture.cli(work, "install", succeeds=False))
            else:
                fixture.cli(work, "install")
                fixture.cli(work, "install", "--deployment", "--offline")
    fixture.verified += [
        "package_duplicate_check_scoped_to_consumer",
        "package_duplicate_check_uses_actual_module_name",
        "package_product_name_can_match_a_different_pod_module",
        "package_duplicate_check_runs_when_product_and_module_names_differ",
    ]


def git_alias_cleanup(fixture):
    work, _ = create(fixture.root / "git-alias")
    source = work / "Kit"
    for args in [
        ["init"],
        ["add", "."],
        [
            "-c",
            "user.name=SwiftPods Tests",
            "-c",
            "user.email=tests@example.invalid",
            "commit",
            "-m",
            "fixture",
        ],
        ["tag", "1.0"],
    ]:
        subprocess.run(
            ["git", "-C", str(source), *args], check=True, capture_output=True
        )
    body = (work / "Podfile").read_text().split("post_install")[0]
    (work / "Podfile").write_text(
        body.replace(
            ":path => './Kit'", ":git => " + repr(str(source)) + ", :tag => '1.0'"
        )
    )
    # Keep this case's cache independent of the other lifecycle fixtures.
    previous = fixture.env["SWIFTPODS_CACHE_ROOT"]
    fixture.env["SWIFTPODS_CACHE_ROOT"] = str(work / "cache")
    try:
        fixture.cli(work, "install")
        entries = fixture.cli(work, "cache", "list", "Kit")["entries"]
        assert len([entry for entry in entries if entry["kind"] == "git"]) == 2
        assert all(entry["pods"] == ["Kit"] for entry in entries)
        fixture.cli(work, "cache", "clean", "Kit")
        assert fixture.cli(work, "cache", "list")["entries"] == []
        source.rename(work / "unavailable-origin")
        shutil.rmtree(work / "Pods/Kit")
        failure = fixture.cli(work, "install", "--offline", succeeds=False)
        assert "SP-OFFLINE-MISSING" in diagnostics(failure)
    finally:
        fixture.env["SWIFTPODS_CACHE_ROOT"] = previous
    fixture.verified.append("named_cleanup_removes_git_selector_and_commit_copies")


def run(fixture):
    package_hooks_and_deintegration(fixture)
    late_sdk_context(fixture)
    package_module_scope(fixture)
    git_alias_cleanup(fixture)
    snapshot_alias_cleanup(fixture)
    concurrent_source_refresh(fixture)
    deleted_svn_path(fixture)


def snapshot_alias_cleanup(fixture):
    for vcs in ["hg", "svn"]:
        for refresh in ["none", "same", "new"]:
            _snapshot_alias_cleanup(fixture, vcs, refresh)


def _snapshot_alias_cleanup(fixture, vcs, refresh):
    root = fixture.root / (vcs + "-shared-alias-" + refresh)
    source = root / "source"
    source.mkdir(parents=True)
    (source / "Library.c").write_text("int library(void) { return 7; }\n")
    for name in ["A", "B"]:
        (source / (name + ".podspec.json")).write_text(json.dumps({
            "name": name, "version": "1.0", "source_files": "*.c", "platforms": {"osx": "13.0"},
        }))
    if vcs == "hg":
        subprocess.run(["hg", "init", str(source)], check=True, capture_output=True)
        subprocess.run(["hg", "--cwd", str(source), "add"], check=True, capture_output=True)
        subprocess.run(["hg", "--cwd", str(source), "commit", "-u", "Fixture", "-m", "source"],
                       check=True, capture_output=True)
        origin = str(source)
    else:
        repository = root / "origin"
        subprocess.run(["svnadmin", "create", str(repository)], check=True, capture_output=True)
        origin = repository.as_uri()
        subprocess.run(["svn", "import", str(source), origin, "-m", "source"], check=True, capture_output=True)
    cache = root / "cache"
    previous = fixture.env["SWIFTPODS_CACHE_ROOT"]
    fixture.env["SWIFTPODS_CACHE_ROOT"] = str(cache)
    try:
        for name in ["A", "B"]:
            work = root / name
            work.mkdir()
            (work / "Podfile").write_text(
                "install! 'swiftpods', :integrate_targets => false\nplatform :osx, '13.0'\n"
                "target 'App' do\n pod " + repr(name) + ", :" + vcs + " => " + repr(origin) + "\nend\n")
            fixture.cli(work, "install")
        receipts = list((cache / "snapshots").glob("*.origin.json"))
        assert len(receipts) == 2
        assert all(json.loads(path.read_text())["pod_names"] == ["A", "B"] for path in receipts)
        if refresh != "none":
            # Simulate older installations: peers were present only on the selector copy.
            selector = hashlib.sha256(json.dumps({vcs: origin}, sort_keys=True, indent=2,
                                                 separators=(",", " : ")).encode()).hexdigest()
            assert (cache / "snapshots" / (selector + ".origin.json")).exists()
            for path in receipts:
                if path.name == selector + ".origin.json":
                    continue
                metadata = json.loads(path.read_text())
                metadata["pod_names"] = ["A"]
                path.write_text(json.dumps(metadata))
            if refresh == "new":
                if vcs == "hg":
                    (source / "Library.c").write_text("int library(void) { return 9; }\n")
                    subprocess.run(["hg", "--cwd", str(source), "commit", "-u", "Fixture", "-m", "next"],
                                   check=True, capture_output=True)
                else:
                    checkout = root / "svn-working"
                    subprocess.run(["svn", "checkout", origin, str(checkout)], check=True, capture_output=True)
                    (checkout / "Library.c").write_text("int library(void) { return 9; }\n")
                    subprocess.run(["svn", "commit", str(checkout), "-m", "next"], check=True, capture_output=True)
            fixture.cli(root / "A", "update", "A", "--no-repo-update")
        # Prove offline availability without registering B on the original revision alias.
        control = root / "control-cache"
        shutil.copytree(cache, control)
        fixture.env["SWIFTPODS_CACHE_ROOT"] = str(control)
        fixture.cli(root / "B", "install", "--offline", "--deployment")
        fixture.env["SWIFTPODS_CACHE_ROOT"] = str(cache)
        fixture.cli(root / "A", "cache", "clean", "A")
        lock = (root / "B/Podfile.lock").read_bytes()
        shutil.rmtree(root / "B/Pods")
        fixture.cli(root / "B", "install", "--offline", "--deployment")
        assert (root / "B/Podfile.lock").read_bytes() == lock
        fixture.cli(root / "B", "cache", "clean", "B")
        assert fixture.cli(root / "B", "cache", "list")["entries"] == []
        fixture.verified.append(vcs + "_named_cleanup_preserves_other_pods_pinned_offline_snapshot_" + refresh)
    finally:
        fixture.env["SWIFTPODS_CACHE_ROOT"] = previous
