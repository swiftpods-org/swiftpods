#!/usr/bin/env python3
"""Export current full acceptance and its logs without depending on runner paths."""

import argparse
import hashlib
import json
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

from reporting import ROOT, contract_digest, source_digest, source_revision


def digest(data):
    return hashlib.sha256(data).hexdigest()


def required_reports():
    registry = json.loads((ROOT / "Profiles/contract.json").read_text())
    return {
        "native-units.json",
        "native-distribution.json",
        *[suite["report"] for suite in registry["suites"]],
        *[
            "native-packaged-" + name + ".json"
            for name in ["variants", "configuration", "layout", "ui"]
        ],
    }


def collect_external_artifacts(report, files):
    """Make passed external gates verifiable after their runner is gone."""
    artifacts = []
    for gate_name, gate in report.get("external_gates", {}).items():
        if gate.get("status") != "passed":
            continue
        for position, item in enumerate(gate.get("evidence", [])):
            path = Path(item["path"])
            data = path.read_bytes()
            if digest(data) != item["sha256"]:
                raise RuntimeError("External gate evidence changed: " + str(path))
            name = "external/" + gate_name + "/" + str(position) + "/" + path.name
            files[name] = data
            artifacts.append(
                {
                    "gate": gate_name,
                    "path": str(path),
                    "archive_path": name,
                    "sha256": item["sha256"],
                }
            )
    return artifacts


def validate_external_artifacts(archive, index, acceptance):
    """Keep old nonstable archives readable; stable gates require their bytes."""
    gates = acceptance.get("external_gates", {})
    registry = json.loads((ROOT / "Profiles/contract.json").read_text())
    if acceptance["stable_acceptance"] == "established" and (
        set(gates) != set(registry["external_gates"])
        or any(gate.get("status") != "passed" for gate in gates.values())
        or acceptance["source_revision"].get("dirty") is not False
    ):
        raise RuntimeError(
            "Stable evidence has incomplete external gates or dirty sources"
        )
    if (
        "external_artifacts" not in index
        and acceptance["stable_acceptance"] != "established"
    ):
        return
    artifacts = index.get("external_artifacts", [])
    expected = []
    for gate_name, gate in gates.items():
        if gate.get("status") != "passed":
            continue
        if not gate.get("evidence"):
            raise RuntimeError("Passed external gate has no evidence: " + gate_name)
        for item in gate["evidence"]:
            matches = [
                entry
                for entry in artifacts
                if entry.get("gate") == gate_name
                and entry.get("path") == item["path"]
                and entry.get("sha256") == item["sha256"]
            ]
            if len(matches) != 1:
                raise RuntimeError(
                    "Missing or duplicated external gate artifact: " + gate_name
                )
            entry = matches[0]
            name = entry["archive_path"]
            if (
                name not in index["files"]
                or digest(archive.read(name)) != item["sha256"]
            ):
                raise RuntimeError(
                    "External gate artifact checksum mismatch: " + gate_name
                )
            expected.append(entry)
    if expected != artifacts:
        raise RuntimeError("Evidence contains unclaimed external gate artifacts")


def export(destination):
    from acceptance import collect

    report_path = ROOT / "test-results/check.json"
    report = json.loads(report_path.read_text())
    if (
        report.get("status") != "passed"
        or report.get("full") is not True
        or report.get("apple_integration_omitted") is not False
    ):
        raise RuntimeError("Evidence export requires a passing full packaged run")
    if (
        report.get("source_digest") != source_digest()
        or report.get("contract_digest") != contract_digest()
        or report.get("source_revision") != source_revision()
    ):
        raise RuntimeError("Acceptance snapshot changed before evidence export")
    names = [entry["report"] for entry in report["reports"]]
    if set(names) != required_reports() or len(names) != len(set(names)):
        raise RuntimeError(
            "Full packaged acceptance reports are incomplete or duplicated"
        )
    validated = collect(names)
    if validated["reports"] != report["reports"]:
        raise RuntimeError("Acceptance report files changed before evidence export")
    files = {"acceptance.json": report_path.read_bytes()}
    bundles = {}
    for entry in report["reports"]:
        name = entry["report"]
        path = ROOT / "test-results" / name
        files["reports/" + name] = path.read_bytes()
        value = json.loads(files["reports/" + name])
        if value.get("log"):
            log = Path(value["log"])
            if not log.is_file():
                raise RuntimeError("Missing verification log: " + str(log))
            files["logs/" + name.removesuffix(".json") + "/" + log.name] = (
                log.read_bytes()
            )
        fixture = Path(value["fixture"]) if value.get("fixture") else None
        if fixture:
            if not fixture.resolve().is_relative_to((ROOT / ".build").resolve()):
                raise RuntimeError("Fixture logs must belong to this checkout")
            for log in sorted(fixture.rglob("*.log")):
                if log.is_file() and not log.is_symlink():
                    files[
                        "fixtures/"
                        + name.removesuffix(".json")
                        + "/"
                        + log.relative_to(fixture).as_posix()
                    ] = log.read_bytes()
        if name == "native-distribution.json" or name.startswith("native-packaged-"):
            executable = Path(value["executable"]["path"])
            manifest = executable.parent.parent / "compatibility.json"
            metadata = json.loads(manifest.read_text())
            bundles[metadata["bundle_digest"]] = {
                "bundle_digest": metadata["bundle_digest"],
                "manifest_sha256": digest(manifest.read_bytes()),
                "executable_sha256": value["executable"]["sha256"],
                "architecture": metadata["build_host"]["architecture"],
            }
    for index, stage in enumerate(report["stages"]):
        log = Path(stage["log"])
        if stage.get("exit_status") != 0 or not log.is_file():
            raise RuntimeError(
                "Missing or unsuccessful acceptance stage: " + str(index)
            )
        files["logs/stages/" + str(index) + ".log"] = log.read_bytes()
    supplemental = ROOT / "test-results/native-homebrew.json"
    if supplemental.is_file():
        value = json.loads(supplemental.read_text())
        if (
            value.get("status") == "passed"
            and value.get("bundle_digest") in bundles
            and all(
                value.get(key) == report[key]
                for key in [
                    "source_digest",
                    "source_revision",
                    "contract_digest",
                    "host",
                    "toolchain",
                ]
            )
        ):
            log = Path(value["log"])
            if not log.is_file():
                raise RuntimeError("Missing Homebrew verification log")
            files["supplemental/native-homebrew.json"] = supplemental.read_bytes()
            files["supplemental/homebrew.log"] = log.read_bytes()
    external_artifacts = collect_external_artifacts(report, files)
    index = {
        key: report[key]
        for key in [
            "source_digest",
            "source_revision",
            "contract_digest",
            "host",
            "toolchain",
            "stable_acceptance",
        ]
    }
    index.update(
        schema_version=1,
        bundles=list(bundles.values()),
        files={name: digest(data) for name, data in sorted(files.items())},
        external_artifacts=external_artifacts,
    )
    destination = Path(destination).absolute()
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        prefix=".evidence-", dir=destination.parent, delete=False
    ) as temporary:
        pending = Path(temporary.name)
    try:
        with zipfile.ZipFile(pending, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("index.json", json.dumps(index, indent=2) + "\n")
            for name, data in sorted(files.items()):
                archive.writestr(name, data)
        validate(pending)
        pending.replace(destination)
    finally:
        pending.unlink(missing_ok=True)
    print(
        "Acceptance evidence:",
        destination,
        "SHA-256:",
        digest(destination.read_bytes()),
    )
    return destination


def validate(path, metadata=None, manifest_sha256=None):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or any(
            PurePosixPath(name).is_absolute()
            or ".." in PurePosixPath(name).parts
            or "\\" in name
            for name in names
        ):
            raise RuntimeError("Unsafe or duplicated evidence archive path")
        index = json.loads(archive.read("index.json"))
        if index.get("schema_version") != 1 or set(names) != {
            *index["files"],
            "index.json",
        }:
            raise RuntimeError("Evidence inventory does not match its archive")
        for name, expected in index["files"].items():
            if digest(archive.read(name)) != expected:
                raise RuntimeError("Evidence file checksum mismatch: " + name)
        acceptance = json.loads(archive.read("acceptance.json"))
        if (
            acceptance.get("status") != "passed"
            or acceptance.get("full") is not True
            or acceptance.get("apple_integration_omitted") is not False
        ):
            raise RuntimeError("Evidence does not contain full passing acceptance")
        for key in [
            "source_digest",
            "source_revision",
            "contract_digest",
            "host",
            "toolchain",
            "stable_acceptance",
        ]:
            if index[key] != acceptance[key]:
                raise RuntimeError("Evidence identity mismatch: " + key)
        validate_external_artifacts(archive, index, acceptance)
        reports = acceptance["reports"]
        if {entry["report"] for entry in reports} != required_reports() or len(
            reports
        ) != len(required_reports()):
            raise RuntimeError("Evidence is missing required packaged reports")
        for entry in reports:
            data = archive.read("reports/" + entry["report"])
            value = json.loads(data)
            if digest(data) != entry["sha256"] or value.get("status") != "passed":
                raise RuntimeError(
                    "Acceptance report checksum/status mismatch: " + entry["report"]
                )
            for key in [
                "source_digest",
                "source_revision",
                "contract_digest",
                "host",
                "toolchain",
            ]:
                if value[key] != acceptance[key]:
                    raise RuntimeError("Report identity mismatch: " + entry["report"])
        if metadata:
            source = metadata["swiftpods_source"]
            if (
                index["source_digest"] != source["files_digest"]
                or index["contract_digest"] != metadata["contract_digest"]
                or index["source_revision"]
                != {
                    "commit": source["base_commit"],
                    "dirty": source["worktree_has_changes"],
                }
                or index["host"] != metadata["build_host"]
                or index["toolchain"] != metadata["toolchain"]
            ):
                raise RuntimeError(
                    "Evidence belongs to another release snapshot or toolchain"
                )
            if not any(
                bundle["bundle_digest"] == metadata["bundle_digest"]
                and bundle["executable_sha256"]
                == metadata["files"]["bin/swiftpods"]["sha256"]
                and (
                    manifest_sha256 is None
                    or bundle["manifest_sha256"] == manifest_sha256
                )
                for bundle in index["bundles"]
            ):
                raise RuntimeError("Evidence did not test this packaged executable")
        return index


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--destination", type=Path, default=ROOT / "test-results/evidence.zip"
    )
    export(parser.parse_args().destination)
