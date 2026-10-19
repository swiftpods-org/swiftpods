"""CLI regressions for version metadata, Xcode roots and repository transactions."""

import functools
import hashlib
import http.server
import json
import shutil
import subprocess
import threading

from lifecycle_audit_regressions import diagnostics, read_project, write_project
from native_xcconfig_tests import create


def git(directory, *arguments):
    return subprocess.check_output(
        ["git", "-C", str(directory), *arguments],
        stderr=subprocess.STDOUT,
        text=True,
    ).strip()


def initialize(directory):
    directory.mkdir(parents=True, exist_ok=True)
    git(directory, "init", "-b", "main")
    git(directory, "add", ".")
    git(
        directory,
        "-c",
        "user.name=SwiftPods Tests",
        "-c",
        "user.email=tests@example.invalid",
        "commit",
        "-m",
        "fixture",
    )
    return git(directory, "rev-parse", "HEAD")


def versions(fixture):
    for index, version in enumerate(["1.2.3+build.7", "1.2.3-alpha-beta"]):
        work, _ = create(fixture.root / ("version-metadata-" + str(index)))
        spec = work / "Kit/Kit.podspec.json"
        data = json.loads(spec.read_text())
        data["version"] = version
        if index == 0:
            # Exercise a Ruby podspec and its live Version/Dependency objects too.
            spec.unlink()
            (work / "Kit/Kit.podspec").write_text(
                "Pod::Spec.new do |s|\n s.name = 'Kit'\n s.version = "
                + repr(version)
                + "\n s.summary = 'Fixture'\n s.homepage = 'https://swiftpods.org'"
                + "\n s.authors = 'Tests'\n s.license = 'MIT'\n s.osx.deployment_target = '13.0'"
                + "\n s.source = { :git => 'https://example.invalid/Kit.git', :tag => "
                + repr(version)
                + " }\n s.source_files = '*.{c,h}'\nend\n"
            )
        else:
            spec.write_text(json.dumps(data))
        body = (work / "Podfile").read_text().split("post_install")[0]
        body = body.replace("pod 'Kit',", "pod 'Kit', " + repr("= " + version) + ",")
        hook = """pre_install do |installer|
  spec = installer.pod_targets.first.root_spec
  raise 'version spelling lost' unless spec.version.to_s == VERSION
  dependency = installer.podfile.dependencies.first
  raise 'version requirement rejected' unless dependency.requirement.satisfied_by?(spec.version)
  raise 'metadata treated as prerelease' unless spec.version.prerelease? == PRERELEASE
end
""".replace("VERSION", repr(version)).replace(
            "PRERELEASE", "true" if index else "false"
        )
        (work / "Podfile").write_text(body + hook)
        fixture.cli(work, "install")
        lock = (work / "Podfile.lock").read_bytes()
        assert version.encode() in lock
        fixture.cli(work, "install", "--offline", "--deployment")
        assert (work / "Podfile.lock").read_bytes() == lock
    fixture.verified += [
        "version_metadata_and_compound_prerelease_install",
        "metadata_version_ruby_hooks_requirements_and_deployment",
    ]


def project_root_and_sdk(fixture):
    work, selected = create(fixture.root / "project-root-sdk")
    graph = read_project(selected)
    graph["objects"][graph["rootObject"]]["projectDirPath"] = "ActualRoot"
    for obj in graph["objects"].values():
        if obj.get("isa") == "XCBuildConfiguration" and not obj["buildSettings"].get(
            "PRODUCT_NAME"
        ):
            obj["buildSettings"]["SDKROOT"] = "iphoneos"
            obj["buildSettings"]["IPHONEOS_DEPLOYMENT_TARGET"] = "15.0"
    write_project(selected, graph)
    actual = selected.parent / "ActualRoot"
    actual.mkdir()
    for name in ["Sources", "Configs"]:
        shutil.move(selected.parent / name, actual / name)
    for name in ["Debug", "Release"]:
        path = actual / "Configs" / (name + ".xcconfig")
        path.write_text(
            path.read_text().replace("../../work/Pods", "../../../work/Pods")
        )
    (actual / "Configs/Base.xcconfig").write_text(
        '#include "Minimum.xcconfig"\nSDKROOT = macosx\n'
        "GCC_PREPROCESSOR_DEFINITIONS = $(inherited) USER_CONFIG=1\n"
    )
    (actual / "Configs/Minimum.xcconfig").write_text(
        "MACOSX_DEPLOYMENT_TARGET = 13.0\nMACOSX_DEPLOYMENT_TARGET[sdk=macosx*] = 14.0\n"
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
  target = aggregate.user_targets.first
  raise 'wrong platform' unless aggregate.platform.name == :osx && aggregate.platform.deployment_target.to_s == '14.0'
  values = target.resolved_build_setting('MACOSX_DEPLOYMENT_TARGET', true)
  raise 'wrong SDK context' unless values.values.uniq == ['14.0']
  source = target.source_build_phase.files.first.file_ref.real_path
  raise 'wrong source root' unless source.file? && source.to_s.end_with?('/ActualRoot/Sources/main.mm')
end
"""
    )
    fixture.cli(work, "install")
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
    (fixture.root / "project-root-settings.log").write_text(
        result.stdout + result.stderr
    )
    assert result.returncode == 0
    settings = json.loads(result.stdout)[0]["buildSettings"]
    assert settings["MACOSX_DEPLOYMENT_TARGET"] == "14.0" and settings[
        "SRCROOT"
    ] == str(actual)
    fixture.build(work, "Demo", "project-root-sdk-build")
    fixture.cli(work, "deintegrate")
    assert (
        read_project(selected)["objects"][graph["rootObject"]]["projectDirPath"]
        == "ActualRoot"
    )
    fixture.verified += [
        "target_sdk_overrides_inherited_project_sdk",
        "project_directory_hooks_xcconfig_build_and_deintegrate",
    ]


def repository_receipts(fixture):
    root = fixture.root / "repository-receipts"
    root.mkdir()
    source = root / "source"
    source.mkdir()
    (source / "Kit.c").write_text("int kit(void) { return 7; }\n")
    commit = initialize(source)
    specs = root / "specs"
    path = specs / "Kit/1.0/Kit.podspec.json"
    path.parent.mkdir(parents=True)
    path.write_text(
        json.dumps(
            {
                "name": "Kit",
                "version": "1.0",
                "source_files": "*.c",
                "platforms": {"osx": "13.0"},
                "source": {"git": str(source), "commit": commit},
            }
        )
    )
    initialize(specs)
    web = root / "web"
    web.mkdir()
    subprocess.run(
        ["git", "clone", "--bare", str(specs), str(web / "specs.git")],
        check=True,
        capture_output=True,
    )
    git(web / "specs.git", "update-server-info")

    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *arguments):
            pass

    server = http.server.ThreadingHTTPServer(
        ("127.0.0.1", 0), functools.partial(Handler, directory=str(web))
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    previous = fixture.env["SWIFTPODS_CACHE_ROOT"]
    fixture.env["SWIFTPODS_CACHE_ROOT"] = str(root / "cache")
    try:
        url = "http://127.0.0.1:" + str(server.server_port) + "/specs.git"
        work = root / "work"
        work.mkdir()
        (work / "Podfile").write_text(
            "platform :osx, '13.0'\nsource "
            + repr(url)
            + "\ntarget 'App' do\n pod 'Kit'\nend\n"
        )
        fixture.cli(work, "install", "--no-integrate")
        entry = fixture.cli(work, "repo", "add", "private", url)["repository"]
        fixture.cli(work, "install", "--no-integrate", "--offline")
        key = hashlib.sha256((url + "\n" + entry["revision"]).encode()).hexdigest()
        checkout = root / "cache/git" / key
        receipt = checkout.with_suffix(".sha256")
        metadata = checkout.with_suffix(".origin.json")
        current = json.loads(receipt.read_text())
        # Emulate the old format; an unverified old revision must be rebuilt.
        receipt.write_text(current["fingerprint"])
        old = json.loads(metadata.read_text())
        old["commit"] = "f" * 40
        metadata.write_text(json.dumps(old))
        fixture.cli(work, "install", "--no-integrate", "--offline")
        assert json.loads(receipt.read_text())["schema_version"] == 1
        assert json.loads(metadata.read_text())["commit"] == entry["revision"]
        clean = metadata.read_text()
        changed = json.loads(clean)
        changed["origin_identity"] = "f" * 64
        metadata.write_text(json.dumps(changed))
        failure = fixture.cli(
            work, "install", "--no-integrate", "--offline", succeeds=False
        )
        assert "SP-CACHE-INTEGRITY" in diagnostics(failure)
        metadata.write_text(clean)
        fixture.cli(work, "repo", "remove", "private")
        fixture.cli(work, "install", "--no-integrate")
    finally:
        fixture.env["SWIFTPODS_CACHE_ROOT"] = previous
        server.shutdown()
        server.server_close()
        thread.join()
    fixture.verified += [
        "repository_registration_reuses_git_receipt",
        "legacy_repository_receipt_rebuilt_from_pinned_checkout",
        "repository_receipt_corruption_rejected",
    ]


def local_publication(fixture):
    root = fixture.root / "local-publication"
    origin = root / "origin"
    origin.mkdir(parents=True)
    (origin / "README").write_text("Publication fixture\n")
    initial = initialize(origin)
    work = root / "work"
    work.mkdir()
    spec = work / "Kit.podspec.json"
    spec.write_text(
        json.dumps(
            {
                "name": "Kit",
                "version": "1.0",
                "summary": "Fixture",
                "homepage": "https://swiftpods.org",
                "authors": "Tests",
                "license": "MIT",
                "source_files": "*.c",
                "source": {"git": "https://example.invalid/Kit.git", "tag": "1.0"},
            }
        )
    )
    previous = fixture.env["SWIFTPODS_CACHE_ROOT"]
    fixture.env["SWIFTPODS_CACHE_ROOT"] = str(root / "cache")
    try:
        fixture.cli(work, "repo", "add", "private", str(origin))
        checkout = root / "cache/repositories/private"
        git(checkout, "config", "user.name", "SwiftPods Tests")
        git(checkout, "config", "user.email", "tests@example.invalid")
        git(checkout, "config", "audit.keep", "preserved")
        hook = checkout / ".git/hooks/pre-commit"
        hook.write_text("#!/bin/sh\nexit 17\n")
        hook.chmod(0o755)
        record = checkout.with_suffix(".json").read_bytes()
        failure = fixture.cli(
            work,
            "repo",
            "push",
            "private",
            str(spec),
            "--local-only",
            "--quick",
            succeeds=False,
        )
        assert "SP-TOOL-FAILED" in diagnostics(failure)
        assert (
            git(checkout, "status", "--porcelain") == ""
            and git(checkout, "rev-parse", "HEAD") == initial
        )
        assert checkout.with_suffix(".json").read_bytes() == record
        assert not (checkout / "Kit").exists()
        assert not list(checkout.parent.glob(".publish-*"))
        fixture.cli(work, "repo", "update", "private")
        hook.write_text(
            "#!/bin/sh\ntest -f Kit/1.0/Kit.podspec.json || exit 19\nprintf 'ran\\n' > .git/hook-proof\n"
        )
        fixture.cli(
            work, "repo", "push", "private", str(spec), "--local-only", "--quick"
        )
        assert (
            git(checkout, "status", "--porcelain") == ""
            and git(checkout, "rev-parse", "HEAD") != initial
        )
        assert git(checkout, "config", "audit.keep") == "preserved"
        assert (checkout / ".git/hook-proof").read_text() == "ran\n"
        assert json.loads(checkout.with_suffix(".json").read_text())["revision"] == git(
            checkout, "rev-parse", "HEAD"
        )
        assert git(origin, "rev-parse", "HEAD") == initial
        assert not list(checkout.parent.glob(".publish-*"))
        # Exercise full lint too: its source-cache lease must finish before publication.
        library = root / "Library"
        library.mkdir()
        (library / "Kit.c").write_text("int kit(void) { return 7; }\n")
        initialize(library)
        git(library, "tag", "1.1")
        data = json.loads(spec.read_text())
        data.update(
            version="1.1",
            platforms={"osx": "13.0"},
            source={"git": str(library), "tag": "1.1"},
        )
        spec.write_text(json.dumps(data))
        fixture.cli(work, "repo", "push", "private", str(spec), "--local-only")
        assert git(checkout, "status", "--porcelain") == ""
        assert (checkout / "Kit/1.1/Kit.podspec.json").is_file()
    finally:
        fixture.env["SWIFTPODS_CACHE_ROOT"] = previous
    fixture.verified += [
        "rejected_local_publication_preserves_clean_checkout",
        "local_publication_retry_preserves_hooks_config_and_revision",
    ]


def run(fixture):
    versions(fixture)
    project_root_and_sdk(fixture)
    repository_receipts(fixture)
    local_publication(fixture)
