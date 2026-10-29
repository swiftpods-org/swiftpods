#!/usr/bin/env python3
"""Build and stage an unsigned SwiftPods/ directory; never publishes or installs it."""

import argparse
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from scripts.support.processes import run_checked, termination_signals
from scripts.support.version import ROOT, source_version


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
    run_checked(
        build_command + ["-Xswiftc", "-warnings-as-errors"],
        cwd=ROOT,
        env=build_environment,
    )
    destination.parent.mkdir(parents=True, exist_ok=True)
    binary_directory = Path(
        run_checked(
            build_command + ["--show-bin-path"],
            cwd=ROOT,
            env=build_environment,
            stdout=subprocess.PIPE,
            text=True,
        ).stdout.strip()
    )
    with tempfile.TemporaryDirectory(
        prefix=".swiftpods-package-", dir=destination.parent
    ) as staging_directory:
        staging = Path(staging_directory) / "SwiftPods"
        (staging / "bin").mkdir(parents=True)
        shutil.copy2(binary_directory / "swiftpods", staging / "bin/swiftpods")
        shutil.copy2(ROOT / "LICENSE", staging / "LICENSE")
        shutil.copy2(ROOT / "README.md", staging / "README.md")
        actual = json.loads(
            run_checked(
                [staging / "bin/swiftpods", "version", "--json"],
                env=build_environment,
                stdout=subprocess.PIPE,
            ).stdout
        )
        if actual["version"] != source_version(ROOT):
            raise RuntimeError("Compiled CLI version differs from its source version")
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
