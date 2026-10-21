"""Repository refresh, source pinning, file matching and generated Ruby inputs."""

import functools
import hashlib
import http.server
import json
import platform
import shutil
import subprocess
import threading
import zipfile
from contextlib import contextmanager

from Tests.Fixtures.vendor_fixture import fixture_build_arguments, fixture_derived_data
from Tests.Integration.native_xcconfig_tests import create
from Tests.Regression.consumer_build_regressions import podfile, update_spec
from Tests.Regression.input_contract_regressions import (
    commit,
    diagnostic,
    git,
    save_project,
)
from Tests.Regression.workspace_resource_regressions import read_project


@contextmanager
def serve(root):
    requests = []

    class Handler(http.server.SimpleHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            super().do_GET()

        def log_message(self, *arguments):
            pass

    server = http.server.ThreadingHTTPServer(
        ("127.0.0.1", 0), functools.partial(Handler, directory=str(root))
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield "http://127.0.0.1:" + str(server.server_port) + "/", requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def installed_version(report, name):
    return next(
        item["version"]
        for event in report["events"]
        if event["kind"] == "installation"
        for item in event["specs"]
        if item["name"] == name
    )


def unintegrated_manifest(work, source, name="Kit", requirement=None, parallel=False):
    (work / "Podfile").write_text(
        "install! 'swiftpods', :integrate_targets => false, :parallel_pod_downloads => "
        + ("true" if parallel else "false")
        + "\nsource "
        + repr(str(source))
        + "\nplatform :osx, '13.0'\ntarget 'Demo' do\n pod "
        + repr(name)
        + (", " + repr(requirement) if requirement else "")
        + "\nend\n"
    )


def write_spec(catalog, version, source, name="Kit"):
    path = catalog / name / version / (name + ".podspec.json")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(
            {"name": name, "version": version, "source": source, "source_files": "*.c"}
        )
    )


def repository_refresh(fixture):
    work, _ = create(fixture.root / "repository-refresh")
    origin = work / "Kit"
    git(origin, "init", "-b", "main")
    revision = commit(origin, "source")
    catalog = work / "specs"
    catalog.mkdir()
    git(catalog, "init", "-b", "main")
    source = {"git": str(origin), "commit": revision}
    write_spec(catalog, "1.0", source)
    commit(catalog, "initial catalog")
    fixture.cli(work, "repo", "add", "audit11-catalog", str(catalog), "main")
    unintegrated_manifest(work, catalog)
    fixture.cli(work, "install")
    locked = (work / "Podfile.lock").read_bytes()
    write_spec(catalog, "1.1", source)
    commit(catalog, "new version")
    # Explicit metadata refresh must preserve the installed version and its source.
    report = fixture.cli(work, "install", "--repo-update", "--deployment")
    assert installed_version(report, "Kit") == "1.0"
    assert (work / "Podfile.lock").read_bytes() == locked
    assert installed_version(fixture.cli(work, "update", "Kit"), "Kit") == "1.1"
    write_spec(catalog, "1.2", source)
    commit(catalog, "another version")
    assert (
        installed_version(fixture.cli(work, "update", "Kit", "--no-repo-update"), "Kit")
        == "1.1"
    )
    assert (
        installed_version(fixture.cli(work, "update", "Kit", "--repo-update"), "Kit")
        == "1.2"
    )
    catalog.rename(work / "unavailable-specs")
    fixture.cli(work, "install", "--offline", "--deployment")
    fixture.cli(work, "update", "Kit", "--offline", "--no-repo-update")
    fixture.cli(work, "repo", "remove", "audit11-catalog")
    fixture.verified += [
        "registered_git_catalog_refreshes_for_update_and_explicit_repo_update",
        "no_repo_update_preserves_catalog_revision_and_offline_skips_fetch",
    ]


def archive(path, value):
    with zipfile.ZipFile(path, "w") as output:
        output.writestr("Kit.c", f"int kit_value(void) {{ return {value}; }}\n")


def http_payload_pins(fixture):
    for parallel in [False, True]:
        label = "parallel" if parallel else "serial"
        work, _ = create(fixture.root / ("repo-refresh-http-" + label))
        web = work / "web"
        web.mkdir()
        archive(web / "source.zip", 1)
        with serve(web) as (location, requests):
            catalog = work / "specs"
            write_spec(catalog, "1.0", {"http": location + "source.zip"})
            unintegrated_manifest(work, catalog, parallel=parallel)
            fixture.cli(work, "install")
            locked = (work / "Podfile.lock").read_bytes()
            source = (work / "Pods/Kit/Kit.c").read_bytes()
            archive(web / "source.zip", 2)
            for flags in [[], ["--repo-update"], ["--repo-update", "--deployment"]]:
                requests.clear()
                fixture.cli(work, "install", *flags)
                assert requests == [], requests
                assert (work / "Pods/Kit/Kit.c").read_bytes() == source
                assert (work / "Podfile.lock").read_bytes() == locked
            fixture.cli(work, "update", "Kit")
            assert requests == ["/source.zip"], requests
            assert "return 2;" in (work / "Pods/Kit/Kit.c").read_text()
        fixture.verified.append("repo_refresh_preserves_http_payload_and_lock_" + label)


def cdn_refresh(fixture):
    work, _ = create(fixture.root / "cdn-refresh")
    web = work / "web"
    web.mkdir()
    archive(web / "source.zip", 7)
    partition = hashlib.md5(b"Kit").hexdigest()[:3]
    index_name = "all_pods_versions_" + "_".join(partition) + ".txt"
    with serve(web) as (location, requests):
        catalog = web / "Specs" / "/".join(partition)
        write_spec(catalog, "1.0", {"http": location + "source.zip"})
        (web / index_name).write_text("Kit/1.0\n")
        unintegrated_manifest(work, location)
        fixture.cli(work, "install")
        write_spec(catalog, "1.1", {"http": location + "source.zip"})
        (web / index_name).write_text("Kit/1.0/1.1\n")
        requests.clear()
        assert (
            installed_version(
                fixture.cli(work, "update", "Kit", "--no-repo-update"), "Kit"
            )
            == "1.0"
        )
        assert "/" + index_name not in requests
        requests.clear()
        assert installed_version(fixture.cli(work, "update", "Kit"), "Kit") == "1.1"
        assert "/" + index_name in requests
        write_spec(catalog, "1.2", {"http": location + "source.zip"})
        (web / index_name).write_text("Kit/1.0/1.1/1.2\n")
        assert (
            installed_version(
                fixture.cli(work, "update", "Kit", "--repo-update"), "Kit"
            )
            == "1.2"
        )
    fixture.verified.append("cdn_update_refreshes_versions_unless_explicitly_disabled")


def source_phase_paths(work):
    objects = read_project(work / "Pods/Pods.xcodeproj")["objects"]
    return [
        objects[objects[build]["fileRef"]]["path"]
        for value in objects.values()
        if value.get("isa") == "PBXSourcesBuildPhase"
        for build in value.get("files", [])
    ]


def module_consumer(selected, module, result):
    graph = read_project(selected)
    for value in graph["objects"].values():
        if (
            value.get("isa") == "PBXFileReference"
            and value.get("path") == "Sources/main.mm"
        ):
            value.update(path="Sources/main.m", lastKnownFileType="sourcecode.c.objc")
        if value.get("isa") == "XCBuildConfiguration":
            value["buildSettings"]["CLANG_ENABLE_MODULES"] = "YES"
    save_project(selected, graph)
    main = selected.parent / "Sources/main.mm"
    main.unlink()
    main.with_suffix(".m").write_text(
        "@import " + module + ";\nint main(void) { return " + result + "; }\n"
    )


def metal_sources(fixture):
    work, _ = create(fixture.root / "metal-sources")
    update_spec(work, source_files="*.{c,h,metal}")
    (work / "Podfile").write_text("use_frameworks!\n" + podfile(work))
    shader = work / "Kit/Shader.metal"
    shader.write_text("#error Metal source must compile\n")
    fixture.cli(work, "install")
    assert any(path.endswith("/Shader.metal") for path in source_phase_paths(work))
    build_root = fixture.root / "metal-invalid-build"
    build_root.mkdir()
    result = subprocess.run(
        [
            "xcodebuild",
            "-workspace",
            str(next(work.glob("*.xcworkspace"))),
            "-scheme",
            "Demo",
            "-configuration",
            "Debug",
            "-destination",
            "platform=macOS,arch=" + platform.machine(),
            *map(str, fixture_build_arguments(build_root)),
            "CODE_SIGNING_ALLOWED=NO",
            "build",
        ],
        cwd=work,
        env=fixture.env,
        capture_output=True,
        text=True,
        timeout=150,
    )
    text = result.stdout + result.stderr
    (fixture.root / "metal-invalid-build.log").write_text(text)
    assert result.returncode != 0 and "Metal source must compile" in text
    shader.write_text(
        "#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void fixture(device int *values [[buffer(0)]], "
        "uint id [[thread_position_in_grid]]) { values[id] = 7; }\n"
    )
    fixture.cli(work, "install", "--deployment")
    fixture.build(work, "Demo", "metal-valid-build")
    products = (
        fixture_derived_data(fixture.root / "metal-valid-build")
        / "Build/Products/Debug"
    )
    framework = products / "Kit.framework/Versions/A/Resources/default.metallib"
    embedded = products / (
        "Demo.app/Contents/Frameworks/Kit.framework/Versions/A/Resources/default.metallib"
    )
    assert framework.is_file() and embedded.read_bytes() == framework.read_bytes()
    fixture.verified.append("metal_sources_compile_and_embed_the_generated_metallib")

    selected = next(work.parent.glob("Apps/*.xcodeproj"))
    module_consumer(selected, "Kit", "0")
    update_spec(work, source_files="*.metal")
    fixture.cli(work, "install")
    fixture.build(work, "Demo", "metal-only-build")
    products = (
        fixture_derived_data(fixture.root / "metal-only-build") / "Build/Products/Debug"
    )
    binary = products / "Kit.framework/Versions/A/Kit"
    assert binary.is_file() and binary.stat().st_size > 0
    library = "Kit.framework/Versions/A/Resources/default.metallib"
    assert (products / library).read_bytes() == (
        products / "Demo.app/Contents/Frameworks" / library
    ).read_bytes()
    fixture.verified.append(
        "shader_only_framework_contains_a_linkable_binary_and_metallib"
    )


def brace_visibility(fixture):
    work, _ = create(fixture.root / "brace-dotfiles")
    (work / "Kit/.hidden.c").write_text("#error Hidden source must not compile\n")
    for index, pattern in enumerate(["{Kit,*}.{c,h}", "{*,Kit}.{c,h}"]):
        update_spec(work, source_files=pattern)
        fixture.cli(work, "install")
        assert not any(path.endswith("/.hidden.c") for path in source_phase_paths(work))
        fixture.build(work, "Demo", "brace-visible-build-" + str(index))
    fixture.verified.append(
        "brace_alternative_order_preserves_dotfile_visibility_in_real_builds"
    )


def quick_validation(fixture):
    work, _ = create(fixture.root / "quick-child-validation")
    path = work / "Kit/Kit.podspec.json"
    original = json.loads(path.read_text())
    cases = [
        {"subspecs": [{"name": "Core", "source_files": 42}]},
        {
            "subspecs": [
                {"name": "Core", "subspecs": [{"name": "Nested", "resources": 42}]}
            ]
        },
        {"testspecs": [{"name": "Tests", "test_type": {"invalid": True}}]},
        {"appspecs": [{"name": "App", "osx": {"source_files": False}}]},
    ]
    for action in ["lib", "spec"]:
        path.write_text(json.dumps(original))
        fixture.cli(work, action, "lint", str(path), "--quick")
        for changes in cases:
            path.write_text(json.dumps(dict(original, **changes)))
            report = fixture.cli(
                work,
                action,
                "lint",
                str(path),
                "--quick",
                "--allow-warnings",
                succeeds=False,
            )
            diagnostic(report, "SP-SPEC-ATTRIBUTE-TYPE")
        invalid = dict(original, testspecs=[{"name": "Tests", "test_type": "invalid"}])
        path.write_text(json.dumps(invalid))
        diagnostic(
            fixture.cli(work, action, "lint", str(path), "--quick", succeeds=False),
            "SP-TEST-TYPE",
        )
    fixture.verified.append(
        "quick_lint_validates_types_and_test_enums_through_all_child_kinds"
    )


def unicode_identity(fixture):
    work, selected = create(fixture.root / "unicode-identity")
    original = work / "Kit/Kit.podspec.json"
    data = json.loads(original.read_text())
    data["name"] = "École"
    original.unlink()
    (work / "Kit/École.podspec.json").write_text(json.dumps(data, ensure_ascii=False))
    (work / "Podfile").write_text(
        "use_frameworks!\n" + podfile(work).replace("pod 'Kit'", "pod 'École'")
    )
    module_consumer(selected, "Ecole", "kit_value() == 7 ? 0 : 1")
    fixture.cli(work, "install")
    fixture.cli(work, "install", "--deployment")
    fixture.build(work, "Demo", "unicode-module-build")
    fixture.verified.append(
        "unicode_pod_identity_preserves_module_imports_and_deployment_lock"
    )


def ruby_literals(fixture):
    work, selected = create(fixture.root / "ruby-init-quotes")
    (work / "Podfile").unlink()
    local = work / "Demo's.xcodeproj"
    shutil.copytree(selected, local)
    graph = read_project(local)
    for value in graph["objects"].values():
        if value.get("isa") == "PBXNativeTarget":
            value["name"] = "Demo's App"
        if value.get("isa") == "XCBuildConfiguration" and value["buildSettings"].get(
            "PRODUCT_NAME"
        ):
            value["buildSettings"].update(
                SDKROOT="macosx", MACOSX_DEPLOYMENT_TARGET="13.0"
            )
            value.pop("baseConfigurationReference", None)
    save_project(local, graph)
    fixture.cli(work, "init")
    report = fixture.cli(work, "ipc", "podfile", "Podfile")
    value = next(
        event["data"] for event in report["events"] if event["kind"] == "inspection"
    )
    assert value["project"] == "Demo's.xcodeproj", value
    assert value["targets"][0]["name"] == "Demo's App", value
    fixture.cli(work, "install")
    fixture.verified.append(
        "init_ruby_literals_round_trip_project_and_target_apostrophes"
    )

    work, _ = create(fixture.root / "ruby-lint-quotes")
    origin = work / "User's Library"
    (work / "Kit").rename(origin)
    path = origin / "Kit.podspec.json"
    data = json.loads(path.read_text())
    data["source"] = {"git": str(origin), "tag": "1.0"}
    path.write_text(json.dumps(data))
    (origin / "LICENSE").write_text("MIT License\n")
    git(origin, "init", "-b", "main")
    commit(origin, "source")
    git(origin, "tag", "1.0")
    fixture.cli(work, "spec", "lint", str(path), "--platforms=osx")
    fixture.verified.append(
        "spec_lint_generated_podfile_preserves_apostrophes_in_source_paths"
    )


def constrained_outdated(fixture):
    work, _ = create(fixture.root / "constrained-outdated")
    origin = work / "Kit"
    git(origin, "init", "-b", "main")
    revision = commit(origin, "source")
    catalog = work / "specs"
    for version in ["1.0", "2.0", "3.0.pre"]:
        write_spec(catalog, version, {"git": str(origin), "commit": revision})
    unintegrated_manifest(work, catalog, requirement="< 2")
    fixture.cli(work, "install")
    before = (work / "Podfile.lock").read_bytes()
    report = fixture.cli(work, "outdated", "--ignore-prerelease")
    changes = next(
        event["pods"] for event in report["events"] if event["kind"] == "outdated"
    )
    assert changes == [
        {"name": "Kit", "installed": "1.0", "available": "1.0", "latest": "2.0"}
    ], changes
    assert (work / "Podfile.lock").read_bytes() == before
    report = fixture.cli(work, "outdated")
    changes = next(
        event["pods"] for event in report["events"] if event["kind"] == "outdated"
    )
    assert changes[0]["latest"] == "3.0.pre"
    fixture.verified.append(
        "outdated_reports_manifest_blocked_versions_and_filters_prereleases"
    )


def run(fixture):
    repository_refresh(fixture)
    http_payload_pins(fixture)
    cdn_refresh(fixture)
    metal_sources(fixture)
    brace_visibility(fixture)
    quick_validation(fixture)
    unicode_identity(fixture)
    ruby_literals(fixture)
    constrained_outdated(fixture)
