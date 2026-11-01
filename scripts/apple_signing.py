#!/usr/bin/env python3
"""Inspect the exact Apple signing certificate attached to one executable."""

import hashlib
import os
import re
import stat
import subprocess
import tempfile
from pathlib import Path


TEAM_ID = re.compile(r"[A-Z0-9]{10}")
CERTIFICATE_SHA1 = re.compile(r"[0-9A-F]{40}")
CERTIFICATE_SHA256 = re.compile(r"[0-9a-f]{64}")


def apple_tool_environment():
    """Return the complete allowlist for credential-bearing Apple tools."""
    environment = {
        name: os.environ[name]
        for name in ("HOME", "TMPDIR")
        if os.environ.get(name)
    }
    environment.update(
        {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"}
    )
    return environment


def inspection_environment():
    return apple_tool_environment()


def trusted_xcode_tool(name):
    """Resolve one selected-Xcode tool without honoring ambient toolchain overrides."""
    if re.fullmatch(r"[A-Za-z0-9_-]+", name) is None:
        raise RuntimeError("Invalid Xcode tool name")
    environment = apple_tool_environment()
    selected_text = subprocess.check_output(
        ["/usr/bin/xcode-select", "-p"],
        text=True,
        env=environment,
        stdin=subprocess.DEVNULL,
    ).strip()
    candidate_text = subprocess.check_output(
        ["/usr/bin/xcrun", "--find", name],
        text=True,
        env=environment,
        stdin=subprocess.DEVNULL,
    ).strip()
    selected_input = Path(selected_text)
    candidate_input = Path(candidate_text)
    if not selected_input.is_absolute() or not candidate_input.is_absolute():
        raise RuntimeError("Xcode tool paths must be absolute")
    selected = selected_input.resolve(strict=True)
    candidate = candidate_input.resolve(strict=True)
    if selected != selected_input or candidate != candidate_input:
        raise RuntimeError("Selected Xcode and its tools must not use symbolic links")
    if candidate != selected / "usr/bin" / name:
        raise RuntimeError("xcrun resolved a tool outside the selected Xcode")

    bundle = next(
        (
            parent
            for parent in [candidate, *candidate.parents]
            if parent.name.startswith("Xcode") and parent.name.endswith(".app")
        ),
        None,
    )
    if bundle is None or bundle.parent != Path("/Applications"):
        raise RuntimeError("Selected Xcode must be installed directly in /Applications")
    relative = candidate.relative_to(bundle)
    current = bundle
    paths = [bundle]
    for component in relative.parts:
        current /= component
        paths.append(current)
    for path in paths:
        status = path.lstat()
        if stat.S_ISLNK(status.st_mode) or status.st_uid != 0 or status.st_mode & 0o022:
            raise RuntimeError("Selected Xcode is not a root-owned, non-writable installation")
    status = candidate.stat()
    if not stat.S_ISREG(status.st_mode) or status.st_mode & 0o111 == 0:
        raise RuntimeError("Selected Xcode tool is not an executable regular file")
    return str(candidate)


def inspect_signature(executable):
    """Return exact Developer ID publisher evidence, or None for an unsigned binary."""
    executable = Path(executable)
    verification = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--strict", executable],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=60,
        env=inspection_environment(),
        stdin=subprocess.DEVNULL,
    )
    if verification.returncode:
        return None
    with tempfile.TemporaryDirectory(prefix="swiftpods-signature-") as temporary:
        prefix = Path(temporary) / "certificate"
        display = subprocess.run(
            [
                "/usr/bin/codesign",
                "--display",
                "--verbose=4",
                "--extract-certificates",
                prefix,
                executable,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=60,
            env=inspection_environment(),
            stdin=subprocess.DEVNULL,
        )
        if display.returncode:
            raise RuntimeError("Cannot inspect the release code signature")
        authorities = re.findall(r"^Authority=(.+)$", display.stderr, re.M)
        team = re.search(r"^TeamIdentifier=([A-Z0-9]+)$", display.stderr, re.M)
        certificate = Path(str(prefix) + "0")
        if (
            not authorities
            or not authorities[0].startswith("Developer ID Application: ")
            or team is None
            or TEAM_ID.fullmatch(team.group(1)) is None
            or certificate.is_symlink()
            or not certificate.is_file()
            or certificate.stat().st_size > 64 * 1024
        ):
            raise RuntimeError(
                "Release signature has invalid Developer ID publisher evidence"
            )
        encoded = certificate.read_bytes()
        if not encoded:
            raise RuntimeError("Release signature has no leaf certificate")
        return {
            "authority": authorities[0],
            "team_id": team.group(1),
            "certificate_sha1": hashlib.sha1(encoded).hexdigest().upper(),
            "certificate_sha256": hashlib.sha256(encoded).hexdigest(),
        }


def validate_publisher(publisher):
    return (
        isinstance(publisher, dict)
        and set(publisher) == {
            "authority",
            "team_id",
            "certificate_sha1",
            "certificate_sha256",
        }
        and isinstance(publisher["authority"], str)
        and publisher["authority"].startswith("Developer ID Application: ")
        and isinstance(publisher["team_id"], str)
        and TEAM_ID.fullmatch(publisher["team_id"]) is not None
        and isinstance(publisher["certificate_sha1"], str)
        and CERTIFICATE_SHA1.fullmatch(publisher["certificate_sha1"]) is not None
        and isinstance(publisher["certificate_sha256"], str)
        and CERTIFICATE_SHA256.fullmatch(publisher["certificate_sha256"]) is not None
    )
