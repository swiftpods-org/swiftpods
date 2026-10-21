#!/usr/bin/env python3
"""Install and test a packaged formula through a temporary local Homebrew tap."""

import argparse
import functools
import hashlib
import http.server
import json
import os
import shutil
import subprocess
import threading
from pathlib import Path

from local_build import fixture_directory, results_directory
from release import homebrew_formula
from reporting import execute


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", required=True, type=Path)
    args = parser.parse_args()
    bundle = args.bundle.resolve()
    metadata = json.loads((bundle / "compatibility.json").read_text())
    brew = shutil.which("brew")
    if not brew:
        raise RuntimeError("Homebrew is required for this check")
    parent = fixture_directory("native-homebrew-")
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("SWIFTPODS_", "BUNDLE_", "GEM_"))
        and key not in ("RUBYOPT", "RUBYLIB")
    }
    env.update(
        HOMEBREW_NO_AUTO_UPDATE="1",
        HOMEBREW_NO_INSTALL_CLEANUP="1",
        HOMEBREW_NO_ENV_HINTS="1",
    )
    log = parent / "homebrew.log"

    def run(command, cwd=parent, check=True):
        result = subprocess.run(
            list(map(str, command)),
            cwd=cwd,
            env=env,
            capture_output=True,
            text=True,
            timeout=300,
        )
        with log.open("a") as output:
            output.write(
                "$ "
                + " ".join(map(str, command))
                + "\n"
                + result.stdout
                + result.stderr
            )
        if check and result.returncode:
            raise RuntimeError("Homebrew check failed; see " + str(log))
        return result

    installed = run([brew, "list", "--formula", "--full-name"]).stdout.splitlines()
    if any(name.split("/")[-1] == "swiftpods" for name in installed):
        raise RuntimeError(
            "This check requires no installed SwiftPods formula; the existing installation was preserved"
        )
    token = (
        "swiftpods-fixture/acceptance-"
        + hashlib.sha256(str(parent).encode()).hexdigest()[:12]
    )
    tap = parent / "tap"
    (tap / "Formula").mkdir(parents=True)
    archive = parent / "SwiftPods.zip"
    run(
        [
            "/usr/bin/ditto",
            "-c",
            "-k",
            "--norsrc",
            "--noextattr",
            "--noqtn",
            "--keepParent",
            bundle,
            archive,
        ]
    )

    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def handle(self):
            try:
                super().handle()
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = http.server.ThreadingHTTPServer(
        ("127.0.0.1", 0), functools.partial(Handler, directory=str(parent))
    )
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    asset = {
        "architecture": metadata["build_host"]["architecture"],
        "minimum_macos": metadata["minimum_macos"],
        "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
        "url": "http://127.0.0.1:" + str(server.server_port) + "/SwiftPods.zip",
    }
    formula = tap / "Formula/swiftpods.rb"
    formula.write_text(homebrew_formula(metadata["swiftpods_version"], [asset]))
    run(["git", "init", tap])
    run(["git", "-C", tap, "add", "Formula/swiftpods.rb"])
    run(
        [
            "git",
            "-C",
            tap,
            "-c",
            "user.name=SwiftPods Tests",
            "-c",
            "user.email=tests@example.invalid",
            "commit",
            "-m",
            "isolated formula",
        ]
    )
    tapped = installed_by_test = False
    try:
        run([brew, "tap", token, tap])
        tapped = True
        # The full tap name avoids resolving another formula with this name.
        result = run([brew, "install", "--formula", token + "/swiftpods"], check=False)
        installed_by_test = (
            token + "/swiftpods"
            in run([brew, "list", "--formula", "--full-name"]).stdout.splitlines()
        )
        if result.returncode:
            raise RuntimeError("Formula installation failed; see " + str(log))
        if not installed_by_test:
            raise RuntimeError("Installed formula does not belong to the temporary tap")
        run([brew, "test", token + "/swiftpods"])
        prefix = Path(run([brew, "--prefix", token + "/swiftpods"]).stdout.strip())
        binary = prefix / "bin/swiftpods"
        run([binary, "runtime", "verify", "--json"])
        version = json.loads(run([binary, "version", "--json"]).stdout)
        if version["swiftpods_version"] != metadata["swiftpods_version"]:
            raise RuntimeError("Installed formula version mismatch")
        project = parent / "project"
        project.mkdir()
        (project / "Podfile").write_text(
            "platform :osx, '13.0'\ninstall! 'swiftpods', :integrate_targets => false\ntarget('App') {}\npre_install { raise 'Installation engine gem loaded' if Gem.loaded_specs.key?('cocoapods'); File.write('hook.txt', 'external-ruby') }\n"
        )
        env["SWIFTPODS_CACHE_ROOT"] = str(parent / "cache")
        run([binary, "install", "--json"], cwd=project)
        if (project / "hook.txt").read_text() != "external-ruby":
            raise RuntimeError("Formula did not execute the external Ruby adapter")
    finally:
        try:
            if installed_by_test:
                run([brew, "uninstall", "--formula", token + "/swiftpods"])
            if tapped:
                run([brew, "untap", token])
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
    report = {
        "status": "passed",
        "fixture": str(parent),
        "log": str(log),
        "bundle_digest": metadata["bundle_digest"],
        "verified": [
            "generated formula downloads the exact checksummed archive",
            "real Homebrew installation and brew test",
            "installed wrapper selects the external Ruby and installed bundle",
            "Podfile hook executes without installation-engine gems",
            "temporary formula installation and tap removed",
        ],
        "unverified": [
            "public release URL",
            "pristine operating system",
            "other architectures or macOS versions",
        ],
    }
    (results_directory() / "native-homebrew.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    execute(main, "native-homebrew.json")
