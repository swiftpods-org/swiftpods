"""Invalidate previous evidence before a run and record failure as well as success."""

import datetime
import hashlib
import json
import os
import platform
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from scripts.support.local_build import (
    WORKSPACE_ENV,
    debug_binary,
    prepare_debug,
    results_directory,
    workspace,
    workspace_root,
)

ROOT = Path(__file__).resolve().parents[2]


def failure_excerpt(text):
    """Keep early failures visible when a provider truncates a long test log."""
    lines = text.splitlines()
    pattern = re.compile(
        r"error:|warning:|traceback|\b(?:assertionerror|runtimeerror|fatalerror)\b|Test Case .+ failed",
        re.IGNORECASE,
    )
    selected = set()
    for index, line in enumerate(lines):
        if pattern.search(line):
            selected.update(range(max(0, index - 2), min(len(lines), index + 3)))
    if not selected:
        return ""
    indices = sorted(
        set(sorted(selected)[:100]) | set(range(max(0, len(lines) - 30), len(lines)))
    )
    return "\n".join(lines[index] for index in indices)


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
        "lib",
        "fastlane-plugin-swiftpods.gemspec",
        ".github",
        "action.yml",
        "Package.swift",
        "Gemfile",
        "Gemfile.lock",
        "README.md",
        "LICENSE",
        "docs",
    ]:
        root = ROOT / name
        paths = [root] if root.is_file() else sorted(root.rglob("*"))
        for path in paths:
            if (
                path.is_file()
                and "__pycache__" not in path.parts
                and path.name != ".DS_Store"
            ):
                files[path.relative_to(ROOT).as_posix()] = hashlib.sha256(
                    path.read_bytes()
                ).hexdigest()
    return hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()


def contract_digest():
    files = [
        ROOT / "Profiles/contract.json",
        ROOT / "Runtime/attributes.json",
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


def option_value(name, arguments=None):
    """Read either option spelling without raising before report invalidation.

    None means absent; an empty string means a missing or empty value. Validation
    belongs inside execute(), so malformed arguments cannot leave stale evidence.
    """
    arguments = sys.argv[1:] if arguments is None else arguments
    value = None
    for index, argument in enumerate(arguments):
        if argument == "--":
            break
        if argument.startswith(name + "="):
            value = argument[len(name) + 1 :]
        elif argument == name:
            value = arguments[index + 1] if index + 1 < len(arguments) else ""
            if value.startswith("--"):
                return ""
        else:
            continue
        if not value:
            return ""
    return value


def binary_identity():
    bundle = option_value("--bundle")
    if bundle is not None:
        if not bundle:
            raise RuntimeError("--bundle requires a distribution path")
        path = Path(bundle).resolve() / "bin/swiftpods"
    elif Path(sys.argv[0]).name == "native_distribution_tests.py" and len(sys.argv) > 1:
        path = Path(sys.argv[1]).resolve() / "bin/swiftpods"
    else:
        path = debug_binary()
    return (
        {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
        if path.is_file()
        else None
    )


def toolchain_identity():
    from scripts.support.ruby_runtime import select_ruby

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
    standalone = not os.environ.get(WORKSPACE_ENV)
    with workspace():
        prepare = (
            standalone
            and name not in ("check.json", "native-units.json")
            and option_value("--bundle") is None
            and Path(sys.argv[0]).name != "native_distribution_tests.py"
        )
        try:
            return execute_in_workspace(main, name, prepare=prepare)
        except BaseException:
            if standalone or name == "check.json":
                show_failure_logs()
            raise


def show_failure_logs():
    """Print diagnostic context before temporary reports are removed."""
    directories = [results_directory(), workspace_root() / "fixtures"]
    for directory in directories:
        for path in sorted(directory.rglob("*.log")):
            if not path.is_file() or path.is_symlink():
                continue
            if not path.resolve().is_relative_to(directory.resolve()):
                continue
            excerpt = failure_excerpt(path.read_text(errors="replace"))
            if excerpt:
                print(str(path), file=sys.stderr, flush=True)
                print(excerpt, file=sys.stderr, flush=True)


def execute_in_workspace(main, name, *, prepare=False):
    path = results_directory() / name
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
        if prepare:
            prepare_debug()
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
