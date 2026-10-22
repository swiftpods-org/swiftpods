"""CLI regressions for version metadata, Xcode roots and repository transactions."""

import functools
import hashlib
import http.server
import json
import shutil
import subprocess
import threading

from Tests.Integration.native_xcconfig_tests import create
from Tests.Regression.lifecycle_audit_regressions import (
    diagnostics,
    read_project,
    write_project,
)


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


def publication_snapshot(fixture):
    root = fixture.root / "publication-snapshot"
    origin = root / "origin"
    origin.mkdir(parents=True)
    (origin / "README").write_text("Isolated specification repository\n")
    initialize(origin)
    library = root / "Library"
    library.mkdir()
    (library / "Kit.c").write_text("int kit(void) { return 7; }\n")
    initialize(library)
    git(library, "tag", "1.0")
    previous = fixture.env["SWIFTPODS_CACHE_ROOT"]
    fixture.env["SWIFTPODS_CACHE_ROOT"] = str(root / "cache")
    try:
        fixture.cli(root, "repo", "add", "snapshot", str(origin))
        checkout = root / "cache/repositories/snapshot"
        git(checkout, "config", "user.name", "SwiftPods Tests")
        git(checkout, "config", "user.email", "tests@example.invalid")
        for label, version, first_valid, full in [
            ("invalid-first", "1.0", False, False),
            ("valid-first-quick", "1.1", True, False),
            ("valid-first-full", "1.2", True, True),
        ]:
            work = root / label
            work.mkdir()
            spec = work / "Kit.podspec"
            condition = "count == 0" if first_valid else "count > 0"
            spec.write_text(
                "count = File.file?('reads') ? File.read('reads').to_i : 0\n"
                "File.write('reads', (count + 1).to_s)\n"
                "Pod::Spec.new do |s|\n s.name = 'Kit'\n s.version = " + repr(version)
                + "\n s.summary = 'Verified snapshot.' if " + condition
                + "\n s.homepage = 'https://swiftpods.org'\n s.authors = 'Tests'\n s.license = 'MIT'"
                + "\n s.platforms = { :osx => '13.0' }\n s.source_files = '*.c'"
                + "\n s.source = { :git => " + repr(str(library)) + ", :tag => '1.0' }\nend\n"
            )
            before = git(checkout, "rev-parse", "HEAD")
            result = fixture.cli(
                work, "repo", "push", "snapshot", str(spec), "--local-only",
                *([] if full else ["--quick"]), succeeds=first_valid,
            )
            assert (work / "reads").read_text() == "1", result
            published = checkout / "Kit" / version / "Kit.podspec.json"
            if not first_valid:
                assert "SP-REPO-LINT" in diagnostics(result), result
                assert not published.exists()
                assert git(checkout, "rev-parse", "HEAD") == before
            else:
                assert json.loads(published.read_text())["summary"] == "Verified snapshot."
                publication = next(event["data"] for event in result["events"]
                                   if event["kind"] == "publication")
                assert publication["validation"]["specifications"][0]["path"] == str(spec)
            assert git(checkout, "status", "--porcelain") == ""
            fixture.verified.append("publication_uses_one_evaluated_snapshot_" + label)
    finally:
        fixture.env["SWIFTPODS_CACHE_ROOT"] = previous


def run(fixture):
    versions(fixture)
    project_root_and_sdk(fixture)
    repository_receipts(fixture)
    local_publication(fixture)
    publication_snapshot(fixture)
    multi_platform_lock(fixture)
    publication_identity(fixture)
    publication_paths(fixture)


def multi_platform_lock(fixture):
    for legacy in [False, True]:
        _multi_platform_lock(fixture, legacy)


def _multi_platform_lock(fixture, legacy):
    work = fixture.root / ("multi-platform-lock-" + ("legacy" if legacy else "current"))
    library = work / "Library"
    library.mkdir(parents=True)
    (library / "Kit.c").write_text("int kit(void) { return 7; }\n")
    revision = initialize(library)
    catalog = work / "specs"

    def specs(version):
        for name in ["A", "B", "C", "D", "E"]:
            data = {"name": name, "version": version, "source_files": "*.c",
                    "source": {"git": str(library), "commit": revision},
                    "platforms": {"ios": "15.4", "osx": "13.0"}}
            if name == "A":
                data.update(ios={"dependencies": {"B": ["= " + version]}},
                            osx={"dependencies": {"C": ["= " + version]}})
            if name == "D":
                data["dependencies"] = {"E": [">= 1.0"]}
            path = catalog / name / version / (name + ".podspec.json")
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(data))

    specs("1.0")
    (work / "Podfile").write_text(
        "install! 'swiftpods', :integrate_targets => false\nsource " + repr(str(catalog))
        + "\ntarget 'Phone' do\n platform :ios, '15.4'\n pod 'A'\nend\n"
        + "target 'Desktop' do\n platform :osx, '13.0'\n pod 'A'\n pod 'D'\nend\n")
    previous = fixture.env["SWIFTPODS_CACHE_ROOT"]
    fixture.env["SWIFTPODS_CACHE_ROOT"] = str(work / "cache")
    try:
        fixture.cli(work, "install")
        locked = (work / "Podfile.lock").read_text()
        assert "    - 'B (= 1.0)'" in locked and "    - 'C (= 1.0)'" in locked, locked
        if legacy:
            # The former writer retained A's iOS edges and omitted its macOS edges.
            (work / "Podfile.lock").write_text(locked.replace("    - 'C (= 1.0)'\n", ""))
            # A clean CI checkout has the lockfile, but no installed podspecs.
            shutil.rmtree(work / "Pods")
        specs("2.0")
        report = fixture.cli(work, "update", "A", "--no-repo-update")
        installed = next(event for event in report["events"] if event["kind"] == "installation")
        assert {spec["name"]: spec["version"] for spec in installed["specs"]} == {
            "A": "2.0", "B": "2.0", "C": "2.0", "D": "1.0", "E": "1.0"}
        fixture.cli(work, "install", "--deployment", "--offline")
        fixture.verified.append("targeted_update_unlocks_every_platform_and_preserves_unrelated_pins_"
                                + ("legacy_lock" if legacy else "current_lock"))
    finally:
        fixture.env["SWIFTPODS_CACHE_ROOT"] = previous


def publication_identity(fixture):
    work = fixture.root / "publication-identity"
    seed = work / "seed"
    seed.mkdir(parents=True)
    (seed / "README").write_text("Local bare publication fixture\n")
    initialize(seed)
    origin = work / "origin.git"
    git(work, "clone", "--bare", str(seed), str(origin))
    previous = fixture.env.copy()
    try:
        for key in list(fixture.env):
            if key.startswith(("GIT_AUTHOR_", "GIT_COMMITTER_", "GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_")) or key in ["GIT_CONFIG_COUNT", "EMAIL"]:
                fixture.env.pop(key)
        fixture.env.update(SWIFTPODS_CACHE_ROOT=str(work / "cache"), GIT_CONFIG_GLOBAL="/dev/null",
                           GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_COUNT="1",
                           GIT_CONFIG_KEY_0="user.useConfigOnly", GIT_CONFIG_VALUE_0="true")
        fixture.cli(work, "repo", "add", "private", str(origin))
        checkout = work / "cache/repositories/private"
        git(checkout, "config", "user.name", "Local Publisher")
        git(checkout, "config", "user.email", "publisher@example.invalid")
        spec = work / "Kit.podspec.json"
        for version, author in [("1.0", "Local Publisher <publisher@example.invalid>"),
                                ("1.1", "Explicit Author <author@example.invalid>")]:
            if version == "1.1":
                fixture.env.update(GIT_AUTHOR_NAME="Explicit Author", GIT_AUTHOR_EMAIL="author@example.invalid")
            spec.write_text(json.dumps({"name": "Kit", "version": version, "summary": "Publication identity fixture.",
                                        "homepage": "https://swiftpods.org", "authors": "Tests", "license": "MIT",
                                        "source": {"git": str(seed), "tag": "1.0"}}))
            fixture.cli(work, "repo", "push", "private", str(spec), "--quick")
            assert git(origin, "log", "-1", "--format=%an <%ae>") == author
            assert git(origin, "log", "-1", "--format=%cn <%ce>") == "Local Publisher <publisher@example.invalid>"
            assert git(checkout, "status", "--porcelain") == ""
            assert git(origin, "rev-parse", "HEAD") == git(checkout, "rev-parse", "HEAD")
        fixture.verified.append("remote_publication_retains_repository_identity_and_explicit_author_override")
    finally:
        fixture.env = previous


def publication_paths(fixture):
    previous = fixture.env.copy()
    try:
        for local in [True, False]:
            for link in ["parent", "checkout", "none"]:
                linked = link != "none"
                root = fixture.root / ("publication-path-" + str(local) + "-" + link)
                seed = root / "seed"
                seed.mkdir(parents=True)
                outside = root / "outside-cache"
                outside.mkdir()
                if link == "parent":
                    (seed / "Kit").symlink_to(outside, target_is_directory=True)
                else:
                    (seed / "README").write_text("Safe publication fixture\n")
                initial = initialize(seed)
                origin = root / "origin.git"
                git(root, "clone", "--bare", str(seed), str(origin))
                fixture.env["SWIFTPODS_CACHE_ROOT"] = str(root / "cache")
                fixture.cli(root, "repo", "add", "private", str(origin))
                checkout = root / "cache/repositories/private"
                git(checkout, "config", "user.name", "Fixture")
                git(checkout, "config", "user.email", "fixture@example.invalid")
                if link == "checkout":
                    target = checkout.with_name("actual-checkout")
                    checkout.rename(target)
                    checkout.symlink_to(target.name, target_is_directory=True)
                record = checkout.with_suffix(".json").read_bytes()
                spec = root / "Kit.podspec.json"
                spec.write_text(json.dumps({
                    "name": "Kit", "version": "1.0", "source_files": "*.c", "platforms": {"osx": "13.0"},
                    "summary": "Publication path fixture.", "homepage": "https://swiftpods.org", "authors": "Tests",
                    "license": {"type": "MIT", "text": "Fixture license"}, "source": {"git": str(seed), "tag": "1.0"},
                }))
                result = fixture.cli(root, "repo", "push", "private", str(spec), "--quick",
                                     *(["--local-only"] if local else []), succeeds=not linked)
                assert list(outside.iterdir()) == []
                if linked:
                    assert "SP-REPO-PATH" in diagnostics(result), result
                    assert git(checkout, "rev-parse", "HEAD") == initial
                    assert git(origin, "rev-parse", "HEAD") == initial
                    assert checkout.with_suffix(".json").read_bytes() == record
                else:
                    assert (checkout / "Kit/1.0/Kit.podspec.json").exists()
                    assert git(checkout, "rev-parse", "HEAD") != initial
                    assert (git(origin, "rev-parse", "HEAD") == initial) == local
                assert git(checkout, "status", "--porcelain") == ""
                assert not list(checkout.parent.glob(".publish-*"))
                fixture.verified.append("publication_path_" + ("local" if local else "remote")
                                        + ("_rejects_" + link + "_symlink_without_writes" if linked else "_publishes_regular_path"))
    finally:
        fixture.env = previous
