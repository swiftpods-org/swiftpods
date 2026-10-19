#!/usr/bin/env python3
"""Check the native archive inventory, relocation and pinned local installer."""

import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from bootstrap import ROOT, environment
from bundle_path_regressions import runtime_boundaries
from reporting import execute


def main():
    bundle = Path(sys.argv[1]).resolve()
    manifest = json.loads((bundle / "compatibility.json").read_text())
    assert manifest["engine"] == "swift"
    assert manifest["gems"] == [] and manifest["native_ruby_libraries"] == []
    assert not any(
        name.startswith(("vendor/", "gems/", "runtime/")) for name in manifest["files"]
    )
    assert (
        "host/dsl.rb" in manifest["files"] and "host/host.rb" not in manifest["files"]
    )
    matrix_checked = False
    if any(
        item["report"] == "native-platforms.json"
        for item in manifest["verification_evidence"]["reports"]
    ):
        matrix_checked = True
        matrix = manifest["matrix"]
        builds = [row for row in matrix if row["status"] == "build_passed"]
        archives = [row for row in matrix if row["status"] == "unsigned_archive_passed"]
        assert len(builds) == 60 and len(archives) == 18
        assert {row["configuration"] for row in builds} == {"Debug", "Release"}
        assert (
            len({(row["linkage"], row["sdk"], row["configuration"]) for row in builds})
            == 60
        )
        assert all(
            row["configuration"] == "Release" and row["signed"] is False
            for row in archives
        )
        assert all(row.get("platform") and row.get("architecture") for row in matrix)
    parent = Path(tempfile.mkdtemp(prefix="native-distribution-", dir=ROOT / ".build"))
    relocated = parent / "relocated" / "SwiftPods"
    relocated.parent.mkdir()
    shutil.copytree(bundle, relocated, symlinks=True)
    env = environment(relocated)
    runtime_paths = runtime_boundaries(
        parent, relocated / "bin/swiftpods", env, relocated
    )
    subprocess.run(
        [str(relocated / "bin/swiftpods"), "runtime", "verify", "--json"],
        env=env,
        check=True,
        stdout=subprocess.DEVNULL,
    )
    release = parent / "release"
    subprocess.run(
        [
            sys.executable,
            "scripts/release.py",
            "--development",
            "--version",
            manifest["swiftpods_version"],
            "--bundle",
            str(relocated),
            "--destination",
            str(release),
        ],
        cwd=ROOT,
        check=True,
    )
    released = json.loads((release / "release.json").read_text())
    assert released["development"] and not released["publishable"]
    assert all(
        asset["url"].startswith(
            "https://github.com/swiftpods-org/swiftpods-release/releases/"
        )
        for asset in released["assets"]
    )
    sha = hashlib.sha256((release / "release.json").read_bytes()).hexdigest()
    prefix = parent / "installed"
    arguments = [
        sys.executable,
        str(release / "install.py"),
        "--version",
        manifest["swiftpods_version"],
        "--manifest-sha256",
        sha,
        "--manifest",
        str(release / "release.json"),
        "--archive",
        str(release / released["assets"][0]["filename"]),
        "--prefix",
        str(prefix),
    ]
    subprocess.run(arguments, env=env, check=True)
    subprocess.run(arguments, env=env, check=True)
    launcher = prefix / "bin/swiftpods"
    launcher.unlink()
    result = subprocess.run(arguments, env=env, capture_output=True, text=True)
    assert result.returncode != 0 and "launcher" in result.stderr
    assert not launcher.exists()
    launcher.write_text("user-owned replacement\n")
    result = subprocess.run(arguments, env=env, capture_output=True, text=True)
    assert result.returncode != 0 and "launcher" in result.stderr
    assert launcher.read_text() == "user-owned replacement\n"
    launcher.unlink()
    launcher.symlink_to("../libexec/bin/swiftpods")
    subprocess.run(arguments, env=env, check=True)
    result = subprocess.run(
        arguments[: arguments.index("--manifest-sha256") + 1]
        + ["0" * 64]
        + arguments[arguments.index("--manifest-sha256") + 2 :],
        env=env,
        capture_output=True,
    )
    assert result.returncode != 0
    (relocated / "host/dsl.rb").write_text("# tampered\n")
    result = subprocess.run(
        [str(relocated / "bin/swiftpods"), "runtime", "verify", "--json"],
        env=env,
        capture_output=True,
    )
    assert result.returncode != 0
    rejected = parent / "rejected-release"
    result = subprocess.run(
        [
            sys.executable,
            "scripts/release.py",
            "--development",
            "--version",
            manifest["swiftpods_version"],
            "--bundle",
            str(relocated),
            "--destination",
            str(rejected),
        ],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0 and "inventory/checksum mismatch" in result.stderr, (
        result.stderr
    )
    assert not rejected.exists(), "Failed preparation exposed a partial release"
    (ROOT / "test-results/native-distribution.json").write_text(
        json.dumps(
            {
                "status": "passed",
                "engine": "swift",
                "bundle_digest": manifest["bundle_digest"],
                "fixture": str(parent),
                "runtime_path_boundaries": runtime_paths,
                "verified": [
                    "runtime inventory excludes reference engine/gems",
                    "relocation",
                    "release URLs",
                    "checksummed installer",
                    "idempotent install",
                    "missing and replaced launchers reject idempotent installation without overwriting user files",
                    "bad checksum rejected",
                    "tampered adapter rejected",
                    "release preparation rejects a changed inventory and leaves no partial destination",
                ]
                + ["bundle_path_" + case for case in runtime_paths]
                + (
                    [
                        "current 60-build/18-archive matrix includes platform architecture configuration and signing status"
                    ]
                    if matrix_checked
                    else []
                ),
                "unverified": [
                    "remote publication",
                    "Homebrew installation",
                    "signing",
                    "Intel",
                ],
            },
            indent=2,
        )
        + "\n"
    )


if __name__ == "__main__":
    execute(main, "native-distribution.json")
