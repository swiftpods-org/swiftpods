#!/usr/bin/env python3
"""Explicit release signing; never chooses an identity, publishes, or changes PATH."""

import argparse
import hashlib
import json
import subprocess
from pathlib import Path

from scripts.support.version import ROOT, source_version


def run(*arguments):
    subprocess.run(list(map(str, arguments)), check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument(
        "--identity",
        required=True,
        help="Explicit Developer ID Application certificate identity",
    )
    parser.add_argument("--notarize", action="store_true")
    parser.add_argument("--keychain-profile")
    parser.add_argument("--keychain", type=Path)
    args = parser.parse_args()
    bundle = args.bundle.resolve()
    executable = bundle / "bin/swiftpods"
    if subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT).strip():
        raise RuntimeError("Release signing requires a clean committed source revision")
    if not executable.is_file():
        raise RuntimeError("Package a complete bundle before signing")
    archive = bundle.with_name(bundle.name + ".zip")
    if archive.exists():
        raise RuntimeError("Release archive already exists: " + str(archive))
    if args.notarize and not args.keychain_profile:
        parser.error("--notarize requires an explicit --keychain-profile")
    identity = subprocess.check_output(
        ["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"], text=True
    )
    matches = [
        line
        for line in identity.splitlines()
        if args.identity in line and "Developer ID Application:" in line
    ]
    if len(matches) != 1:
        raise RuntimeError(
            "Identity must uniquely select an available Developer ID Application certificate"
        )
    run(
        "/usr/bin/codesign",
        "--force",
        "--timestamp",
        "--options",
        "runtime",
        "--sign",
        args.identity,
        executable,
    )
    run("/usr/bin/codesign", "--verify", "--strict", executable)
    # The hardened, signed executable must still start and report its source version.
    actual = json.loads(
        subprocess.check_output([str(executable), "version", "--json"], timeout=60)
    )
    if actual["version"] != source_version(ROOT):
        raise RuntimeError("Signed CLI version differs from its source version")
    run(
        "/usr/bin/ditto",
        "-c",
        "-k",
        "--norsrc",
        "--noextattr",
        "--noqtn",
        "--keepParent",
        bundle,
        archive,
    )
    if args.notarize:
        command = [
            "/usr/bin/xcrun",
            "notarytool",
            "submit",
            archive,
            "--keychain-profile",
            args.keychain_profile,
            "--wait",
            "--output-format",
            "json",
        ]
        if args.keychain:
            command += ["--keychain", args.keychain]
        submission = json.loads(
            subprocess.check_output(list(map(str, command)), text=True)
        )
        submission["archive_sha256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
        archive.with_suffix(".zip.notary.json").write_text(
            json.dumps(submission, indent=2) + "\n"
        )
        if submission.get("status") != "Accepted":
            raise RuntimeError(
                "Notarization was not accepted; inspect "
                + str(archive.with_suffix(".zip.notary.json"))
            )
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_suffix(".zip.sha256").write_text(checksum + "  " + archive.name + "\n")
    print(archive)


if __name__ == "__main__":
    main()
