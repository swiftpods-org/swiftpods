#!/usr/bin/env python3
"""Exercise missing, stale, changed and incomplete acceptance evidence."""

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

import acceptance
import evidence as evidence_tools
import reporting
import swift_binary_producer as swift_producer
from reporting import ROOT, execute
from vendor_fixture import run as fixture_command


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "test-results").mkdir()
        (self.root / "Profiles").mkdir()
        self.binary = self.root / "swiftpods"
        self.binary.write_bytes(b"fixture executable")
        self.report = {
            "status": "passed",
            "source_digest": "source",
            "contract_digest": "contract",
            "host": {"architecture": "arm64"},
            "toolchain": {"swift": "fixture"},
            "executable": {
                "path": str(self.binary),
                "sha256": hashlib.sha256(self.binary.read_bytes()).hexdigest(),
            },
            "source_revision": {"commit": "fixed", "dirty": False},
            "test_count": 1,
            "verified_cases": ["method"],
        }
        self.names = ["native-units.json", "fixture.json"]
        self.revision = self.report["source_revision"]
        for name in self.names:
            self.write(name, self.report)
        registry = {
            "requirements": [{"id": "T-001", "reports": self.names}],
            "external_gates": ["physical_devices"],
            "api": {"methods": {"method": {"report": "fixture.json"}}},
            "coverage_policy": "bounded fixture",
        }
        self.registry = registry
        (self.root / "Profiles/contract.json").write_text(json.dumps(registry))
        patches = [
            patch.object(acceptance, "ROOT", self.root),
            patch.object(acceptance, "source_digest", return_value="source"),
            patch.object(acceptance, "contract_digest", return_value="contract"),
            patch.object(
                acceptance, "source_revision", side_effect=lambda: self.revision
            ),
        ]
        for replacement in patches:
            replacement.start()
            self.addCleanup(replacement.stop)

    def write(self, name, value):
        (self.root / "test-results" / name).write_text(json.dumps(value))

    def improvement(self):
        difference = {
            "id": "fixture.correct_output",
            "feature": "Fixture",
            "parity": False,
            "reference": "incorrect output",
            "native": "correct output",
        }
        report = dict(
            self.report,
            differences=[difference],
            verified_cases=["method", "unchanged_input", "correct_output"],
        )
        rule = {
            "feature": "Fixture",
            "report": "fixture.json",
            "kind": "reference_bug_fix",
            "preserves_input_contract": True,
            "evidence": {"fixture.json": ["unchanged_input", "correct_output"]},
        }
        self.registry["compatibility_policy"] = {
            "mode": "input_compatible",
            "inherit_reference_bugs": False,
            "improvements": {"fixture.correct_output": rule},
        }
        self.write("fixture.json", report)
        (self.root / "Profiles/contract.json").write_text(json.dumps(self.registry))
        return report, rule

    def external_gate(self):
        evidence = self.root / "device.log"
        evidence.write_text("fixture")
        supplied = self.root / "external.json"
        supplied.write_text(
            json.dumps(
                {
                    "source_digest": "source",
                    "contract_digest": "contract",
                    "gates": {
                        "physical_devices": {
                            "status": "passed",
                            "evidence": [
                                {
                                    "path": str(evidence),
                                    "sha256": hashlib.sha256(
                                        evidence.read_bytes()
                                    ).hexdigest(),
                                }
                            ],
                        }
                    },
                }
            )
        )
        return supplied

    def testPassingLocalReportsLeaveExternalGateUnverified(self):
        result = acceptance.collect(self.names)
        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["stable_acceptance"], "not_established")
        self.assertEqual(
            result["external_gates"]["physical_devices"]["status"], "unverified"
        )

    def testFixtureTimeoutStopsDescendantsAfterTheParentExits(self):
        state = self.root / "child.json"
        child = "import json,os,signal,sys,time;signal.signal(signal.SIGINT,signal.SIG_IGN);signal.signal(signal.SIGTERM,signal.SIG_IGN);json.dump({'pid':os.getpid(),'group':os.getpgrp()},open(sys.argv[1],'w'));time.sleep(60)"
        parent = "import subprocess,sys,time;subprocess.Popen([sys.executable,'-c',sys.argv[1],sys.argv[2]]);time.sleep(60)"
        with self.assertRaises(subprocess.TimeoutExpired):
            fixture_command(
                [sys.executable, "-c", parent, child, str(state)],
                self.root,
                self.root / "timeout.log",
                timeout=1,
            )
        value = json.loads(state.read_text())

        def cleanup():
            try:
                os.killpg(value["group"], 9)
            except ProcessLookupError:
                pass

        self.addCleanup(cleanup)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            status = subprocess.run(
                ["ps", "-p", str(value["pid"]), "-o", "stat="],
                capture_output=True,
                text=True,
            ).stdout.strip()
            if not status or status.startswith("Z"):
                break
            time.sleep(0.02)
        self.assertTrue(
            not status or status.startswith("Z"),
            "Timed-out fixture left its descendant running",
        )

    def testSwiftLanguageModeDoesNotPretendToBeAnotherCompiler(self):
        compiler = "Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)"
        interface = compiler.replace("6.4 (", "6.4 effective-5.10 (")
        self.assertEqual(
            swift_producer.compiler_identity(compiler),
            swift_producer.compiler_identity(interface),
        )
        self.assertNotEqual(
            swift_producer.compiler_identity(compiler),
            swift_producer.compiler_identity(compiler.replace("6.4", "6.1")),
        )

    def testSwiftProducerRejectsChangedPayloadAndStaleSnapshot(self):
        framework = self.root / "SwiftBinaryKit.framework"
        framework.mkdir()
        (framework / "SwiftBinaryKit").write_bytes(b"fixture framework")
        metadata = {
            "schema_version": 1,
            "architecture": swift_producer.platform.machine(),
            "source_digest": "source",
            "contract_digest": "contract",
            "source_revision": self.revision,
            "files": swift_producer.inventory(framework),
        }
        manifest = self.root / "producer.json"
        with (
            patch.object(swift_producer, "source_digest", return_value="source"),
            patch.object(swift_producer, "contract_digest", return_value="contract"),
            patch.object(swift_producer, "source_revision", return_value=self.revision),
        ):
            for key, value in [
                ("source_digest", "stale"),
                ("contract_digest", "stale"),
                ("source_revision", {"commit": "other", "dirty": False}),
            ]:
                manifest.write_text(json.dumps(dict(metadata, **{key: value})))
                with self.assertRaisesRegex(RuntimeError, "another source or contract"):
                    swift_producer.validate(framework, manifest)
            manifest.write_text(json.dumps(metadata))
            (framework / "SwiftBinaryKit").write_bytes(b"changed framework")
            with self.assertRaisesRegex(RuntimeError, "inventory/checksum"):
                swift_producer.validate(framework, manifest)

    def testSwiftProducerRejectsCompilerLabelThatDisagreesWithInterface(self):
        framework = self.root / "SwiftBinaryKit.framework"
        framework.mkdir()
        (framework / "arm64.swiftinterface").write_text(
            "// swift-compiler-version: Apple Swift version 6.4\n"
        )
        metadata = {
            "schema_version": 1,
            "architecture": swift_producer.platform.machine(),
            "source_digest": "source",
            "contract_digest": "contract",
            "source_revision": self.revision,
            "files": swift_producer.inventory(framework),
            "compiler_version": "Apple Swift version 6.4",
            "toolchain": "Apple Swift version 6.1",
        }
        manifest = self.root / "producer.json"
        manifest.write_text(json.dumps(metadata))
        with (
            patch.object(swift_producer, "source_digest", return_value="source"),
            patch.object(swift_producer, "contract_digest", return_value="contract"),
            patch.object(swift_producer, "source_revision", return_value=self.revision),
        ):
            with self.assertRaisesRegex(RuntimeError, "compiler identity"):
                swift_producer.validate(framework, manifest)

    def testTestedInputCompatibleImprovementDoesNotRequireReferenceBugParity(self):
        self.improvement()
        local = acceptance.collect(self.names)
        self.assertEqual(local["stable_acceptance"], "not_established")
        result = acceptance.collect(self.names, self.external_gate())
        self.assertEqual(result["stable_acceptance"], "established")
        self.assertEqual(result["blocking_compatibility_differences"], [])
        self.assertEqual(
            result["compatibility_differences"][0]["classification"],
            "accepted_improvement",
        )
        self.assertIs(result["compatibility_differences"][0]["parity"], False)

    def testUnregisteredOutputDifferenceRemainsVisibleAndBlocking(self):
        report, _ = self.improvement()
        self.registry.pop("compatibility_policy")
        (self.root / "Profiles/contract.json").write_text(json.dumps(self.registry))
        result = acceptance.collect(self.names, self.external_gate())
        self.assertEqual(result["stable_acceptance"], "not_established")
        self.assertEqual(
            result["blocking_compatibility_differences"][0]["id"],
            report["differences"][0]["id"],
        )

    def testImprovementRequiresMatchingIdentityAndInputAndEffectCases(self):
        external = self.external_gate()
        for field, value in [
            ("preserves_input_contract", False),
            ("feature", "another"),
            ("report", "another.json"),
            ("kind", "unverified"),
            ("evidence", {}),
            ("evidence", {"absent.json": ["correct_output"]}),
        ]:
            _, rule = self.improvement()
            rule[field] = value
            (self.root / "Profiles/contract.json").write_text(json.dumps(self.registry))
            self.assertEqual(
                acceptance.collect(self.names, external)["stable_acceptance"],
                "not_established",
                field,
            )
        for cases in [["method", "unchanged_input"], ["method", "correct_output"]]:
            report, _ = self.improvement()
            self.write("fixture.json", dict(report, verified_cases=cases))
            self.assertEqual(
                acceptance.collect(self.names, external)["stable_acceptance"],
                "not_established",
                cases,
            )

    def testAcceptedImprovementDoesNotReplaceRequiredAPIOrUnitEvidence(self):
        report, _ = self.improvement()
        self.write(
            "fixture.json",
            dict(report, verified_cases=["unchanged_input", "correct_output"]),
        )
        result = acceptance.collect(self.names, self.external_gate())
        self.assertEqual(result["blocking_compatibility_differences"], [])
        self.assertEqual(result["stable_acceptance"], "not_established")
        partial = acceptance.collect(["fixture.json"])
        self.assertIsNone(partial["swift_unit_tests"])

    def testMissingAndFailedReportsAreRejected(self):
        for report in [
            dict(self.report, status="skipped"),
            dict(self.report, status="failed"),
            dict(self.report, status="running"),
        ]:
            self.write("fixture.json", report)
            with self.assertRaises(RuntimeError):
                acceptance.collect(self.names)
        (self.root / "test-results/fixture.json").unlink()
        with self.assertRaises(RuntimeError):
            acceptance.collect(self.names)

    def testStaleContractSourceToolchainAndBinaryAreRejected(self):
        for key, value in [
            ("contract_digest", "old"),
            ("source_digest", "old"),
            ("toolchain", {"swift": "another"}),
        ]:
            self.write("fixture.json", dict(self.report, **{key: value}))
            with self.assertRaises(RuntimeError):
                acceptance.collect(self.names)
        self.write("fixture.json", self.report)
        self.binary.write_bytes(b"replaced executable")
        with self.assertRaises(RuntimeError):
            acceptance.collect(self.names)

    def testRunningFixtureRejectsReplacedBinaryAndRuby(self):
        metadata = {
            "source_digest": "source",
            "source_revision": self.revision,
            "toolchain": {"external_ruby": {"sha256": "original-ruby"}},
            "executable": self.report["executable"],
        }
        with (
            patch.object(reporting, "source_digest", return_value="source"),
            patch.object(reporting, "source_revision", return_value=self.revision),
            patch.object(
                reporting, "toolchain_identity", return_value=metadata["toolchain"]
            ) as toolchain,
            patch.object(
                reporting, "binary_identity", return_value=metadata["executable"]
            ) as binary,
        ):
            reporting.verify_snapshot(metadata)
            binary.return_value = dict(metadata["executable"], sha256="relinked")
            with self.assertRaisesRegex(RuntimeError, "Executable changed"):
                reporting.verify_snapshot(metadata)
            reporting.verify_snapshot(metadata, allow_build=True)
            toolchain.return_value = {"external_ruby": {"sha256": "replaced-ruby"}}
            with self.assertRaisesRegex(RuntimeError, "Toolchain changed"):
                reporting.verify_snapshot(metadata, allow_build=True)

    def testSuppliedExternalEvidenceMustMatchItsHash(self):
        evidence = self.root / "device.log"
        evidence.write_text("fixture")
        supplied = self.root / "external.json"
        supplied.write_text(
            json.dumps(
                {
                    "source_digest": "source",
                    "contract_digest": "contract",
                    "gates": {
                        "physical_devices": {
                            "status": "passed",
                            "evidence": [{"path": str(evidence), "sha256": "0" * 64}],
                        }
                    },
                }
            )
        )
        with self.assertRaises(RuntimeError):
            acceptance.collect(self.names, supplied)

    def testAnotherRevisionOrNewDirtyStateIsRejected(self):
        self.revision = {"commit": "another", "dirty": False}
        with self.assertRaises(RuntimeError):
            acceptance.collect(self.names)
        self.revision = {"commit": "fixed", "dirty": True}
        with self.assertRaises(RuntimeError):
            acceptance.collect(self.names)

    def testDirtyRevisionCannotBecomeStableEvenWithVerifiedExternalGate(self):
        self.revision = {"commit": "fixed", "dirty": True}
        for name in self.names:
            self.write(
                name,
                dict(self.report, source_revision={"commit": "fixed", "dirty": True}),
            )
        evidence = self.root / "device.log"
        evidence.write_text("fixture")
        supplied = self.root / "external.json"
        supplied.write_text(
            json.dumps(
                {
                    "source_digest": "source",
                    "contract_digest": "contract",
                    "gates": {
                        "physical_devices": {
                            "status": "passed",
                            "evidence": [
                                {
                                    "path": str(evidence),
                                    "sha256": hashlib.sha256(
                                        evidence.read_bytes()
                                    ).hexdigest(),
                                }
                            ],
                        }
                    },
                }
            )
        )
        self.assertEqual(
            acceptance.collect(self.names, supplied)["stable_acceptance"],
            "not_established",
        )

    def evidence_archive(
        self, *, changed_log=False, extra_file=False, missing_report=False
    ):
        metadata = {
            "swiftpods_source": {
                "base_commit": "fixed",
                "worktree_has_changes": False,
                "files_digest": "source",
            },
            "contract_digest": "contract",
            "build_host": self.report["host"],
            "toolchain": self.report["toolchain"],
            "bundle_digest": "bundle",
            "files": {"bin/swiftpods": {"sha256": self.report["executable"]["sha256"]}},
        }
        acceptance = dict(
            self.report,
            full=True,
            apple_integration_omitted=False,
            stable_acceptance="not_established",
        )
        files = {"logs/test.log": b"passed"}
        reports = []
        for name in self.names[:1] if missing_report else self.names:
            data = json.dumps(self.report).encode()
            files["reports/" + name] = data
            reports.append({"report": name, "sha256": evidence_tools.digest(data)})
        acceptance["reports"] = reports
        files["acceptance.json"] = json.dumps(acceptance).encode()
        index = {
            key: acceptance[key]
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
            bundles=[
                {
                    "bundle_digest": "bundle",
                    "manifest_sha256": "manifest",
                    "executable_sha256": self.report["executable"]["sha256"],
                }
            ],
            files={name: evidence_tools.digest(data) for name, data in files.items()},
        )
        path = self.root / "evidence.zip"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("index.json", json.dumps(index))
            for name, data in files.items():
                archive.writestr(
                    name,
                    b"changed" if changed_log and name == "logs/test.log" else data,
                )
            if extra_file:
                archive.writestr("unexpected", "extra")
        return path, metadata

    def testPortableEvidenceChecksEveryFileAndRequiredReport(self):
        with patch.object(
            evidence_tools, "required_reports", return_value=set(self.names)
        ):
            path, metadata = self.evidence_archive()
            self.assertEqual(
                evidence_tools.validate(path, metadata, "manifest")[
                    "stable_acceptance"
                ],
                "not_established",
            )
            for options in [
                {"changed_log": True},
                {"extra_file": True},
                {"missing_report": True},
            ]:
                path, _ = self.evidence_archive(**options)
                with self.assertRaises(RuntimeError):
                    evidence_tools.validate(path)

    def testPortableEvidenceRejectsAnotherBundleManifestAndRevision(self):
        with patch.object(
            evidence_tools, "required_reports", return_value=set(self.names)
        ):
            path, metadata = self.evidence_archive()
            with self.assertRaises(RuntimeError):
                evidence_tools.validate(path, metadata, "changed-manifest")
            metadata["bundle_digest"] = "untested-bundle"
            with self.assertRaises(RuntimeError):
                evidence_tools.validate(path, metadata)
            path, metadata = self.evidence_archive()
            metadata["swiftpods_source"]["base_commit"] = "another-revision"
            with self.assertRaises(RuntimeError):
                evidence_tools.validate(path, metadata)


def main():
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(EvidenceTests)
    )
    if not result.wasSuccessful():
        raise RuntimeError("Acceptance evidence tests failed")
    (ROOT / "test-results/native-acceptance-harness.json").write_text(
        json.dumps(
            {
                "status": "passed",
                "test_count": result.testsRun,
                "verified": [
                    "missing, failed and skipped evidence rejected",
                    "stale source, contract and toolchain rejected",
                    "replaced executable rejected",
                    "external artifact hash checked",
                    "unverified external gates and dirty revisions cannot establish stable acceptance",
                ],
            },
            indent=2,
        )
        + "\n"
    )


if __name__ == "__main__":
    execute(main, "native-acceptance-harness.json")
