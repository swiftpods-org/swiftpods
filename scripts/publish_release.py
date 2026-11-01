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

from scripts.apple_signing import validate_publisher

REPOSITORY = "swiftpods-org/swiftpods"


def validate(directory, version, commit, tag_object):
    if directory.is_symlink() or not directory.is_dir():
        raise RuntimeError("Release assets must be a real directory")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?", version):
        raise RuntimeError("Invalid release version")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise RuntimeError("Release requires an exact source commit")
    if re.fullmatch(r"[0-9a-f]{40}(?:[0-9a-f]{24})?", tag_object or "") is None:
        raise RuntimeError("Release requires an exact annotated tag object")
    manifest = json.loads((directory / "release.json").read_text())
    if (
        manifest.get("schema_version") != 3
        or manifest.get("version") != version
        or manifest.get("development") is not False
        or manifest.get("publishable") is not True
        or manifest.get("source_revision")
        != {"commit": commit, "tag_object": tag_object}
        or not validate_publisher(manifest.get("publisher"))
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
            or not re.fullmatch(r"[0-9a-f]{64}", asset.get("content_sha256", ""))
            or asset.get("notarization", {}).get("status") != "Accepted"
        ):
            raise RuntimeError("Invalid or unnotarized release asset")
        expected[name] = asset["sha256"]
    manifest_sha256 = hashlib.sha256(
        (directory / "release.json").read_bytes()
    ).hexdigest()
    expected["release.json"] = manifest_sha256
    checksum_path = directory / "SHA256SUMS"
    if checksum_path.is_symlink() or not checksum_path.is_file():
        raise RuntimeError("Release checksum list must be a regular file")
    checksums = checksum_path.read_text().splitlines()
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
    paths.append(checksum_path)
    expected_names = {path.name for path in paths}
    entries = list(directory.iterdir())
    if (
        {path.name for path in entries} != expected_names
        or any(path.is_symlink() or not path.is_file() for path in entries)
    ):
        raise RuntimeError("Release directory contains an unexpected public asset")
    return paths, manifest_sha256


def existing_release(tag):
    try:
        return json.loads(subprocess.check_output(
            ["gh", "api", f"repos/{REPOSITORY}/releases/tags/{tag}"],
            text=True, stderr=subprocess.PIPE,
        ))
    except subprocess.CalledProcessError as error:
        # Missing is the only state in which a version may be published.
        # Authentication and transport failures stop publication before changes.
        if re.search(r"\bHTTP 404\b", error.stderr or ""):
            return None
        raise


def github_json(path):
    return json.loads(
        subprocess.check_output(
            ["gh", "api", f"repos/{REPOSITORY}/{path}"],
            text=True,
        )
    )


def validate_remote_source_tag(tag, expected_object, commit):
    """Bind the remote ref to one exact annotated tag object and commit."""
    if re.fullmatch(r"[0-9a-f]{40}(?:[0-9a-f]{24})?", expected_object) is None:
        raise RuntimeError("Release requires an exact annotated tag object")
    reference = github_json("git/ref/tags/" + tag)
    target = reference.get("object") if isinstance(reference, dict) else None
    if (
        not isinstance(reference, dict)
        or reference.get("ref") != "refs/tags/" + tag
        or not isinstance(target, dict)
        or target.get("type") != "tag"
        or target.get("sha") != expected_object
    ):
        raise RuntimeError("Remote release tag object changed or is not annotated")
    annotated = github_json("git/tags/" + expected_object)
    peeled = annotated.get("object") if isinstance(annotated, dict) else None
    if (
        not isinstance(annotated, dict)
        or annotated.get("sha") != expected_object
        or annotated.get("tag") != tag
        or not isinstance(peeled, dict)
        or peeled.get("type") != "commit"
        or peeled.get("sha") != commit
    ):
        raise RuntimeError("Annotated release tag does not peel to the tested commit")


def release_notes(version, checksum, publisher, tag_object):
    tag = "v" + version
    return (
        "Signed and notarized macOS builds for Apple Silicon and Intel.\n\n"
        "Download the installer and archives below. See "
        "[installation and CI](https://github.com/"
        + REPOSITORY
        + "/blob/"
        + tag
        + "/docs/Release.md) for setup.\n\n"
        "`release.json` SHA-256: `" + checksum + "`\n"
        "\nSource annotated tag object: `" + tag_object + "`\n"
        "\nPublisher Team ID: `" + publisher["team_id"] + "`\n"
        "\nPublisher certificate SHA-256: `"
        + publisher["certificate_sha256"]
        + "`\n"
    )


def recorded_release_notes_checksum(body, version, publisher, tag_object):
    """Return the prior manifest checksum only for exact canonical release notes."""
    placeholder = "M" * 64
    template = release_notes(version, placeholder, publisher, tag_object)
    prefix, suffix = template.split(placeholder)
    if not isinstance(body, str):
        return None
    match = re.fullmatch(
        re.escape(prefix) + r"([0-9a-f]{64})" + re.escape(suffix), body
    )
    return match.group(1) if match is not None else None


def validate_release_record(
    published, version, commit, tag_object, paths, checksum, *, draft
):
    """Validate GitHub metadata for one exact local payload."""
    tag = "v" + version
    manifest = json.loads(next(path for path in paths if path.name == "release.json").read_text())
    if (
        not isinstance(published, dict)
        or published.get("tag_name") != tag
        or published.get("draft") is not draft
        or published.get("prerelease") is not ("-" in version)
        or published.get("name") != "SwiftPods " + version
        or published.get("body")
        != release_notes(version, checksum, manifest["publisher"], tag_object)
    ):
        raise RuntimeError("GitHub release metadata does not match the exact source payload")
    if not draft and published.get("immutable") is not True:
        raise RuntimeError(
            "Published GitHub release is mutable; enable repository immutable releases before publishing"
        )
    validate_remote_source_tag(tag, tag_object, commit)

    assets = published.get("assets")
    if not isinstance(assets, list):
        raise RuntimeError("GitHub release has invalid asset metadata")
    names = [asset.get("name") for asset in assets]
    expected_names = {path.name for path in paths}
    if len(names) != len(set(names)) or set(names) != expected_names:
        raise RuntimeError("GitHub release asset set differs from the verified payload")
    local_sizes = {path.name: path.stat().st_size for path in paths}
    if any(
        not isinstance(asset.get("size"), int)
        or asset["size"] != local_sizes[asset["name"]]
        for asset in assets
    ):
        raise RuntimeError("GitHub release asset sizes differ from the verified payload")


def validate_reconcilable_draft(
    published, version, commit, tag_object, expected_names, publisher
):
    """Reject a foreign or ambiguous draft before changing it."""
    tag = "v" + version
    recorded_checksum = (
        recorded_release_notes_checksum(
            published.get("body"), version, publisher, tag_object
        )
        if isinstance(published, dict)
        else None
    )
    if (
        not isinstance(published, dict)
        or published.get("tag_name") != tag
        or published.get("draft") is not True
        or published.get("prerelease") is not ("-" in version)
        or published.get("name") != "SwiftPods " + version
        or recorded_checksum is None
    ):
        raise RuntimeError(
            "Existing draft metadata does not match the exact source tag object"
        )
    validate_remote_source_tag(tag, tag_object, commit)
    assets = published.get("assets")
    if not isinstance(assets, list):
        raise RuntimeError("Existing draft has invalid asset metadata")
    names = [asset.get("name") for asset in assets]
    if len(names) != len(set(names)) or not set(names).issubset(expected_names):
        raise RuntimeError("Existing draft contains unexpected release assets")


def verify_downloaded_payload(
    tag, version, commit, tag_object, expected_paths, checksum
):
    """Download every remote asset and compare its bytes with the local payload."""
    with tempfile.TemporaryDirectory(prefix="swiftpods-remote-release-") as temporary:
        remote = Path(temporary)
        subprocess.run(
            [
                "gh",
                "release",
                "download",
                tag,
                "--repo",
                REPOSITORY,
                "--dir",
                str(remote),
            ],
            check=True,
        )
        remote_paths, remote_checksum = validate(remote, version, commit, tag_object)
        if remote_checksum != checksum:
            raise RuntimeError("Remote release manifest differs from the local payload")
        expected = {path.name: hashlib.sha256(path.read_bytes()).digest() for path in expected_paths}
        actual = {path.name: hashlib.sha256(path.read_bytes()).digest() for path in remote_paths}
        if actual != expected:
            raise RuntimeError("Remote release assets differ from the local payload")


def verify_published(directory, version, commit, tag_object):
    """Bind downloaded assets to one immutable public release and source tag."""
    paths, checksum = validate(directory, version, commit, tag_object)
    tag = "v" + version
    published = existing_release(tag)
    if published is None:
        raise RuntimeError(tag + " is not published")
    validate_release_record(
        published, version, commit, tag_object, paths, checksum, draft=False
    )
    verify_downloaded_payload(tag, version, commit, tag_object, paths, checksum)
    return checksum


def publish(directory, version, commit, tag_object):
    paths, checksum = validate(directory, version, commit, tag_object)
    publisher = json.loads((directory / "release.json").read_text())["publisher"]
    tag = "v" + version
    expected_names = {path.name for path in paths}
    release = existing_release(tag)
    if release is not None and release.get("draft") is False:
        # A concurrent or retried exact publication is already complete. Never
        # replace it; accept it only after comparing the remote bytes.
        validate_release_record(
            release, version, commit, tag_object, paths, checksum, draft=False
        )
        verify_downloaded_payload(
            tag, version, commit, tag_object, paths, checksum
        )
        return checksum
    if release is not None:
        validate_reconcilable_draft(
            release,
            version,
            commit,
            tag_object,
            expected_names,
            publisher,
        )
    else:
        validate_remote_source_tag(tag, tag_object, commit)

    with tempfile.TemporaryDirectory(prefix="swiftpods-release-notes-") as temporary:
        notes = Path(temporary) / "notes.md"
        notes.write_text(release_notes(version, checksum, publisher, tag_object))
        state_options = (
            ["--prerelease", "--latest=false"]
            if "-" in version
            else ["--prerelease=false", "--latest=false"]
        )
        if release is None:
            # Create metadata only. A failed upload leaves a deterministic hidden
            # draft that the next run can safely reconcile.
            subprocess.run(
                [
                    "gh",
                    "release",
                    "create",
                    tag,
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
                    *state_options,
                ],
                check=True,
            )
        # Metadata and every allowed asset are overwritten from the freshly
        # validated local payload. Unexpected draft assets are never deleted or
        # silently adopted.
        subprocess.run(
            [
                "gh",
                "release",
                "edit",
                tag,
                "--repo",
                REPOSITORY,
                "--title",
                "SwiftPods " + version,
                "--notes-file",
                str(notes),
                "--draft=true",
                *state_options,
            ],
            check=True,
        )
        current = existing_release(tag)
        if current is None:
            raise RuntimeError("Draft disappeared before its assets were uploaded")
        validate_reconcilable_draft(
            current,
            version,
            commit,
            tag_object,
            expected_names,
            publisher,
        )
        subprocess.run(
            [
                "gh",
                "release",
                "upload",
                tag,
                *map(str, paths),
                "--repo",
                REPOSITORY,
                "--clobber",
            ],
            check=True,
        )
        current = existing_release(tag)
        if current is None:
            raise RuntimeError("Draft disappeared after its assets were uploaded")
        validate_release_record(
            current, version, commit, tag_object, paths, checksum, draft=True
        )
        verify_downloaded_payload(
            tag, version, commit, tag_object, paths, checksum
        )
        validate_remote_source_tag(tag, tag_object, commit)
        final_options = (
            ["--prerelease", "--latest=false"] if "-" in version else ["--prerelease=false", "--latest"]
        )
        subprocess.run(
            [
                "gh",
                "release",
                "edit",
                tag,
                "--repo",
                REPOSITORY,
                "--title",
                "SwiftPods " + version,
                "--notes-file",
                str(notes),
                "--draft=false",
                *final_options,
            ],
            check=True,
        )
    published = existing_release(tag)
    if published is None:
        raise RuntimeError("Published release disappeared during final verification")
    validate_release_record(
        published, version, commit, tag_object, paths, checksum, draft=False
    )
    # The public state is a distinct trust boundary from the hidden draft. Verify
    # every byte again only after GitHub reports the release as immutable.
    verify_downloaded_payload(tag, version, commit, tag_object, paths, checksum)
    return checksum


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--tag-object", required=True)
    parser.add_argument("--publish", action="store_true")
    parser.add_argument("--verify-published", action="store_true")
    parser.add_argument("--expected-manifest-sha256")
    args = parser.parse_args()
    if args.publish and args.verify_published:
        parser.error("--publish and --verify-published are mutually exclusive")
    if args.publish:
        checksum = publish(args.directory, args.version, args.commit, args.tag_object)
    elif args.verify_published:
        checksum = verify_published(
            args.directory, args.version, args.commit, args.tag_object
        )
    else:
        _, checksum = validate(
            args.directory, args.version, args.commit, args.tag_object
        )
    if args.expected_manifest_sha256 is not None:
        if (
            re.fullmatch(r"[0-9a-f]{64}", args.expected_manifest_sha256) is None
            or checksum != args.expected_manifest_sha256
        ):
            raise RuntimeError("Release manifest differs from the previously verified publication")
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
