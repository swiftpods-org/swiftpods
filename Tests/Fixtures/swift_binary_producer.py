#!/usr/bin/env python3
"""Produce a checksummed Swift framework for independent compiler acceptance."""

import argparse
import hashlib
import json
import platform
import plistlib
import re
import subprocess
from pathlib import Path

from scripts.support.reporting import contract_digest, source_digest, source_revision
from Tests.Fixtures.vendor_fixture import run

NAME = "SwiftBinaryKit"


def compiler_identity(version):
    match = re.search(r"(?:Apple )?Swift version [^\n]+", version)
    if not match:
        raise RuntimeError("Missing Swift compiler identity")
    return re.sub(r" effective-[^ ]+", "", match.group())


def inventory(framework):
    files = {}
    for path in sorted(framework.rglob("*")):
        if path.is_symlink():
            if not path.resolve().is_relative_to(framework.resolve()):
                raise RuntimeError("Framework symlink escapes artifact")
            files[path.relative_to(framework).as_posix()] = {
                "symlink": path.readlink().as_posix()
            }
        elif path.is_file():
            files[path.relative_to(framework).as_posix()] = {
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest()
            }
    return files


def produce(destination):
    destination.mkdir(parents=True, exist_ok=False)
    framework = destination / (NAME + ".framework")
    version = framework / "Versions/A"
    modules = version / "Modules" / (NAME + ".swiftmodule")
    modules.mkdir(parents=True)
    (version / "Resources").mkdir()
    (framework / "Versions/Current").symlink_to("A")
    for entry in ["Modules", "Resources", NAME]:
        (framework / entry).symlink_to("Versions/Current/" + entry)
    source = destination / "SDK.swift"
    source.write_text("public func swiftBinaryValue() -> Int32 { return 29 }\n")
    architecture = platform.machine()
    sdk = subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
    ).strip()
    toolchain = subprocess.check_output(
        ["xcrun", "swiftc", "--version"], text=True
    ).strip()
    interface = modules / (architecture + "-apple-macos.swiftinterface")
    run(
        [
            "xcrun",
            "swiftc",
            "-emit-library",
            "-emit-module",
            "-enable-library-evolution",
            "-warnings-as-errors",
            "-swift-version",
            "5",
            "-module-name",
            NAME,
            "-target",
            architecture + "-apple-macosx13.0",
            "-sdk",
            sdk,
            "-emit-module-path",
            modules / (architecture + "-apple-macos.swiftmodule"),
            "-emit-module-interface-path",
            interface,
            "-Xlinker",
            "-install_name",
            "-Xlinker",
            "@rpath/" + NAME + ".framework/Versions/A/" + NAME,
            source,
            "-o",
            version / NAME,
        ],
        destination,
        destination / "producer.log",
    )
    (version / "Resources/Info.plist").write_bytes(
        plistlib.dumps(
            {
                "CFBundleExecutable": NAME,
                "CFBundleIdentifier": "org.swiftpods.binary-fixture",
                "CFBundleName": NAME,
                "CFBundlePackageType": "FMWK",
                "CFBundleVersion": "1",
                "CFBundleShortVersionString": "1.0",
                "CFBundleSupportedPlatforms": ["MacOSX"],
                "LSMinimumSystemVersion": "13.0",
            }
        )
    )
    for file in framework.rglob("*"):
        if file.is_file() and (
            file.suffix == ".swiftmodule"
            or file.name.endswith(".private.swiftinterface")
        ):
            file.unlink()
    compiler = re.search(
        r"^// swift-compiler-version: (.+)$", interface.read_text(), re.MULTILINE
    ).group(1)
    metadata = {
        "schema_version": 1,
        "architecture": architecture,
        "toolchain": toolchain,
        "compiler_version": compiler,
        "source_revision": source_revision(),
        "source_digest": source_digest(),
        "contract_digest": contract_digest(),
        "files": inventory(framework),
    }
    (destination / "producer.json").write_text(json.dumps(metadata, indent=2) + "\n")
    return framework, metadata


def validate(framework, manifest):
    metadata = json.loads(manifest.read_text())
    if (
        metadata.get("schema_version") != 1
        or metadata.get("architecture") != platform.machine()
    ):
        raise RuntimeError("Swift producer architecture/schema differs from consumer")
    if (
        metadata.get("source_digest") != source_digest()
        or metadata.get("contract_digest") != contract_digest()
        or metadata.get("source_revision") != source_revision()
    ):
        raise RuntimeError(
            "Swift producer belongs to another source or contract snapshot"
        )
    if not metadata.get("files") or metadata["files"] != inventory(framework):
        raise RuntimeError("Swift producer framework inventory/checksum changed")
    interfaces = list(framework.rglob("*.swiftinterface"))
    if (
        not interfaces
        or any(file.is_file() for file in framework.rglob("*.swiftmodule"))
        or any(framework.rglob("*.private.swiftinterface"))
    ):
        raise RuntimeError(
            "Swift producer must expose public text interfaces without serialized/private modules"
        )
    for interface in interfaces:
        match = re.search(
            r"^// swift-compiler-version: (.+)$", interface.read_text(), re.MULTILINE
        )
        if (
            not match
            or match.group(1) != metadata.get("compiler_version")
            or compiler_identity(match.group(1))
            != compiler_identity(metadata.get("toolchain", ""))
        ):
            raise RuntimeError(
                "Swift interface compiler identity differs from producer evidence"
            )
    architectures = subprocess.check_output(
        ["xcrun", "lipo", "-archs", str(framework / NAME)], text=True
    ).split()
    if architectures != [metadata["architecture"]]:
        raise RuntimeError("Swift producer Mach-O architecture differs from manifest")
    return metadata


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    framework, metadata = produce(args.destination.resolve())
    validate(framework, framework.parent / "producer.json")
    print(json.dumps({"framework": str(framework), "toolchain": metadata["toolchain"]}))
