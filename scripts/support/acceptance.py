"""Validate current evidence; never promote a missing check to a pass."""

import hashlib
import json
from pathlib import Path

from scripts.support.local_build import results_directory
from scripts.support.reporting import (
    ROOT,
    contract_digest,
    source_digest,
    source_revision,
)


def classify_differences(registry, content):
    policy = registry.get("compatibility_policy", {})
    improvements = policy.get("improvements", {})
    differences = []
    for name, report in content.items():
        for value in report.get("differences", []):
            if value.get("parity") is not False:
                continue
            rule = improvements.get(value.get("id"), {})
            evidence = rule.get("evidence", {})
            accepted = (
                policy.get("mode") == "input_compatible"
                and policy.get("inherit_reference_bugs") is False
                and rule.get("kind")
                in ("reference_bug_fix", "implementation_improvement")
                and rule.get("preserves_input_contract") is True
                and rule.get("feature") == value.get("feature")
                and rule.get("report") == name
                and bool(evidence)
                and all(
                    cases
                    and all(
                        case in content.get(required, {}).get("verified_cases", [])
                        for case in cases
                    )
                    for required, cases in evidence.items()
                )
            )
            differences.append(
                dict(
                    value,
                    report=name,
                    classification="accepted_improvement"
                    if accepted
                    else "unverified_difference",
                )
            )
    return differences


def collect(names, external=None):
    source, contract = source_digest(), contract_digest()
    revision = source_revision()
    reports, content = [], {}
    host = toolchain = executable = None
    for name in names:
        path = results_directory() / name
        if not path.is_file():
            raise RuntimeError("Missing required evidence: " + name)
        report = json.loads(path.read_text())
        content[name] = report
        if (
            report.get("status") != "passed"
            or report.get("source_digest") != source
            or report.get("contract_digest") != contract
        ):
            raise RuntimeError("Failed, stale or incomplete evidence: " + name)
        if report.get("source_revision") != revision:
            raise RuntimeError(
                "Evidence belongs to another revision or worktree state: " + name
            )
        if (
            not report.get("executable")
            or not report.get("toolchain")
            or not report.get("host")
        ):
            raise RuntimeError("Missing executable/host/toolchain identity: " + name)
        if host is None:
            host, toolchain = report["host"], report["toolchain"]
        if host != report["host"] or toolchain != report["toolchain"]:
            raise RuntimeError("Evidence belongs to another host/toolchain: " + name)
        if (
            not name.startswith("native-packaged-")
            and name != "native-distribution.json"
        ):
            if executable is None:
                executable = report["executable"]
            if executable != report["executable"]:
                raise RuntimeError(
                    "Evidence used different native executables: " + name
                )
        binary = Path(report["executable"]["path"])
        if (
            not binary.is_file()
            or hashlib.sha256(binary.read_bytes()).hexdigest()
            != report["executable"]["sha256"]
        ):
            raise RuntimeError("Verified executable changed: " + name)
        reports.append(
            {
                "report": name,
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "verified": report.get("verified", []),
                "unverified": report.get("unverified", []),
            }
        )
    registry = json.loads((ROOT / "Profiles/contract.json").read_text())
    available = set(names)
    requirements, statuses = [], {}
    for entry in registry["requirements"]:
        dependencies = entry.get("requirements", [])
        missing = sorted(set(entry.get("reports", [])).difference(available))
        covered = not missing and all(
            statuses.get(name) == "covered_by_current_reports" for name in dependencies
        )
        status = "covered_by_current_reports" if covered else "missing_evidence"
        statuses[entry["id"]] = status
        requirements.append(dict(entry, status=status, missing_reports=missing))
    gates = {name: {"status": "unverified"} for name in registry["external_gates"]}
    api = []
    for category, entries in registry["api"].items():
        for name, entry in entries.items():
            report = entry.get("declarations", entry.get("report"))
            case = entry.get("case", name)
            effects = entry.get("effects", [])
            missing_effects = sorted(set(effects).difference(available))
            covered = (
                case in content.get(report, {}).get("verified_cases", [])
                and not missing_effects
            )
            api.append(
                {
                    "category": category,
                    "name": name,
                    "report": report,
                    "case": case,
                    "effects": effects,
                    "missing_effect_reports": missing_effects,
                    "status": "covered_by_current_case"
                    if covered
                    else "missing_case_evidence",
                }
            )
    if external:
        supplied = json.loads(Path(external).read_text())
        if (
            supplied.get("source_digest") != source
            or supplied.get("contract_digest") != contract
        ):
            raise RuntimeError("External acceptance evidence is stale")
        for name, gate in supplied.get("gates", {}).items():
            if (
                name not in gates
                or gate.get("status") != "passed"
                or not gate.get("evidence")
            ):
                raise RuntimeError("Invalid external acceptance gate: " + name)
            for item in gate["evidence"]:
                file = Path(item["path"])
                if (
                    not file.is_file()
                    or hashlib.sha256(file.read_bytes()).hexdigest() != item["sha256"]
                ):
                    raise RuntimeError("External gate evidence changed: " + str(file))
            gates[name] = gate
    complete = all(value == "covered_by_current_reports" for value in statuses.values())
    differences = classify_differences(registry, content)
    blocking_differences = [
        value
        for value in differences
        if value["classification"] != "accepted_improvement"
    ]
    stable = (
        complete
        and not blocking_differences
        and all(entry["status"] == "covered_by_current_case" for entry in api)
        and not revision["dirty"]
        and all(gate["status"] == "passed" for gate in gates.values())
    )
    return {
        "status": "passed",
        "engine": "swift",
        "reports": reports,
        "requirements": requirements,
        "api_coverage": api,
        "external_gates": gates,
        "stable_acceptance": "established" if stable else "not_established",
        "source_revision": revision,
        "compatibility_differences": differences,
        "blocking_compatibility_differences": blocking_differences,
        "compatibility_policy": registry.get("compatibility_policy", {}),
        "coverage_policy": registry["coverage_policy"],
        "swift_unit_tests": content.get("native-units.json", {}).get("test_count"),
    }
