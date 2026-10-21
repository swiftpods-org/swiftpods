#!/usr/bin/env python3
"""Run native, independent reference and packaged checks from one source snapshot."""

import argparse
import json
import os
import re
import sys
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

from acceptance import collect
from local_build import results_directory
from local_build import workspace as build_workspace
from processes import run_logged, termination_signals
from reporting import ROOT, execute, option_value, write_report
from ruby_runtime import clean_environment, select_ruby


class VerificationStages:
    """Own stage logs, report aggregation, and cancellation across worker threads."""

    def __init__(self):
        self.stages = []
        self.reports = []
        self.lock = threading.Lock()
        self.cancelled = threading.Event()

    def run(self, command, report=None, env=None):
        print("Running:", " ".join(map(str, command)), flush=True)
        with self.lock:
            log = results_directory() / (
                "native-check-" + str(len(self.stages)) + ".log"
            )
            stage = {
                "command": list(map(str, command)),
                "exit_status": None,
                "log": str(log),
            }
            self.stages.append(stage)
        # Nested fixture runners need time to cancel their own process groups.
        try:
            status = run_logged(
                command,
                ROOT,
                log,
                env=env,
                cancelled=self.cancelled,
                cancellation_grace=4,
            )
        except BaseException as error:
            with self.lock:
                stage["error"] = str(error) or type(error).__name__
                write_report(
                    results_directory() / "check.json",
                    {
                        "status": "failed",
                        "stages": self.stages,
                        "failed_report": report,
                    },
                )
            raise
        warning = re.search(
            r"(?m)^\s*(?:[^\n]*:[0-9]+:[0-9]+:\s*|(?:clang|swift):\s*)?warning:",
            log.read_text(errors="replace"),
        )
        with self.lock:
            stage["exit_status"] = status
            if status or warning:
                write_report(
                    results_directory() / "check.json",
                    {
                        "status": "failed",
                        "stages": self.stages,
                        "failed_report": report,
                        "compiler_warning": bool(warning),
                    },
                )
                raise RuntimeError("Verification failed; see " + str(log))
            if report:
                self.reports.append(report)


def check_package(run, args):
    run([sys.executable, "scripts/package.py", "--destination", args.package])
    if args.signing_identity:
        command = [
            sys.executable,
            "scripts/sign_release.py",
            args.package,
            "--identity",
            args.signing_identity,
        ]
        if args.notary_profile:
            command += ["--notarize", "--keychain-profile", args.notary_profile]
            if args.notary_keychain:
                command += ["--keychain", args.notary_keychain]
        run(command)
    run(
        [sys.executable, "scripts/native_distribution_tests.py", args.package],
        "native-distribution.json",
    )
    if args.full:
        for name in ["variant", "configuration", "layout", "ui"]:
            report = (
                "native-packaged-"
                + ("variants" if name == "variant" else name)
                + ".json"
            )
            run(
                [
                    sys.executable,
                    "scripts/native_" + name + "_tests.py",
                    "--bundle",
                    args.package,
                ],
                report,
            )


def main(workspace):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--full",
        action="store_true",
        help="Require all native and isolated reference suites",
    )
    parser.add_argument(
        "--skip-apple",
        action="store_true",
        help="Explicitly incomplete native smoke check",
    )
    parser.add_argument(
        "--reference-gem-home", type=Path, default=workspace / "reference-gems"
    )
    parser.add_argument(
        "--package",
        nargs="?",
        const=True,
        type=Path,
        help="Check a temporary package, or export it to an explicitly supplied path",
    )
    parser.add_argument("--external-evidence", type=Path)
    parser.add_argument(
        "--evidence-destination",
        type=Path,
        help="Export verification evidence before temporary reports are removed",
    )
    parser.add_argument("--require-stable", action="store_true")
    parser.add_argument(
        "--signing-identity",
        help="Explicit Developer ID identity for a clean release checkout",
    )
    parser.add_argument(
        "--notary-profile", help="Explicit existing notarytool keychain profile"
    )
    parser.add_argument("--notary-keychain", type=Path)
    parser.add_argument(
        "--jobs",
        type=int,
        default=2,
        help="Isolated fixture processes after the build finishes",
    )
    args = parser.parse_args()
    if args.package is True:
        args.package = workspace / "SwiftPods"
    if not 1 <= args.jobs <= 8:
        parser.error("--jobs must be between 1 and 8")
    if args.full and args.skip_apple:
        parser.error("--full cannot skip required Apple checks")
    if args.evidence_destination and not (args.full and args.package):
        parser.error("--evidence-destination requires --full and --package")
    if args.require_stable and (not args.full or not args.package):
        parser.error("--require-stable requires --full and --package")
    if (
        args.signing_identity
        and (not args.full or not args.package)
        or args.notary_profile
        and not args.signing_identity
    ):
        parser.error(
            "Signing requires --full --package; notarization also requires --signing-identity"
        )
    registry = json.loads((ROOT / "Profiles/contract.json").read_text())
    verification = VerificationStages()
    stages, reports, run = verification.stages, verification.reports, verification.run

    run([sys.executable, "scripts/package_tests.py"])
    run([sys.executable, "scripts/local_build_tests.py"])
    run([sys.executable, "scripts/bootstrap.py"])
    run([sys.executable, "scripts/unit_tests.py"], "native-units.json")
    run([sys.executable, "scripts/ruby_runtime_tests.py"])
    ruby, _ = select_ruby(json.loads((ROOT / "Profiles/baseline.json").read_text()))
    run(
        [ruby, "scripts/ruby_adapter_tests.rb"],
        env=clean_environment(os.environ),
    )
    run(
        [sys.executable, "scripts/ruby_compatibility_tests.py", "--ruby", ruby],
        "ruby-compatibility.json",
    )
    if args.full:
        run(
            [
                sys.executable,
                "scripts/prepare_reference.py",
                "--gem-home",
                args.reference_gem_home,
            ]
        )
    # No Swift rebuilds occur while CLI fixtures are active.
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        try:
            pending = []
            for suite in registry["suites"]:
                if (
                    suite["reference"]
                    and not args.full
                    or suite["apple"]
                    and args.skip_apple
                ):
                    continue
                command = [sys.executable, suite["script"]]
                if suite["reference"]:
                    command += ["--gem-home", args.reference_gem_home]
                pending.append(pool.submit(run, command, suite["report"]))
            failures = []
            for result in as_completed(pending):
                try:
                    result.result()
                except Exception as error:
                    failures.append(str(error))
            if failures:
                raise RuntimeError("\n".join(failures))
        except BaseException:
            verification.cancelled.set()
            for future in pending:
                future.cancel()
            raise
    if args.package:
        check_package(run, args)
    aggregate = collect(reports, args.external_evidence)
    aggregate.update(
        stages=stages, full=args.full, apple_integration_omitted=args.skip_apple
    )
    (results_directory() / "check.json").write_text(
        json.dumps(aggregate, indent=2) + "\n"
    )
    if args.require_stable and aggregate["stable_acceptance"] != "established":
        raise RuntimeError(
            "Stable acceptance is incomplete: inspect external gates and source revision in check.json"
        )
    print("Verification passed; stable acceptance:", aggregate["stable_acceptance"])


@termination_signals()
def run_checks():
    with build_workspace() as temporary:
        execute(lambda: main(temporary), "check.json")
        if "--full" in sys.argv and any(
            argument == "--package" or argument.startswith("--package=")
            for argument in sys.argv[1:]
        ):
            from evidence import export

            try:
                destination = option_value("--evidence-destination")
                export(
                    Path(destination).resolve()
                    if destination
                    else results_directory() / "evidence.zip"
                )
            except BaseException as error:
                path = results_directory() / "check.json"
                report = json.loads(path.read_text())
                report.update(
                    status="failed", error="Evidence export failed: " + str(error)
                )
                path.write_text(json.dumps(report, indent=2) + "\n")
                raise


if __name__ == "__main__":
    run_checks()
