#!/usr/bin/env python3
"""Exercise external source contracts and an imported Bundler environment locally."""

import functools
import hashlib
import http.server
import json
import shutil
import subprocess
import tempfile
import threading
import zipfile
from pathlib import Path

from bootstrap import ROOT, environment
from reporting import execute


def main():
    parent = Path(
        tempfile.mkdtemp(prefix="native-source-contract-", dir=ROOT / ".build")
    )
    print("Source contract fixtures:", parent, flush=True)
    work = parent / "project"
    work.mkdir()
    env = environment()
    env["SWIFTPODS_CACHE_ROOT"] = str(parent / "cache")
    binary = ROOT / ".build/debug/swiftpods"

    def cli(*args, success=True):
        result = subprocess.run(
            [str(binary), *map(str, args), "--json"],
            cwd=work,
            env=env,
            capture_output=True,
            text=True,
            timeout=90,
        )
        assert (result.returncode == 0) == success, (args, result.stdout, result.stderr)
        return json.loads(result.stdout)

    def manifest(declaration):
        work.joinpath("Podfile").write_text(
            "platform :osx, '13.0'\ntarget 'App' do\n " + declaration + "\nend\n"
        )

    web = parent / "web"
    web.mkdir()
    spec = {"name": "ArchiveKit", "version": "1.0", "source_files": "Sources/*.c"}
    with zipfile.ZipFile(web / "kit.zip", "w") as archive:
        archive.writestr("Root/ArchiveKit.podspec.json", json.dumps(spec))
        archive.writestr(
            "Root/Sources/value.c", "int archive_value(void) { return 29; }\n"
        )
    checksum = hashlib.sha256(web.joinpath("kit.zip").read_bytes()).hexdigest()

    class Handler(http.server.SimpleHTTPRequestHandler):
        def do_GET(self):
            if self.headers.get("X-Fixture") != "allowed":
                self.send_error(403)
                return
            super().do_GET()

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(
        ("127.0.0.1", 0), functools.partial(Handler, directory=web)
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        manifest(
            f"pod 'ArchiveKit', :http => 'http://127.0.0.1:{server.server_port}/kit.zip', :sha256 => '{checksum}', :headers => {{ 'X-Fixture' => 'allowed' }}"
        )
        cli("install", "--no-integrate")
        assert (
            "return 29" in work.joinpath("Pods/ArchiveKit/Sources/value.c").read_text()
        )
        lock = work.joinpath("Podfile.lock").read_bytes()
        cli("install", "--no-integrate", "--offline", "--deployment")
        assert lock == work.joinpath("Podfile.lock").read_bytes()
        assert any(
            entry.get("kind") == "source-snapshot"
            for entry in cli("cache", "list", "ArchiveKit")["entries"]
        )
        assert cli("cache", "verify")["status"] == "passed"
        snapshot = next((parent / "cache/snapshots").glob("*/Sources/value.c"))
        original = snapshot.read_bytes()
        snapshot.write_bytes(b"tampered\n")
        cli("cache", "verify", success=False)
        snapshot.write_bytes(original)
        assert cli("cache", "clean", "ArchiveKit")["removed"] > 0
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    verified = [
        "external HTTP archive with authenticated headers and SHA-256",
        "external HTTP offline deployment and byte-preserved lockfile",
        "snapshot listing and targeted cleanup",
        "cache verify detects a modified source snapshot",
    ]
    svn, svnadmin = shutil.which("svn"), shutil.which("svnadmin")
    assert svn and svnadmin, (
        "Subversion tools are required by this source contract suite"
    )
    repository = parent / "svn"
    subprocess.run(
        [svnadmin, "create", str(repository)], check=True, capture_output=True
    )
    checkout = parent / "svn-working"
    subprocess.run(
        [svn, "checkout", repository.as_uri(), str(checkout)],
        check=True,
        capture_output=True,
    )
    checkout.joinpath("SVNKit.c").write_text("int svn_value(void) { return 1; }\n")
    checkout.joinpath("SVNKit.podspec.json").write_text(
        json.dumps({"name": "SVNKit", "version": "1.0", "source_files": "*.c"})
    )

    def svn_commit(message):
        subprocess.run(
            [svn, "add", "--force", str(checkout)], check=True, capture_output=True
        )
        subprocess.run(
            [svn, "commit", "-m", message, str(checkout)],
            check=True,
            capture_output=True,
        )

    svn_commit("first")
    manifest("pod 'SVNKit', :svn => '" + repository.as_uri() + "'")
    cli("install", "--no-integrate")
    lock = work.joinpath("Podfile.lock").read_bytes()
    checkout.joinpath("SVNKit.c").write_text("int svn_value(void) { return 2; }\n")
    svn_commit("second")
    env["SWIFTPODS_CACHE_ROOT"] = str(parent / "fresh-cache")
    cli("install", "--no-integrate", "--deployment")
    assert "return 1" in work.joinpath("Pods/SVNKit/SVNKit.c").read_text()
    assert lock == work.joinpath("Podfile.lock").read_bytes()
    cli("update", "SVNKit", "--no-integrate")
    assert "return 2" in work.joinpath("Pods/SVNKit/SVNKit.c").read_text()
    cli("install", "--no-integrate", "--deployment", "--offline")
    verified.append(
        "Subversion frozen revision in a fresh cache, selected update and offline deployment"
    )
    evaluated = work / "EvalKit"
    evaluated.mkdir()
    evaluated.joinpath("Value.c").write_text("int eval_value(void) { return 1; }\n")
    evaluated.joinpath("EvalKit.podspec").write_text(
        "File.open(File.join(__dir__, 'evaluations'), 'a') { |file| file.puts('evaluated') }\nPod::Spec.new do |spec|\n spec.name = 'EvalKit'\n spec.version = '1.0'\n spec.source_files = '*.c'\nend\n"
    )
    manifest("pod 'EvalKit', :path => './EvalKit'")
    cli("install", "--no-integrate", "--offline")
    cli("install", "--no-integrate", "--offline")
    assert evaluated.joinpath("evaluations").read_text().splitlines() == [
        "evaluated",
        "evaluated",
    ]
    verified.append(
        "canonical external podspec checksums do not repeat Ruby evaluation within an install"
    )
    # Empty imported Gemfile uses the external Ruby's Bundler without importing an engine.
    work.joinpath("Gemfile").write_text("source 'https://rubygems.org'\n")
    ruby = env["SWIFTPODS_RUBY"]
    subprocess.run(
        [ruby, "-S", "bundle", "lock", "--local"],
        cwd=work,
        env=env,
        check=True,
        capture_output=True,
    )
    cli("env", "import", "--gemfile", "Gemfile", "--name", "fixture", "--local")
    original = work.joinpath("Podfile").read_text()
    work.joinpath("Podfile").write_text("ensure_bundler! '>= 2'\n" + original)
    cli("install", "--no-integrate", "--environment", "fixture", "--offline")
    work.joinpath("Podfile").write_text("ensure_bundler! '> 999'\n" + original)
    cli(
        "install",
        "--no-integrate",
        "--environment",
        "fixture",
        "--offline",
        success=False,
    )
    verified.append(
        "imported frozen Bundler environment accepts and rejects explicit version requirements"
    )
    report = {
        "status": "passed",
        "engine": "swift",
        "fixture": str(parent),
        "verified": verified,
        "unverified": [
            "Mercurial executable is unavailable on this host",
            "remote VCS authentication",
        ],
    }
    ROOT.joinpath("test-results/native-source-contract.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    execute(main, "native-source-contract.json")
