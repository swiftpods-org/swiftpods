#!/usr/bin/env python3
"""Smoke-test one signed release bundle in an isolated process environment."""

import argparse
import os
import stat
import tempfile
from pathlib import Path

from scripts.apple_signing import inspect_signature
from scripts.package import isolated_build_environment, verify_distribution


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    args = parser.parse_args()

    bundle = args.bundle.resolve(strict=True)
    executable = bundle / "bin/swiftpods"
    try:
        metadata = executable.lstat()
    except FileNotFoundError as error:
        raise RuntimeError("Signed release has no SwiftPods executable") from error
    if not stat.S_ISREG(metadata.st_mode) or not os.access(executable, os.X_OK):
        raise RuntimeError("Signed release executable must be an executable regular file")
    if inspect_signature(executable) is None:
        raise RuntimeError("Signed release failed strict code-signature verification")

    # The workflow job that invokes this command has no signing/notary secrets. The
    # candidate itself receives only this complete allowlisted environment.
    with tempfile.TemporaryDirectory(prefix="swiftpods-signed-smoke-") as owner:
        temporary = Path(owner) / "temporary"
        temporary.mkdir()
        environment = isolated_build_environment(temporary)
        verify_distribution(executable, environment, temporary)
    print("Signed release smoke test passed: " + str(executable))


if __name__ == "__main__":
    main()
