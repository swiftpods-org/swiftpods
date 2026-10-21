#!/usr/bin/env python3
"""Assemble an unsigned development bundle; never publishes or installs it."""

import argparse
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from scripts.support.bootstrap import PROFILE, ROOT, environment, manifest
from scripts.support.processes import termination_signals


def assemble(destination, scratch):
    if destination.exists():
        raise RuntimeError(
            "Destination exists; choose a new destination: " + str(destination)
        )
    build_temporary = scratch.parent / "temporary"
    build_temporary.mkdir(exist_ok=True)
    build_environment = dict(os.environ, TMPDIR=str(build_temporary))
    build_command = [
        "swift", "build",
        "--scratch-path", str(scratch),
        "--cache-path", str(scratch.parent / "cache"),
        "--config-path", str(scratch.parent / "configuration"),
        "--security-path", str(scratch.parent / "security"),
        "-c", "release",
    ]
    subprocess.run(
        build_command + [
            "-Xswiftc",
            "-warnings-as-errors",
            "-Xcc",
            "-Wall",
            "-Xcc",
            "-Wextra",
            "-Xcc",
            "-Werror",
        ],
        cwd=ROOT,
        env=build_environment,
        check=True,
    )
    destination.parent.mkdir(parents=True, exist_ok=True)
    binary_directory = Path(
        subprocess.check_output(
            build_command + ["--show-bin-path"],
            cwd=ROOT,
            env=build_environment,
            text=True,
        ).strip()
    )
    with tempfile.TemporaryDirectory(
        prefix=".swiftpods-package-", dir=destination.parent
    ) as staging_directory:
        staging = Path(staging_directory) / "SwiftPods"
        shutil.copytree(ROOT / "Runtime", staging / "host")
        (staging / "licenses").mkdir()
        (staging / "bin").mkdir()
        shutil.copy2(binary_directory / "swiftpods", staging / "bin/swiftpods")
        shutil.copy2(ROOT / "README.md", staging / "README.md")
        shutil.copy2(ROOT / "LICENSE", staging / "LICENSE")
        shutil.copytree(ROOT / "docs", staging / "docs")
        shutil.copy2(
            ROOT / "Sources/ProcessSupport/ArchiveHeaders/LICENSE.txt",
            staging / "licenses/libarchive-public-headers.txt",
        )
        manifest(staging)
        env = environment(staging)
        env["SWIFTPODS_BUNDLE"] = str(staging)
        env["TMPDIR"] = str(build_temporary)
        actual = json.loads(
            subprocess.check_output(
                [str(staging / "bin/swiftpods"), "version", "--json"], env=env
            )
        )
        if actual["swiftpods_version"] != PROFILE["swiftpods_version"]:
            raise RuntimeError(
                "Compiled CLI version differs from the compatibility profile"
            )
        staging.rename(destination)


@termination_signals()
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--destination",
        type=Path,
        help="Export the package to this path; otherwise verify it in a temporary directory",
    )
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="swiftpods-package-") as temporary:
        workspace = Path(temporary)
        subprocess_temporary = workspace / "temporary"
        subprocess_temporary.mkdir()
        previous_temporary = os.environ.get("TMPDIR")
        destination = (
            args.destination.resolve() if args.destination else workspace / "SwiftPods"
        )
        try:
            os.environ["TMPDIR"] = str(subprocess_temporary)
            assemble(destination, workspace / "build")
        finally:
            if previous_temporary is None:
                os.environ.pop("TMPDIR", None)
            else:
                os.environ["TMPDIR"] = previous_temporary
    if args.destination:
        print(destination / "bin/swiftpods")
    else:
        print("Package verified; temporary build files removed")


if __name__ == "__main__":
    main()
