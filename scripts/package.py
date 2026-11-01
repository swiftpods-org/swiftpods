#!/usr/bin/env python3
"""Build and stage an unsigned SwiftPods/ directory; never publishes or installs it."""

import argparse
import hashlib
import io
import json
import os
import shutil
import subprocess
import tarfile
import tempfile
import uuid
from pathlib import Path

from scripts.support.processes import run_checked, termination_signals
from scripts.support.version import ROOT, source_version


def isolated_build_environment(temporary):
    """Return the complete environment used by xcrun, Swift and package smoke tests."""
    home = temporary.parent / "home"
    home.mkdir(exist_ok=True)
    return {
        "HOME": str(home),
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "TMPDIR": str(temporary),
    }


def swift_executable(environment):
    """Resolve Swift through Apple's absolute xcrun instead of the caller's PATH."""
    result = run_checked(
        ["/usr/bin/xcrun", "--find", "swift"],
        env=environment,
        stdout=subprocess.PIPE,
        text=True,
    ).stdout
    lines = result.splitlines()
    if len(lines) != 1:
        raise RuntimeError("xcrun returned an invalid Swift executable path")
    executable = Path(lines[0])
    if (
        not executable.is_absolute()
        or not executable.is_file()
        or not os.access(executable, os.X_OK)
    ):
        raise RuntimeError("xcrun did not return an executable absolute Swift path")
    return str(executable)


def verify_distribution(binary, environment, temporary):
    actual = json.loads(
        run_checked(
            [binary, "version", "--json"],
            env=environment,
            stdout=subprocess.PIPE,
        ).stdout
    )
    if actual != {"version": source_version(ROOT)}:
        raise RuntimeError("Compiled CLI version differs from its source version")

    help_text = run_checked(
        [binary, "help"],
        env=environment,
        stdout=subprocess.PIPE,
        text=True,
    ).stdout
    if "Usage: swiftpods <command> [options]" not in help_text:
        raise RuntimeError("Compiled CLI did not produce its expected help output")

    # Compressed archives are parsed by a resource-limited hidden mode of this exact executable. Exercise that entry
    # point after copying the single-file distribution so packaging can never accidentally ship only the parent side
    # of the protocol.
    with tempfile.TemporaryDirectory(prefix="swiftpods-worker-smoke-", dir=temporary) as owner:
        archive = Path(owner) / "archive.tar.gz"
        contents = b"worker-smoke"
        information = tarfile.TarInfo("Kit.xcframework/Info.plist")
        information.size = len(contents)
        information.mode = 0o644
        with tarfile.open(archive, mode="w:gz") as output:
            output.addfile(information, io.BytesIO(contents))
        archive_descriptor = os.open(archive, os.O_RDONLY)
        executable_descriptor = os.open(binary, os.O_RDONLY)
        parent_reader, parent_writer = os.pipe()
        nonce = str(uuid.uuid4())
        try:
            worker = json.loads(
                run_checked(
                    [
                        binary,
                        "--swiftpods-internal-archive-worker-v1",
                        "1",
                        "inspect",
                        archive_descriptor,
                        -1,
                        executable_descriptor,
                        parent_reader,
                        nonce,
                    ],
                    env=environment,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    pass_fds=(archive_descriptor, executable_descriptor, parent_reader),
                    timeout=60,
                ).stdout
            )
        finally:
            os.close(parent_writer)
            os.close(parent_reader)
            os.close(executable_descriptor)
            os.close(archive_descriptor)
        inspection = worker.get("inspection", {})
        if (
            worker.get("protocolVersion") != 1
            or worker.get("nonce") != nonce
            or inspection.get("format") != "tar"
            or inspection.get("bytes") != len(contents)
        ):
            raise RuntimeError("Packaged CLI failed its isolated archive-worker smoke test")

        # The direct protocol check above cannot prove that the release parent can rediscover, pin and authenticate its
        # own mapped vnode. Exercise the complete authenticated copy -> inspect worker -> extract worker path too.
        parent = json.loads(
            run_checked(
                [
                    binary,
                    "--swiftpods-internal-archive-parent-probe-v1",
                    "1",
                    archive,
                    hashlib.sha256(archive.read_bytes()).hexdigest(),
                ],
                env=environment,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                timeout=120,
            ).stdout
        )
        if parent != {"protocolVersion": 1, "bytes": len(contents)}:
            raise RuntimeError("Packaged CLI failed its parent-to-worker archive smoke test")

    # Exercise the staged release executable through its CLI, ManifestReader and linked
    # libraries without consulting the network or modifying a real user project.
    with tempfile.TemporaryDirectory(prefix="swiftpods-smoke-", dir=temporary) as owner:
        project = Path(owner) / "Project"
        project.mkdir()
        podfile = project / "Podfile"
        podfile.write_text(
            "platform :ios, '15.0'\n"
            "target 'App' do\n"
            "  spm 'https://example.com/Smoke.git', exact: '1.2.3', products: ['Smoke']\n"
            "end\n"
        )
        manifest = json.loads(
            run_checked(
                [binary, "check", "--offline", "--json", "--project-directory", project],
                env=environment,
                stdout=subprocess.PIPE,
            ).stdout
        )
        if (
            manifest.get("file") != str(podfile)
            or [item.get("name") for item in manifest.get("packages", [])] != ["Smoke"]
            or [item.get("name") for item in manifest.get("targets", [])] != ["App"]
        ):
            raise RuntimeError("Compiled CLI failed its offline Podfile smoke test")


def assemble(destination, scratch):
    if destination.exists():
        raise RuntimeError(
            "Destination exists; choose a new destination: " + str(destination)
        )
    build_temporary = scratch.parent / "temporary"
    build_temporary.mkdir(exist_ok=True)
    build_environment = isolated_build_environment(build_temporary)
    swift = swift_executable(build_environment)
    build_command = [
        swift, "build",
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
        verify_distribution(staging / "bin/swiftpods", build_environment, build_temporary)
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
