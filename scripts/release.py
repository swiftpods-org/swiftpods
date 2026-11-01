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

from scripts.apple_signing import inspect_signature, validate_publisher
from scripts.install import MAX_DOWNLOAD_BYTES, distribution_digest, extract_archive
from scripts.support.version import ROOT, source_version

CONTENTS = {"LICENSE", "README.md", "bin/swiftpods"}
OBJECT_ID_PATTERN = r"[0-9a-f]{40}(?:[0-9a-f]{24})?"


def inspect_archive(archive):
    """Read the platform and signature of the archived executable itself."""
    archive = Path(archive)
    if archive.stat().st_size > MAX_DOWNLOAD_BYTES:
        raise RuntimeError("Release archive exceeds the size limit")
    with tempfile.TemporaryDirectory(
        prefix="swiftpods-release-inventory-"
    ) as temporary:
        root = extract_archive(archive.read_bytes(), Path(temporary))
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
        return {
            "architecture": architectures[0],
            "minimum_macos": minimums[0],
            "publisher": inspect_signature(executable),
            "content_sha256": distribution_digest(root),
        }


def prepare(args, destination):
    if args.version != source_version(ROOT):
        raise RuntimeError("Release version differs from the source version")
    tag_object = getattr(args, "tag_object", None)
    if tag_object is not None and (
        not isinstance(tag_object, str)
        or re.fullmatch(OBJECT_ID_PATTERN, tag_object) is None
    ):
        raise RuntimeError("Release requires a valid annotated tag object")
    if not args.development and tag_object is None:
        raise RuntimeError("Production release requires an annotated tag object")
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
    assets, publishers, seen = [], [], set()
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
        publisher = executable.get("publisher")
        if publisher is not None and not validate_publisher(publisher):
            raise RuntimeError("Release archive has invalid publisher identity")
        if not args.development and (notarization is None or publisher is None):
            raise RuntimeError(
                "Each release archive requires an exact Developer ID publisher and matching accepted notarization"
            )
        publishers.append(publisher)
        assets.append(
            {
                "os": "macos",
                "architecture": architecture,
                "minimum_macos": minimum,
                "filename": filename,
                "sha256": sha256,
                "content_sha256": executable["content_sha256"],
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
    publisher = (
        publishers[0]
        if publishers and all(value == publishers[0] for value in publishers)
        else None
    )
    if not args.development and publisher is None:
        raise RuntimeError("All release architectures must use the same exact Developer ID publisher")
    shutil.copy2(ROOT / "scripts/install.py", destination / "install.py")
    source_revision = {"commit": commit}
    if tag_object is not None:
        source_revision["tag_object"] = tag_object
    release = {
        "schema_version": 3,
        "development": args.development,
        "publishable": not args.development
        and publisher is not None
        and all(asset["notarization"] is not None for asset in assets),
        "publisher": publisher,
        "source_revision": source_revision,
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
    parser.add_argument(
        "--tag-object",
        help="Exact annotated source tag object ID (required for production)",
    )
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
    if args.tag_object is not None and re.fullmatch(
        OBJECT_ID_PATTERN, args.tag_object
    ) is None:
        parser.error("--tag-object must be a complete hexadecimal Git object ID")
    if not args.development and args.tag_object is None:
        parser.error("Production release preparation requires --tag-object")
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
