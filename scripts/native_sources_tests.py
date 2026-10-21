#!/usr/bin/env python3
"""Exercise native repository, HTTP, Git, lock, recovery and hardened paths."""

import functools
import hashlib
import http.server
import json
import subprocess
import threading
import zipfile

from bootstrap import environment
from local_build import debug_binary, fixture_directory, results_directory
from reporting import execute


def main():
    parent = fixture_directory("native-sources-")
    web = parent / "web"
    web.mkdir()
    with zipfile.ZipFile(web / "source.zip", "w") as archive:
        archive.writestr(
            "Package/Sources/source.c", "int swiftpods_source(void) { return 1; }\n"
        )
    checksum = hashlib.sha256((web / "source.zip").read_bytes()).hexdigest()
    requests = []

    class Handler(http.server.SimpleHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            super().do_GET()

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(
        ("127.0.0.1", 0), functools.partial(Handler, directory=web)
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    location = "http://127.0.0.1:" + str(server.server_port) + "/source.zip"
    catalog = parent / "catalog"

    def spec(name, version, deps=None, source=None):
        return {
            "name": name,
            "version": version,
            "source": source or {"http": location, "sha256": checksum, "flatten": True},
            "source_files": "Sources/*.c",
            "dependencies": deps or {},
        }

    for data in [
        spec("Kit", "1.0", {"Helper": ["~> 1.0"]}),
        spec("Helper", "1.1"),
        spec("Helper", "2.0"),
    ]:
        path = (
            catalog / data["name"] / data["version"] / (data["name"] + ".podspec.json")
        )
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data))
    work = parent / "project"
    work.mkdir()
    manifest = {
        "schema_version": 1,
        "project": "Unused.xcodeproj",
        "platform": {"name": "osx", "deployment_target": "13.0"},
        "sources": [str(catalog)],
        "targets": [{"name": "App", "pods": [{"name": "Kit"}]}],
    }
    (work / "Podfile.json").write_text(json.dumps(manifest))
    env = environment()
    env["SWIFTPODS_CACHE_ROOT"] = str(parent / "cache")
    cli = debug_binary()

    def run(*args, success=True):
        result = subprocess.run(
            [str(cli), *args, "--json"],
            cwd=work,
            env=env,
            capture_output=True,
            text=True,
            timeout=90,
        )
        if success and result.returncode:
            raise RuntimeError(result.stderr + result.stdout)
        if not success and not result.returncode:
            raise RuntimeError("Expected rejection: " + str(args))
        return json.loads(result.stdout)

    try:
        # JSON mode does not execute or require a Ruby interpreter.
        env["SWIFTPODS_RUBY"] = "/does/not/exist"
        installed = run("install", "--hardened", "--no-integrate")
        roots = {
            event["name"]: event["version"]
            for event in installed["events"]
            if event["kind"] == "installation"
            for event in event["specs"]
        }
        assert roots == {"Kit": "1.0", "Helper": "1.1"}, roots
        assert (work / "Pods/Kit/Sources/source.c").exists()
        assert (work / "Pods/Pods.xcodeproj/project.pbxproj").exists()
        lock = (work / "Podfile.lock").read_bytes()
        assert run("cache", "list", "Kit")["entries"]
        assert run("cache", "clean", "Kit")["removed"] == 2
        assert run("cache", "list", "Helper")["entries"], (
            "Shared archive cleanup removed another pod origin"
        )
        run("install", "--hardened", "--no-integrate")
        # The CDN protocol indexes versions first and downloads only candidates used.
        partition = hashlib.md5(b"CDNKit").hexdigest()[:3]
        (web / ("all_pods_versions_" + "_".join(partition) + ".txt")).write_text(
            "CDNKit/1.0/1.1/2.0\n"
        )
        for version in ("1.0", "1.1", "2.0"):
            path = (
                web
                / "Specs"
                / "/".join(partition)
                / "CDNKit"
                / version
                / "CDNKit.podspec.json"
            )
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(spec("CDNKit", version)))
        previous_work = work
        work = parent / "cdn-project"
        work.mkdir()
        cdn_manifest = dict(manifest)
        cdn_manifest["sources"] = ["http://127.0.0.1:" + str(server.server_port) + "/"]
        cdn_manifest["targets"] = [
            {"name": "App", "pods": [{"name": "CDNKit", "versions": ["~> 1.0"]}]}
        ]
        (work / "Podfile.json").write_text(json.dumps(cdn_manifest))
        run("install", "--hardened", "--no-integrate")
        assert any("/CDNKit/1.1/" in path for path in requests)
        assert not any(
            "/CDNKit/1.0/" in path or "/CDNKit/2.0/" in path for path in requests
        )
        work = previous_work
        server.shutdown()
        thread.join(timeout=5)
        run("install", "--hardened", "--no-integrate", "--deployment", "--offline")
        assert (work / "Podfile.lock").read_bytes() == lock
        helper = catalog / "Helper/1.1/Helper.podspec.json"
        original = helper.read_bytes()
        changed_spec = json.loads(original)
        changed_spec["summary"] = "changed"
        helper.write_text(json.dumps(changed_spec))
        rejected = run(
            "install",
            "--hardened",
            "--no-integrate",
            "--deployment",
            "--offline",
            success=False,
        )
        assert any(
            event.get("code") == "SP-DEPLOYMENT-SPEC" for event in rejected["events"]
        )
        helper.write_bytes(original)
        # Stale or missing lock inputs are rejected before touching Pods.
        changed = dict(manifest)
        changed["targets"] = [
            {"name": "App", "pods": [{"name": "Kit", "versions": [">= 2"]}]}
        ]
        (work / "Podfile.json").write_text(json.dumps(changed))
        rejected = run(
            "install", "--hardened", "--no-integrate", "--deployment", success=False
        )
        assert any(
            event.get("code") == "SP-DEPLOYMENT-LOCK" for event in rejected["events"]
        )
        (work / "Podfile.json").write_text(json.dumps(manifest))
        # Raw-cache corruption must fail, even when the destination is present.
        raw = parent / "cache/content/objects" / checksum
        raw.chmod(0o644)
        raw.write_bytes(b"corrupt")
        rejected = run(
            "install", "--hardened", "--no-integrate", "--offline", success=False
        )
        assert any(
            event.get("code") == "SP-CACHE-INTEGRITY" for event in rejected["events"]
        )
        run("recover")
        assert (work / "Podfile.lock").read_bytes() == lock
        assert (work / "Pods/Kit/Sources/source.c").exists()
        # A Git source is cloned and checked out by the native downloader.
        env = environment()
        env["SWIFTPODS_CACHE_ROOT"] = str(parent / "git-cache")
        repository = parent / "git-source"
        repository.mkdir()
        (repository / "GitKit.podspec.json").write_text(
            json.dumps(spec("GitKit", "1.2.3.4"))
        )
        (repository / "Sources").mkdir()
        (repository / "Sources/source.c").write_text(
            "int git_source(void) { return 2; }\n"
        )
        for args in [
            ("init",),
            ("add", "."),
            (
                "-c",
                "user.name=SwiftPods Tests",
                "-c",
                "user.email=tests@example.invalid",
                "commit",
                "-m",
                "fixture",
            ),
        ]:
            subprocess.run(
                ["git", "-C", str(repository), *args],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        revision = subprocess.check_output(
            ["git", "-C", str(repository), "rev-parse", "HEAD"], text=True
        ).strip()
        (work / "Podfile").write_text(
            "platform :osx, '13.0'\ntarget 'App' do\n  pod 'GitKit', :git => "
            + repr(str(repository))
            + ", :commit => "
            + repr(revision)
            + "\nend\n"
        )
        run("install", "--no-integrate")
        run("install", "--no-integrate", "--offline", "--deployment")
        assert (work / "Pods/GitKit/Sources/source.c").exists()
        assert not (work / "Pods/GitKit/.git").exists()
        # Hardened mode must reject executable specs before running prepare.
        bad = parent / "Bad"
        bad.mkdir()
        (bad / "Bad.podspec.json").write_text(
            json.dumps(
                {
                    "name": "Bad",
                    "version": "1.0",
                    "prepare_command": "touch MUST_NOT_RUN",
                }
            )
        )
        manifest["targets"] = [
            {"name": "App", "pods": [{"name": "Bad", "path": str(bad)}]}
        ]
        (work / "Podfile.json").write_text(json.dumps(manifest))
        run("install", "--hardened", "--no-integrate", success=False)
        assert not (bad / "MUST_NOT_RUN").exists()
        report = {
            "status": "passed",
            "engine": "swift",
            "fixture": str(parent),
            "verified": [
                "local spec repository",
                "lazy CDN version index and podspec fetch",
                "transitive version constraints",
                "HTTP archive with SHA-256",
                "hardened JSON without Ruby",
                "offline deployment reinstall",
                "changed deployment rejected",
                "changed podspec rejected in deployment",
                "corrupt cache rejected",
                "recovery restores source trees",
                "native Git commit source and offline reinstall",
                "hardened prepare rejected before execution",
            ],
            "unverified": [
                "public CDN",
                "authenticated remote sources",
                "full compatibility matrix",
            ],
        }
        (results_directory() / "native-sources.json").write_text(
            json.dumps(report, indent=2) + "\n"
        )
        print(json.dumps(report, indent=2))
    finally:
        server.server_close()


if __name__ == "__main__":
    execute(main, "native-sources.json")
