#!/usr/bin/env python3
"""Assemble an unsigned development bundle; never publishes or installs it."""

import argparse
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

from bootstrap import PREFIX, PROFILE, ROOT, environment, manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, default=ROOT / "dist/SwiftPods")
    args = parser.parse_args()
    destination = args.destination.resolve()
    if destination.exists():
        raise RuntimeError(
            "Destination exists; choose a new destination: " + str(destination)
        )
    subprocess.run(
        [
            "swift",
            "build",
            "-c",
            "release",
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
        check=True,
    )
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(
        tempfile.mkdtemp(prefix=".swiftpods-package-", dir=destination.parent)
    )
    try:
        if (PREFIX / "runtime").exists():
            raise RuntimeError(
                "Bootstrap with external Ruby first; embedded runtimes cannot be packaged"
            )
        for path in PREFIX.iterdir():
            if path.name == "compatibility.json":
                continue
            if path.is_dir():
                shutil.copytree(
                    path,
                    staging / path.name,
                    symlinks=True,
                    ignore=shutil.ignore_patterns("*.dSYM"),
                )
            else:
                shutil.copy2(path, staging / path.name)
        (staging / "bin").mkdir()
        shutil.copy2(ROOT / ".build/release/swiftpods", staging / "bin/swiftpods")
        shutil.copy2(ROOT / "README.md", staging / "README.md")
        shutil.copytree(ROOT / "docs", staging / "docs")
        shutil.copy2(
            ROOT / "Sources/ProcessSupport/ArchiveHeaders/LICENSE.txt",
            staging / "licenses/libarchive-public-headers.txt",
        )
        manifest(staging)
        env = environment(staging)
        env["SWIFTPODS_BUNDLE"] = str(staging)
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
    except BaseException:
        shutil.rmtree(staging)
        raise
    print(destination / "bin/swiftpods")


if __name__ == "__main__":
    main()
