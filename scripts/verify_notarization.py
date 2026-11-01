#!/usr/bin/env python3
"""Verify one exact archive against Apple's independent notarization records."""

import argparse
import hashlib
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

from scripts.apple_signing import apple_tool_environment, trusted_xcode_tool


SUBMISSION_ID = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
)
KEY_ID = re.compile(r"[A-Z0-9]{10}")
ISSUER_ID = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
)


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            value.update(chunk)
    return value.hexdigest()


def read_receipt(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 1024 * 1024:
        raise RuntimeError("Notarization receipt must be a bounded regular file")
    receipt = json.loads(path.read_text())
    if not isinstance(receipt, dict):
        raise RuntimeError("Notarization receipt must contain a JSON object")
    return receipt


def query_notarytool(tool, command, submission_id, credentials):
    return json.loads(
        subprocess.check_output(
            [tool, command, submission_id, *credentials, "--output-format", "json"],
            text=True,
            env=apple_tool_environment(),
            stdin=subprocess.DEVNULL,
        )
    )


def verify(archive, receipt_path, credentials):
    archive = Path(archive)
    receipt_path = Path(receipt_path)
    if archive.is_symlink() or not archive.is_file():
        raise RuntimeError("Notarized archive must be a regular file")
    archive_digest = digest(archive)
    receipt = read_receipt(receipt_path)
    submission_id = receipt.get("id")
    if (
        receipt.get("status") != "Accepted"
        or receipt.get("archive_sha256") != archive_digest
        or not isinstance(submission_id, str)
        or SUBMISSION_ID.fullmatch(submission_id) is None
    ):
        raise RuntimeError("Local notarization receipt does not bind the exact archive")

    tool = trusted_xcode_tool("notarytool")
    info = query_notarytool(tool, "info", submission_id, credentials)
    log = query_notarytool(tool, "log", submission_id, credentials)
    if (
        not isinstance(info, dict)
        or str(info.get("id", "")).lower() != submission_id.lower()
        or info.get("status") != "Accepted"
    ):
        raise RuntimeError("Apple does not report the recorded submission as accepted")
    if (
        not isinstance(log, dict)
        or str(log.get("jobId", "")).lower() != submission_id.lower()
        or log.get("status") != "Accepted"
        or str(log.get("sha256", "")).lower() != archive_digest
        or log.get("archiveFilename") != archive.name
    ):
        raise RuntimeError("Apple notarization log does not bind the exact archive bytes")
    return submission_id


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("receipt", type=Path)
    parser.add_argument(
        "--key-environment",
        required=True,
        help="Environment variable containing an independent App Store Connect API private key",
    )
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--issuer", required=True)
    args = parser.parse_args()
    if re.fullmatch(r"[A-Z][A-Z0-9_]{0,127}", args.key_environment) is None:
        parser.error("--key-environment must name one uppercase environment variable")
    if KEY_ID.fullmatch(args.key_id) is None:
        parser.error("--key-id must be exactly 10 uppercase letters or digits")
    if ISSUER_ID.fullmatch(args.issuer) is None:
        parser.error("--issuer must be an App Store Connect issuer UUID")
    key = os.environ.get(args.key_environment, "")
    if (
        not key.startswith("-----BEGIN PRIVATE KEY-----\n")
        or "-----END PRIVATE KEY-----" not in key
        or len(key.encode()) > 64 * 1024
    ):
        raise RuntimeError("Independent notarization verification key is missing or invalid")

    temporary_root = os.environ.get("RUNNER_TEMP")
    with tempfile.TemporaryDirectory(
        prefix="swiftpods-notary-verification-", dir=temporary_root
    ) as temporary:
        key_path = Path(temporary) / "AuthKey.p8"
        key_path.write_text(key)
        key_path.chmod(0o600)
        submission_id = verify(
            args.archive,
            args.receipt,
            ["--key", str(key_path), "--key-id", args.key_id, "--issuer", args.issuer],
        )
    print("Apple independently verified notarization submission " + submission_id)


if __name__ == "__main__":
    main()
