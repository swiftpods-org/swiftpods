#!/usr/bin/env python3
"""Prepare release archives, checksums, release.json and the installer; never publishes."""

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from scripts.install import extract_archive
from scripts.support.version import ROOT, source_version

CONTENTS = {"LICENSE", "README.md", "bin/swiftpods"}


def inspect_archive(archive):
    """Read the platform and signature of the archived executable itself."""
    with tempfile.TemporaryDirectory(
        prefix="swiftpods-release-inventory-"
    ) as temporary:
        root = extract_archive(Path(archive).read_bytes(), Path(temporary))
        files = {
            path.relative_to(root).as_posix()
            for path in root.rglob("*")
            if path.is_symlink() or not path.is_dir()
        }
        if files != CONTENTS:
            raise RuntimeError(
                "Release archive must contain exactly " + ", ".join(sorted(CONTENTS))
            )
        executable = root / "bin/swiftpods"
        if executable.is_symlink() or not executable.stat().st_mode & 0o111:
            raise RuntimeError("Release executable has no executable permissions")
        architectures = subprocess.check_output(
            ["/usr/bin/lipo", "-archs", executable], text=True
        ).split()
        minimums = re.findall(
            r"\bminos\s+([0-9]+(?:\.[0-9]+){1,2})\b",
            subprocess.check_output(
                ["/usr/bin/xcrun", "vtool", "-show-build", executable], text=True
            ),
        )
        if (
            len(architectures) != 1
            or architectures[0] not in ("arm64", "x86_64")
            or len(minimums) != 1
        ):
            raise RuntimeError("Release executable must target one macOS architecture")
        verified = not subprocess.run(
            ["/usr/bin/codesign", "--verify", "--strict", executable],
            capture_output=True,
        ).returncode
        authority = re.search(
            r"^Authority=(.+)$",
            subprocess.run(
                ["/usr/bin/codesign", "--display", "--verbose=2", executable],
                capture_output=True,
                text=True,
            ).stderr,
            re.M,
        )
        return {
            "architecture": architectures[0],
            "minimum_macos": minimums[0],
            "signed_by": authority.group(1) if verified and authority else None,
        }


def prepare(args, destination):
    if args.version != source_version(ROOT):
        raise RuntimeError("Release version differs from the source version")
    if (
        not args.development
        and subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT).strip()
    ):
        raise RuntimeError(
            "Release preparation requires a clean committed revision; use --development only for unpublished fixtures"
        )
    commit = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
    ).strip()
    archives = list(args.archive)
    for index, bundle in enumerate(args.bundle):
        temporary = destination / ("input-" + str(index) + ".zip")
        subprocess.run(
            [
                "/usr/bin/ditto",
                "-c",
                "-k",
                "--norsrc",
                "--noextattr",
                "--noqtn",
                "--keepParent",
                str(bundle.resolve()),
                str(temporary),
            ],
            check=True,
        )
        archives.append(temporary)
    notarizations = {}
    for path in args.notarization:
        receipt = json.loads(path.read_text())
        checksum = receipt.get("archive_sha256", "")
        if (
            receipt.get("status") != "Accepted"
            or not isinstance(receipt.get("id"), str)
            or not receipt["id"].strip()
            or not re.fullmatch(r"[0-9a-f]{64}", checksum)
            or checksum in notarizations
        ):
            raise RuntimeError(
                "Invalid or duplicate notarization receipt: " + str(path)
            )
        notarizations[checksum] = receipt
    assets, seen = [], set()
    for archive in archives:
        executable = inspect_archive(archive)
        architecture = executable["architecture"]
        minimum = executable["minimum_macos"]
        key = architecture, minimum
        if key in seen:
            raise RuntimeError("Duplicate release architecture/OS floor")
        seen.add(key)
        filename = (
            "swiftpods-"
            + args.version
            + "-macos-"
            + minimum
            + "-"
            + architecture
            + ".zip"
        )
        target = destination / filename
        if archive.parent == destination:
            archive.rename(target)
        else:
            shutil.copy2(archive, target)
        sha256 = hashlib.sha256(target.read_bytes()).hexdigest()
        notarization = notarizations.pop(sha256, None)
        if not args.development and (
            notarization is None
            or not (executable["signed_by"] or "").startswith(
                "Developer ID Application: "
            )
        ):
            raise RuntimeError(
                "Each release archive requires Developer ID signing and matching accepted notarization"
            )
        assets.append(
            {
                "os": "macos",
                "architecture": architecture,
                "minimum_macos": minimum,
                "filename": filename,
                "sha256": sha256,
                "url": "https://github.com/swiftpods-org/swiftpods/releases/download/v"
                + args.version
                + "/"
                + filename,
                "notarization": (
                    {"id": notarization["id"], "status": notarization["status"]}
                    if notarization
                    else None
                ),
            }
        )
    assets.sort(key=lambda asset: (asset["architecture"], asset["minimum_macos"]))
    if notarizations:
        raise RuntimeError(
            "A notarization receipt does not match a supplied release archive"
        )
    shutil.copy2(ROOT / "scripts/install.py", destination / "install.py")
    release = {
        "schema_version": 2,
        "development": args.development,
        "publishable": not args.development
        and all(asset["notarization"] is not None for asset in assets),
        "source_revision": {"commit": commit},
        "version": args.version,
        "assets": assets,
        "installer_sha256": hashlib.sha256(
            (destination / "install.py").read_bytes()
        ).hexdigest(),
    }
    (destination / "release.json").write_text(json.dumps(release, indent=2) + "\n")
    checksums = []
    for name in sorted(
        ["release.json", "install.py", *[asset["filename"] for asset in assets]]
    ):
        checksums.append(
            hashlib.sha256((destination / name).read_bytes()).hexdigest() + "  " + name
        )
    (destination / "SHA256SUMS").write_text("\n".join(checksums) + "\n")
    print(
        "Manifest SHA-256:",
        hashlib.sha256((destination / "release.json").read_bytes()).hexdigest(),
    )
    print("Installer SHA-256:", release["installer_sha256"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--bundle", type=Path, action="append", default=[])
    parser.add_argument("--archive", type=Path, action="append", default=[])
    parser.add_argument(
        "--notarization",
        type=Path,
        action="append",
        default=[],
        help="Accepted notarytool JSON receipt bound to each archive SHA-256",
    )
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument(
        "--development",
        action="store_true",
        help="Prepare explicitly unpublished development fixtures from a dirty checkout",
    )
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?", args.version):
        parser.error("Explicit release version required, without a leading v")
    if not args.bundle and not args.archive:
        parser.error("At least one --bundle or --archive is required")
    if not args.development and not args.notarization:
        parser.error("Release preparation requires accepted --notarization receipts")
    destination = args.destination.absolute()
    if destination.exists() or destination.is_symlink():
        raise RuntimeError("Release destination already exists")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=".swiftpods-release-", dir=destination.parent
    ) as temporary:
        staging = Path(temporary) / "release"
        staging.mkdir()
        prepare(args, staging)
        staging.rename(destination)
    print("Prepared", destination)


if __name__ == "__main__":
    main()
