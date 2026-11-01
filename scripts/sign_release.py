#!/usr/bin/env python3
"""Explicit release signing; never chooses an identity, publishes, or changes PATH."""

import argparse
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path

from scripts.apple_signing import apple_tool_environment, inspect_signature, trusted_xcode_tool
from scripts.support.version import ROOT


def release_environment():
    return apple_tool_environment()


def run(*arguments):
    subprocess.run(
        list(map(str, arguments)),
        check=True,
        env=release_environment(),
        stdin=subprocess.DEVNULL,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument(
        "--identity",
        required=True,
        help="Exact 40-character SHA-1 fingerprint of the Developer ID certificate",
    )
    parser.add_argument(
        "--team-id", required=True, help="Exact 10-character Apple Developer Team ID"
    )
    parser.add_argument("--notarize", action="store_true")
    parser.add_argument("--keychain-profile")
    parser.add_argument("--keychain", type=Path)
    args = parser.parse_args()
    bundle = args.bundle.resolve()
    executable = bundle / "bin/swiftpods"
    if subprocess.check_output(
        ["git", "status", "--porcelain"], cwd=ROOT, env=release_environment()
    ).strip():
        raise RuntimeError("Release signing requires a clean committed source revision")
    if not executable.is_file():
        raise RuntimeError("Package a complete bundle before signing")
    archive = bundle.with_name(bundle.name + ".zip")
    if archive.exists():
        raise RuntimeError("Release archive already exists: " + str(archive))
    if args.notarize and not args.keychain_profile:
        parser.error("--notarize requires an explicit --keychain-profile")
    fingerprint = args.identity.upper()
    if re.fullmatch(r"[0-9A-F]{40}", fingerprint) is None:
        parser.error("--identity must be an exact 40-character certificate fingerprint")
    if re.fullmatch(r"[A-Z0-9]{10}", args.team_id) is None:
        parser.error("--team-id must be an exact 10-character Apple Developer Team ID")
    identity = subprocess.check_output(
        ["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"],
        text=True,
        env=release_environment(),
        stdin=subprocess.DEVNULL,
    )
    matches = [
        match
        for line in identity.splitlines()
        if (
            match := re.match(
                r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"\s*$', line
            )
        )
        and match.group(1).upper() == fingerprint
        and match.group(2).startswith("Developer ID Application: ")
    ]
    if len(matches) != 1:
        raise RuntimeError(
            "Fingerprint must select exactly one available Developer ID Application certificate"
        )
    run(
        "/usr/bin/codesign",
        "--force",
        "--timestamp",
        "--options",
        "runtime",
        "--sign",
        fingerprint,
        executable,
    )
    publisher = inspect_signature(executable)
    if publisher is None:
        raise RuntimeError("Signed release failed strict code-signature verification")
    if (
        publisher["certificate_sha1"] != fingerprint
        or publisher["team_id"] != args.team_id
    ):
        raise RuntimeError("Signed release publisher differs from the pinned certificate or Team ID")
    # Never execute artifact code in this process. CI imports signing and notarization
    # credentials before calling this tool, so all functional smoke tests belong to a
    # subsequent fresh job that has no release credentials.
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
        notarytool = trusted_xcode_tool("notarytool")
        command = [
            notarytool,
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
            subprocess.check_output(
                list(map(str, command)),
                text=True,
                env=release_environment(),
                stdin=subprocess.DEVNULL,
            )
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
