"""Invalidate previous evidence before a run and record failure as well as success."""

import datetime
import hashlib
import json
import platform
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def source_revision():
    return {
        "commit": subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
        ).strip(),
        "dirty": bool(
            subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT)
        ),
    }


def source_digest():
    files = {}
    for name in [
        "Sources",
        "Runtime",
        "Tests",
        "scripts",
        "Profiles",
        ".github",
        "action.yml",
        "Package.swift",
        "Gemfile",
        "Gemfile.lock",
        "README.md",
        "docs",
    ]:
        root = ROOT / name
        paths = [root] if root.is_file() else sorted(root.rglob("*"))
        for path in paths:
            if path.is_file() and "__pycache__" not in path.parts:
                files[path.relative_to(ROOT).as_posix()] = hashlib.sha256(
                    path.read_bytes()
                ).hexdigest()
    return hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()


def contract_digest():
    files = [
        ROOT / "Profiles/contract.json",
        ROOT / "Runtime/attributes.json",
        ROOT / "docs/SwiftPods-Specification-v0.1.md",
    ]
    return hashlib.sha256(
        json.dumps(
            {
                str(path.relative_to(ROOT)): hashlib.sha256(
                    path.read_bytes()
                ).hexdigest()
                for path in files
                if path.is_file()
            },
            sort_keys=True,
        ).encode()
    ).hexdigest()


def binary_identity():
    path = ROOT / ".build/debug/swiftpods"
    if "--bundle" in sys.argv:
        path = (
            Path(sys.argv[sys.argv.index("--bundle") + 1]).resolve() / "bin/swiftpods"
        )
    elif Path(sys.argv[0]).name == "native_distribution_tests.py" and len(sys.argv) > 1:
        path = Path(sys.argv[1]).resolve() / "bin/swiftpods"
    return (
        {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
        if path.is_file()
        else None
    )


def toolchain_identity():
    from ruby_runtime import select_ruby

    _, ruby = select_ruby(json.loads((ROOT / "Profiles/baseline.json").read_text()))
    ruby["sha256"] = hashlib.sha256(Path(ruby["path"]).read_bytes()).hexdigest()
    if ruby["library"]:
        ruby["library_sha256"] = hashlib.sha256(
            Path(ruby["library"]).read_bytes()
        ).hexdigest()
    result = {
        name: subprocess.check_output(
            command, cwd=ROOT, text=True, stderr=subprocess.STDOUT
        ).strip()
        for name, command in [
            ("xcode", ["xcodebuild", "-version"]),
            ("swift", ["swift", "--version"]),
        ]
    }
    result["external_ruby"] = ruby
    result["python"] = {
        "version": platform.python_version(),
        "path": str(Path(sys.executable).resolve()),
    }
    return result


def verify_snapshot(metadata, allow_build=False):
    if (
        source_digest() != metadata["source_digest"]
        or source_revision() != metadata["source_revision"]
    ):
        raise RuntimeError(
            "Sources or revision changed during verification; rerun against a fixed source snapshot"
        )
    if toolchain_identity() != metadata["toolchain"]:
        raise RuntimeError("Toolchain changed during verification")
    if not allow_build and binary_identity() != metadata["executable"]:
        raise RuntimeError("Executable changed during verification")


def snapshot_metadata():
    """Capture the inputs whose identity must remain fixed during a check."""
    return {
        "source_digest": source_digest(),
        "contract_digest": contract_digest(),
        "source_revision": source_revision(),
        "host": {"os": platform.mac_ver()[0], "architecture": platform.machine()},
        "toolchain": toolchain_identity(),
        "executable": binary_identity(),
    }


def write_report(path, value):
    """Publish complete JSON atomically, without sharing a temporary filename."""
    with tempfile.NamedTemporaryFile(
        mode="w", prefix="." + path.name + "-", dir=path.parent, delete=False
    ) as temporary:
        pending = Path(temporary.name)
        try:
            temporary.write(json.dumps(value, indent=2) + "\n")
        except BaseException:
            pending.unlink(missing_ok=True)
            raise
    try:
        pending.replace(path)
    finally:
        pending.unlink(missing_ok=True)


def execute(main, name):
    path = ROOT / "test-results" / name
    path.parent.mkdir(exist_ok=True)
    started = time.monotonic()
    metadata = {
        "schema_version": 1,
        "status": "running",
        "command": sys.argv,
        "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }

    # Invalidate old evidence before probing Ruby, Xcode, the binary, or sources.
    # A failure in any of those probes must not leave a previous pass behind.
    write_report(path, metadata)
    try:
        metadata.update(snapshot_metadata())
        write_report(path, metadata)
        main()
        verify_snapshot(
            metadata, allow_build=name in ("native-units.json", "check.json")
        )
        result = json.loads(path.read_text())
        if result.get("status") in (None, "running"):
            result["status"] = "passed"
        result.update(
            {key: value for key, value in metadata.items() if key != "status"}
        )
        result["duration_seconds"] = time.monotonic() - started
        result["executable"] = binary_identity()
        write_report(path, result)
    except SystemExit as error:
        metadata.update(
            status="skipped" if error.code in (None, 0) else "failed",
            error="Exited before test evidence was completed: " + str(error.code),
            duration_seconds=time.monotonic() - started,
        )
        write_report(path, metadata)
        raise
    except BaseException as error:
        try:
            current = json.loads(path.read_text())
            if not isinstance(current, dict):
                current = {}
        except (OSError, ValueError):
            current = {}
        current.update(metadata)
        current.update(
            status="failed",
            error=str(error) or type(error).__name__,
            duration_seconds=time.monotonic() - started,
        )
        write_report(path, current)
        raise
