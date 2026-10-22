#!/usr/bin/env python3
"""Explicit release signing; never chooses an identity, publishes, or changes PATH."""

import argparse
import hashlib
import json
import subprocess
from pathlib import Path

from scripts.support.bootstrap import ROOT, manifest


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
    if subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT).strip():
        raise RuntimeError("Release signing requires a clean committed source revision")
    if not (bundle / "bin/swiftpods").is_file():
        raise RuntimeError("Package a complete bundle before signing")
    if (bundle / "compatibility.cms").exists():
        raise RuntimeError("Bundle is already signed; assemble a new package")
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
    certificate_name = matches[0].split('"', 2)[1]
    for path in sorted(bundle.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        description = subprocess.check_output(["/usr/bin/file", "-b", path], text=True)
        if "Mach-O" not in description or "object" in description:
            continue
        command = [
            "/usr/bin/codesign",
            "--force",
            "--timestamp",
            "--options",
            "runtime",
            "--sign",
            args.identity,
        ]
        run(*command, path)
        run("/usr/bin/codesign", "--verify", "--strict", path)
    # Sign binaries first: the signed manifest must hash their final bytes.
    manifest(bundle)
    report = json.loads((bundle / "compatibility.json").read_text())
    report["status"] = "release"
    report["release_acceptance"] = (
        "experimental; certification is limited to the recorded matrix"
    )
    report["signing"] = {
        "identity": certificate_name,
        "notarization_requested": args.notarize,
    }
    (bundle / "compatibility.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n"
    )
    run(
        "/usr/bin/security",
        "cms",
        "-S",
        "-H",
        "SHA256",
        "-u",
        "6",
        "-N",
        certificate_name,
        "-i",
        bundle / "compatibility.json",
        "-o",
        bundle / "compatibility.cms",
    )
    # This command validates the CMS identity and complete inventory before
    # external Ruby starts. A mismatched signer is a packaging failure.
    run(
        "/usr/bin/env",
        "SWIFTPODS_BUNDLE=" + str(bundle),
        bundle / "bin/swiftpods",
        "runtime",
        "verify",
        "--json",
    )
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
