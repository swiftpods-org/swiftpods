#!/usr/bin/env python3
"""Validate prepared public assets and publish them together through GitHub Releases."""

import argparse
import hashlib
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

REPOSITORY = "swiftpods-org/swiftpods"


def validate(directory, version, commit):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?", version):
        raise RuntimeError("Invalid release version")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise RuntimeError("Release requires an exact source commit")
    manifest = json.loads((directory / "release.json").read_text())
    if (
        manifest.get("schema_version") != 1
        or manifest.get("version") != version
        or manifest.get("runtime_mode") != "external"
        or manifest.get("development") is not False
        or manifest.get("publishable") is not True
        or manifest.get("source_revision", {}).get("commit") != commit
    ):
        raise RuntimeError("Manifest is not publishable from this tagged revision")
    assets = manifest["assets"]
    if len(assets) != 2 or {asset["architecture"] for asset in assets} != {
        "arm64",
        "x86_64",
    }:
        raise RuntimeError("A release requires both macOS architectures")
    expected = {"install.py": manifest["installer_sha256"]}
    base = f"https://github.com/{REPOSITORY}/releases/download/v{version}/"
    for asset in assets:
        name = asset["filename"]
        if (
            not re.fullmatch(r"swiftpods-[A-Za-z0-9._-]+\.zip", name)
            or name in expected
            or asset["url"] != base + name
            or asset["os"] != "macos"
            or asset.get("notarization", {}).get("status") != "Accepted"
        ):
            raise RuntimeError("Invalid or unnotarized release asset")
        expected[name] = asset["sha256"]
    manifest_sha256 = hashlib.sha256(
        (directory / "release.json").read_bytes()
    ).hexdigest()
    expected["release.json"] = manifest_sha256
    checksums = (directory / "SHA256SUMS").read_text().splitlines()
    if len(checksums) != len(expected) or set(checksums) != {
        checksum + "  " + name for name, checksum in expected.items()
    }:
        raise RuntimeError("Release checksum list does not match the public assets")
    paths = []
    for name, checksum in expected.items():
        path = directory / name
        if (
            path.is_symlink()
            or hashlib.sha256(path.read_bytes()).hexdigest() != checksum
        ):
            raise RuntimeError("Release asset changed: " + name)
        paths.append(path)
    paths.append(directory / "SHA256SUMS")
    return paths, manifest_sha256


def existing_release(tag):
    try:
        return json.loads(subprocess.check_output(
            ["gh", "api", f"repos/{REPOSITORY}/releases/tags/{tag}"],
            text=True, stderr=subprocess.PIPE,
        ))
    except subprocess.CalledProcessError as error:
        # Missing is a valid retry state after deletion. Authentication and
        # transport failures must still stop publication before any changes.
        if re.search(r"\bHTTP 404\b", error.stderr or ""):
            return None
        raise


def replace_release(tag, commit, expected_tag_object):
    if not re.fullmatch(r"[0-9a-f]{40}", expected_tag_object):
        raise RuntimeError("Replacement requires the exact previous tag object")
    reference = json.loads(
        subprocess.check_output(
            ["gh", "api", f"repos/{REPOSITORY}/git/ref/tags/{tag}"], text=True
        )
    )
    current = reference["object"]["sha"]
    if current not in (expected_tag_object, commit):
        raise RuntimeError("Remote tag changed before release replacement")
    existing = existing_release(tag)
    if existing and existing.get("immutable"):
        raise RuntimeError("An immutable release cannot be replaced")
    # Keep the old release available if retargeting fails. A retry can observe
    # either the expected old tag or the exact destination commit of this run.
    if current != commit:
        subprocess.run(
            [
                "gh",
                "api",
                "--method",
                "PATCH",
                f"repos/{REPOSITORY}/git/refs/tags/{tag}",
                "-f",
                "sha=" + commit,
                "-F",
                "force=true",
            ],
            check=True,
        )
    if existing:
        subprocess.run(
            ["gh", "release", "delete", tag, "--repo", REPOSITORY, "--yes"],
            check=True,
        )


def publish(directory, version, commit, replace_tag_object=None):
    paths, checksum = validate(directory, version, commit)
    tag = "v" + version
    if replace_tag_object is not None:
        replace_release(tag, commit, replace_tag_object)
    remote = subprocess.check_output(
        ["gh", "api", f"repos/{REPOSITORY}/commits/{tag}", "--jq", ".sha"], text=True
    ).strip()
    if remote != commit:
        raise RuntimeError("Remote tag no longer points to the tested source commit")
    with tempfile.TemporaryDirectory(prefix="swiftpods-release-notes-") as temporary:
        notes = Path(temporary) / "notes.md"
        notes.write_text(
            "Signed and notarized macOS builds for Apple Silicon and Intel.\n\n"
            "Download the installer and archives below. See "
            "[installation and CI](https://github.com/"
            + REPOSITORY
            + "/blob/"
            + tag
            + "/docs/Release.md) for setup.\n\n"
            "`release.json` SHA-256: `" + checksum + "`\n"
        )
        # Keep an incomplete upload hidden. Replacement requires explicit opt-in above.
        subprocess.run(
            [
                "gh",
                "release",
                "create",
                tag,
                *map(str, paths),
                "--repo",
                REPOSITORY,
                "--verify-tag",
                "--target",
                commit,
                "--title",
                "SwiftPods " + version,
                "--notes-file",
                str(notes),
                "--draft",
            ],
            check=True,
        )
    options = ["--prerelease", "--latest=false"] if "-" in version else ["--latest"]
    subprocess.run(
        ["gh", "release", "edit", tag, "--repo", REPOSITORY, "--draft=false", *options],
        check=True,
    )
    return checksum


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--publish", action="store_true")
    parser.add_argument("--replace-tag-object")
    args = parser.parse_args()
    if args.replace_tag_object is not None and not args.publish:
        parser.error("--replace-tag-object requires --publish")
    if args.publish:
        checksum = publish(
            args.directory, args.version, args.commit, args.replace_tag_object
        )
    else:
        _, checksum = validate(args.directory, args.version, args.commit)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write("manifest-sha256=" + checksum + "\n")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write(
                f"SwiftPods `{args.version}`\n\n"
                f"`SWIFTPODS_VERSION`: `{args.version}`\n\n"
                f"`SWIFTPODS_MANIFEST_SHA256`: `{checksum}`\n"
            )
    print("release.json SHA-256:", checksum)


if __name__ == "__main__":
    main()
