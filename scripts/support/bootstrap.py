#!/usr/bin/env python3
"""Prepare SwiftPods' own DSL adapter; no third-party engine or gems are installed."""

import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from scripts.support.local_build import (
    WORKSPACE_ENV,
    results_directory,
    workspace,
    workspace_root,
)
from scripts.support.ruby_runtime import clean_environment, select_ruby

ROOT = Path(__file__).resolve().parents[2]
PROFILE = json.loads((ROOT / "Profiles/baseline.json").read_text())


def runtime_prefix():
    return workspace_root() / "runtime"


def project_state_directory(project):
    """Locate a fixture's private state independently of the native CLI."""
    project = Path(project).resolve()
    repository = next(
        (path for path in (project, *project.parents) if (path / ".git").exists()),
        project,
    )
    root = repository / ".swiftpods"
    if repository == project:
        return root
    name = bytes(
        byte
        if 48 <= byte <= 57 or 65 <= byte <= 90 or 97 <= byte <= 122 or byte in (45, 95)
        else 45
        for byte in project.name.encode()
    )[:48].decode("ascii")
    relative = project.relative_to(repository).as_posix().encode()
    key = name + "-" + hashlib.sha256(relative).hexdigest()
    return root / "projects" / key


def environment(destination=None):
    ruby, _ = select_ruby(PROFILE)
    env = clean_environment(os.environ)
    env.update(
        SWIFTPODS_RUBY=str(ruby), SWIFTPODS_BUNDLE=str(destination or runtime_prefix())
    )
    return env


def manifest(destination):
    files = {}
    for path in sorted(destination.rglob("*")):
        if path.parent == destination and path.name in (
            "compatibility.json",
            "compatibility.cms",
        ):
            continue
        relative = path.relative_to(destination).as_posix()
        if path.is_symlink():
            if not path.resolve().is_relative_to(destination.resolve()):
                raise RuntimeError("Bundle symlink escapes: " + relative)
            files[relative] = {"symlink": os.readlink(path)}
        elif path.is_file():
            files[relative] = {"sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    if any(
        name.startswith(("vendor/", "gems/", "runtime/")) or name == "host/host.rb"
        for name in files
    ):
        raise RuntimeError(
            "Native distributions must not contain a third-party engine or bundled Ruby"
        )
    result = dict(PROFILE)
    result["files"] = files
    result["bundle_digest"] = hashlib.sha256(
        json.dumps(files, sort_keys=True).encode()
    ).hexdigest()
    result["build_host"] = {
        "os": platform.mac_ver()[0],
        "architecture": platform.machine(),
    }
    result["native_ruby_libraries"] = []
    minimum = (13, 0)
    for path in destination.rglob("*"):
        if (
            path.is_file()
            and not path.is_symlink()
            and path.read_bytes()[:4] in (b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe")
        ):
            output = subprocess.check_output(
                ["xcrun", "vtool", "-show-build", str(path)], text=True
            )
            for value in re.findall(r"\bminos\s+([0-9.]+)", output):
                minimum = max(minimum, tuple(map(int, value.split("."))))
    result["minimum_macos"] = ".".join(map(str, minimum))
    from scripts.support.reporting import (
        contract_digest,
        source_digest,
        source_revision,
        toolchain_identity,
    )

    result["toolchain"] = toolchain_identity()
    tested_source, contract = source_digest(), contract_digest()
    result["swiftpods_source"] = {
        "base_commit": subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
        ).strip(),
        "worktree_has_changes": bool(
            subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT)
        ),
        "files_digest": tested_source,
    }
    registry = json.loads((ROOT / "Profiles/contract.json").read_text())
    result["compatibility_policy"] = registry.get("compatibility_policy", {})
    result["contract_digest"] = contract
    evidence, current = [], {}
    for name in ["native-units.json"] + [
        suite["report"] for suite in registry["suites"]
    ]:
        if not os.environ.get(WORKSPACE_ENV):
            break
        path = results_directory() / name
        if not path.exists():
            continue
        report = json.loads(path.read_text())
        if (
            report.get("status") == "passed"
            and report.get("source_digest") == tested_source
            and report.get("contract_digest") == contract
            and report.get("source_revision") == source_revision()
            and report.get("host") == result["build_host"]
            and report.get("toolchain") == result["toolchain"]
        ):
            current[name] = report
            evidence.append(
                {
                    "report": name,
                    "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                    "verified": report.get("verified", []),
                    "unverified": report.get("unverified", []),
                }
            )
    result["verification_evidence"] = {
        "reports": evidence,
        "source_digest": tested_source,
        "contract_digest": contract,
        "scope": registry["coverage_policy"],
        "stable_acceptance": "not_established",
    }
    result["matrix"] = [
        dict(row, status="build_passed", evidence="native-platforms.json")
        for row in current.get("native-platforms.json", {}).get("builds", [])
    ]
    result["matrix"] += [
        dict(row, status="unsigned_archive_passed", evidence="native-platforms.json")
        for row in current.get("native-platforms.json", {}).get("archives", [])
    ]
    result["matrix"] += [
        dict(row, status="application_executed", evidence="native-swift-binary.json")
        for row in current.get("native-swift-binary.json", {}).get("executions", [])
    ]
    result["matrix"] += [
        dict(
            row,
            status="supplementary_build_passed",
            evidence="native-host-platforms.json",
        )
        for row in current.get("native-host-platforms.json", {}).get("builds", [])
    ]
    for report, platform_name, sdk in [
        ("native-supplementary.json", "osx", "macosx"),
        ("native-ui.json", "ios", "iphonesimulator"),
    ]:
        for scenario in current.get(report, {}).get("scenarios", []):
            result["matrix"] += [
                dict(
                    row,
                    platform=platform_name,
                    sdk=sdk,
                    architecture=result["build_host"]["architecture"],
                    linkage=scenario["linkage"],
                    status="test_executed",
                    evidence=report,
                )
                for row in scenario.get("host_executions", [])
            ]
    result["gems"] = []
    (destination / "compatibility.json").write_text(json.dumps(result, indent=2) + "\n")


def main():
    select_ruby(PROFILE)
    prefix = runtime_prefix()
    with tempfile.TemporaryDirectory(
        prefix=".native-runtime-", dir=prefix.parent
    ) as temporary:
        staging = Path(temporary) / "runtime"
        shutil.copytree(ROOT / "Runtime", staging / "host")
        (staging / "licenses").mkdir()
        manifest(staging)
        backup = Path(temporary) / "previous"
        if prefix.exists():
            prefix.rename(backup)
        try:
            staging.rename(prefix)
        except BaseException:
            if backup.exists():
                backup.rename(prefix)
            raise
    print("Prepared native Swift engine adapter:", prefix)


if __name__ == "__main__":
    with workspace():
        main()
