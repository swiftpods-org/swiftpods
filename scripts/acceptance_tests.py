#!/usr/bin/env python3
"""Exercise missing, stale, changed and incomplete acceptance evidence."""

import hashlib
import io
import json
import os
import runpy
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

import acceptance
import check as check_tools
import evidence as evidence_tools
import install as installer
import reporting
import swift_binary_producer as swift_producer
from processes import run_logged
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
            "bundle_digest": "bundle",
        }
        self.names = ["native-units.json", "fixture.json", "native-distribution.json"]
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

    def testLicenseChangesInvalidateSourceEvidence(self):
        license_file = self.root / "LICENSE"
        license_file.write_text("original license")
        with patch.object(reporting, "ROOT", self.root):
            before = reporting.source_digest()
            license_file.write_text("updated license")
            self.assertNotEqual(reporting.source_digest(), before)

    def testInstallerDownloadsThePinnedReleaseFromTheMainRepository(self):
        version = "0.1.0"
        base = "https://github.com/swiftpods-org/swiftpods/releases/download/v0.1.0/"
        metadata = {
            "swiftpods_version": version,
            "runtime": {"mode": "external"},
            "build_host": {"architecture": "arm64"},
            "minimum_macos": "13.0",
        }
        payload = io.BytesIO()
        with zipfile.ZipFile(payload, "w") as archive:
            archive.writestr("SwiftPods/compatibility.json", json.dumps(metadata))
            binary = zipfile.ZipInfo("SwiftPods/bin/swiftpods")
            binary.external_attr = 0o100755 << 16
            archive.writestr(binary, "#!/bin/sh\nexit 0\n")
        archive_bytes = payload.getvalue()
        asset = {
            "os": "macos",
            "architecture": "arm64",
            "minimum_macos": "13.0",
            "sha256": hashlib.sha256(archive_bytes).hexdigest(),
            "url": base + "swiftpods-0.1.0-macos-13.0-arm64.zip",
        }
        manifest = json.dumps(
            {"schema_version": 1, "version": version, "assets": [asset]}
        ).encode()
        responses = {base + "release.json": manifest, asset["url"]: archive_bytes}

        def download(url, **_):
            response = io.BytesIO(responses[url])
            response.url = url
            return response

        prefix = self.root / "installed"
        argv = [
            "install.py",
            "--version",
            version,
            "--manifest-sha256",
            hashlib.sha256(manifest).hexdigest(),
            "--prefix",
            str(prefix),
        ]
        with (
            patch("sys.argv", argv),
            patch.object(installer.urllib.request, "urlopen", side_effect=download) as fetch,
            patch.object(installer, "select_asset", return_value=asset),
            patch.object(installer, "verify_distribution"),
        ):
            installer.main()
        self.assertEqual(
            [call.args[0] for call in fetch.call_args_list], list(responses)
        )
        installer.verify_launcher(prefix)

    def testInstallerTreatsMissingMacOSPatchComponentAsZero(self):
        asset = {"os": "macos", "architecture": "arm64", "minimum_macos": "13.0.0"}
        manifest = {"schema_version": 1, "version": "1.0.0", "assets": [asset]}
        self.assertEqual(
            installer.select_asset(
                manifest, "1.0.0", architecture="arm64", macos="13.0"
            ),
            asset,
        )
        with self.assertRaisesRegex(RuntimeError, "No compatible SwiftPods asset"):
            installer.select_asset(
                manifest, "1.0.0", architecture="arm64", macos="12.9.9"
            )

    def testInstallerRejectsMissingReplacedAndRedirectedLaunchers(self):
        prefix = self.root / "installed"
        binary = prefix / "libexec/bin/swiftpods"
        binary.parent.mkdir(parents=True)
        binary.write_text("#!/bin/sh\nexit 0\n")
        binary.chmod(0o755)
        launcher = prefix / "bin/swiftpods"
        launcher.parent.mkdir()
        with self.assertRaisesRegex(RuntimeError, "launcher"):
            installer.verify_launcher(prefix)
        launcher.symlink_to("../libexec/bin/swiftpods")
        installer.verify_launcher(prefix)
        launcher.unlink()
        launcher.write_text("unowned file")
        with self.assertRaisesRegex(RuntimeError, "launcher"):
            installer.verify_launcher(prefix)
        launcher.unlink()
        launcher.symlink_to(self.binary)
        with self.assertRaisesRegex(RuntimeError, "launcher"):
            installer.verify_launcher(prefix)

    def testInstallerArchiveRootCannotCollideWithItsPayloadStaging(self):
        for name in ["prefix", "archive", "SwiftPods"]:
            with self.subTest(root=name):
                archive = self.root / (name + ".zip")
                metadata = {
                    "swiftpods_version": "0.1.0-dev",
                    "runtime": {"mode": "external"},
                    "build_host": {"architecture": "fixture"},
                    "minimum_macos": "13.0",
                }
                with zipfile.ZipFile(archive, "w") as payload:
                    payload.writestr(name + "/compatibility.json", json.dumps(metadata))
                    binary = zipfile.ZipInfo(name + "/bin/swiftpods")
                    binary.external_attr = 0o100755 << 16
                    payload.writestr(binary, "#!/bin/sh\nexit 0\n")
                asset = {
                    "architecture": "fixture",
                    "minimum_macos": "13.0",
                    "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
                }
                manifest = self.root / (name + ".json")
                manifest.write_text(
                    json.dumps(
                        {"schema_version": 1, "version": "0.1.0-dev", "assets": [asset]}
                    )
                )
                prefix = self.root / (name + "-installed")
                argv = [
                    "install.py",
                    "--version",
                    "0.1.0-dev",
                    "--manifest",
                    str(manifest),
                    "--manifest-sha256",
                    hashlib.sha256(manifest.read_bytes()).hexdigest(),
                    "--archive",
                    str(archive),
                    "--prefix",
                    str(prefix),
                ]
                with (
                    patch("sys.argv", argv),
                    patch.object(installer, "select_asset", return_value=asset),
                    patch.object(installer, "verify_distribution"),
                ):
                    installer.main()
                installer.verify_launcher(prefix)
                self.assertTrue((prefix / ".installation.json").is_file())
                self.assertFalse((prefix / "libexec/.installation.json").exists())

    def testSigtermUnwindsTheRunnerAndStopsItsChild(self):
        state = self.root / "sigterm-child.json"
        child = "import json,os,signal,sys,time;signal.signal(signal.SIGINT,signal.SIG_IGN);json.dump({'pid':os.getpid()},open(sys.argv[1],'w'));time.sleep(60)"
        driver = "import sys;from pathlib import Path;sys.path.insert(0,sys.argv[1]);from processes import run_logged;run_logged([sys.executable,'-c',sys.argv[3],sys.argv[4]],Path(sys.argv[2]),Path(sys.argv[2])/'child.log',cancellation_grace=0.1)"
        process = subprocess.Popen(
            [
                sys.executable,
                "-c",
                driver,
                str(Path(reporting.__file__).parent),
                str(self.root),
                child,
                str(state),
            ]
        )

        def cleanup():
            if process.poll() is None:
                process.kill()
            process.wait()
            if state.exists():
                try:
                    os.killpg(json.loads(state.read_text())["pid"], signal.SIGKILL)
                except ProcessLookupError:
                    pass

        self.addCleanup(cleanup)
        deadline = time.monotonic() + 5
        while not state.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(state.is_file())
        process.send_signal(signal.SIGTERM)
        self.assertEqual(process.wait(timeout=5), 128 + signal.SIGTERM)
        with self.assertRaises(ProcessLookupError):
            os.kill(json.loads(state.read_text())["pid"], 0)

    def testEvidenceIndexCannotClaimAnUntestedPayload(self):
        with patch.object(
            evidence_tools, "required_reports", return_value=set(self.names)
        ):
            path, metadata = self.evidence_archive()
            with zipfile.ZipFile(path) as archive:
                files = {name: archive.read(name) for name in archive.namelist()}
            index = json.loads(files["index.json"])
            index["bundles"][0]["bundle_digest"] = "untested-payload"
            metadata["bundle_digest"] = "untested-payload"
            files["index.json"] = json.dumps(index).encode()
            with zipfile.ZipFile(path, "w") as archive:
                for name, data in files.items():
                    archive.writestr(name, data)
            with self.assertRaisesRegex(RuntimeError, "package index"):
                evidence_tools.validate(path, metadata, "manifest")

    def testEvidenceExportChecksPayloadBytesAgainstTheManifest(self):
        bundle = self.root / "payload"
        bundle.mkdir()
        adapter = bundle / "adapter.rb"
        adapter.write_text("puts 'tested'\n")
        files = {"adapter.rb": {"sha256": evidence_tools.digest(adapter.read_bytes())}}
        metadata = {
            "files": files,
            "bundle_digest": evidence_tools.digest(
                json.dumps(files, sort_keys=True).encode()
            ),
        }
        evidence_tools.verify_payload(bundle, metadata)
        adapter.write_text("raise 'changed after tests'\n")
        with self.assertRaisesRegex(RuntimeError, "payload changed"):
            evidence_tools.verify_payload(bundle, metadata)

    def testEvidenceExportRejectsARepackagedAdapter(self):
        bundle = self.root / "Bundle"
        binary = bundle / "bin/swiftpods"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(self.binary.read_bytes())
        self.report["executable"]["path"] = str(binary)
        for name in self.names:
            self.write(name, self.report)
        manifest = {
            "bundle_digest": "changed-adapter",
            "files": {"bin/swiftpods": {"sha256": self.report["executable"]["sha256"]}},
        }
        (bundle / "compatibility.json").write_text(json.dumps(manifest))
        report = dict(self.report, **acceptance.collect(self.names))
        report.update(full=True, apple_integration_omitted=False, stages=[])
        self.write("check.json", report)
        with (
            patch.object(evidence_tools, "ROOT", self.root),
            patch.object(evidence_tools, "source_digest", return_value="source"),
            patch.object(evidence_tools, "contract_digest", return_value="contract"),
            patch.object(evidence_tools, "source_revision", return_value=self.revision),
            patch.object(
                evidence_tools, "required_reports", return_value=set(self.names)
            ),
        ):
            with self.assertRaisesRegex(RuntimeError, "package identity changed"):
                evidence_tools.export(self.root / "repackaged.zip")

    def testBundleArgumentSpellingsSelectPackagedBinaryAndReport(self):
        bundle = self.root / "packaged release"
        binary = bundle / "bin/swiftpods"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"packaged executable")
        expected = {
            "path": str(binary.resolve()),
            "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        }
        scripts = {
            "native_variant_tests.py": "variants",
            "native_configuration_tests.py": "configuration",
            "native_layout_tests.py": "layout",
            "native_ui_tests.py": "ui",
        }
        for arguments in [["--bundle", str(bundle)], ["--bundle=" + str(bundle)]]:
            with (
                self.subTest(arguments=arguments),
                patch.object(sys, "argv", ["fixture.py", *arguments]),
            ):
                self.assertEqual(reporting.binary_identity(), expected)
                for script, name in scripts.items():
                    with patch.object(reporting, "execute") as execute_fixture:
                        runpy.run_path(
                            str(ROOT / "scripts" / script), run_name="__main__"
                        )
                    self.assertEqual(
                        execute_fixture.call_args[0][1],
                        "native-packaged-" + name + ".json",
                    )

    def testMissingBundlePathInvalidatesThePackagedFailureReport(self):
        name = "native-packaged-variants.json"
        for arguments in [["--bundle"], ["--bundle="], ["--bundle", "--other-option"]]:
            self.write(name, self.report)
            with (
                self.subTest(arguments=arguments),
                patch.object(sys, "argv", ["fixture.py", *arguments]),
                patch.object(reporting, "ROOT", self.root),
                patch.object(reporting, "source_digest", return_value="source"),
                patch.object(reporting, "contract_digest", return_value="contract"),
                patch.object(reporting, "source_revision", return_value=self.revision),
                patch.object(
                    reporting,
                    "toolchain_identity",
                    return_value=self.report["toolchain"],
                ),
            ):
                with self.assertRaisesRegex(
                    RuntimeError, "requires a distribution path"
                ):
                    reporting.execute(lambda: self.fail("fixture must not run"), name)
            result = json.loads((self.root / "test-results" / name).read_text())
            self.assertEqual(result["status"], "failed")
            self.assertEqual(result["error"], "--bundle requires a distribution path")

    def testToolchainProbeFailureInvalidatesPreviousPassingReport(self):
        with (
            patch.object(reporting, "ROOT", self.root),
            patch.object(reporting, "source_digest", return_value="source"),
            patch.object(reporting, "contract_digest", return_value="contract"),
            patch.object(reporting, "source_revision", return_value=self.revision),
            patch.object(
                reporting,
                "toolchain_identity",
                side_effect=RuntimeError("missing Ruby"),
            ),
        ):
            with self.assertRaisesRegex(RuntimeError, "missing Ruby"):
                reporting.execute(
                    lambda: self.fail("fixture must not run"), "fixture.json"
                )
        report = json.loads((self.root / "test-results/fixture.json").read_text())
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["error"], "missing Ruby")

    def testMalformedPartialReportDoesNotHideOriginalFixtureFailure(self):
        def failing_fixture():
            (self.root / "test-results/fixture.json").write_text("{incomplete")
            raise RuntimeError("fixture failed")

        with (
            patch.object(reporting, "ROOT", self.root),
            patch.object(reporting, "snapshot_metadata", return_value=self.report),
        ):
            with self.assertRaisesRegex(RuntimeError, "fixture failed"):
                reporting.execute(failing_fixture, "fixture.json")
        report = json.loads((self.root / "test-results/fixture.json").read_text())
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["error"], "fixture failed")

    def testVerificationCancellationStopsRunningCommand(self):
        state = self.root / "running.json"
        cancelled = threading.Event()
        errors = []

        def run():
            try:
                run_logged(
                    [
                        sys.executable,
                        "-c",
                        "import json,os,sys,time;json.dump({'pid':os.getpid()},open(sys.argv[1],'w'));time.sleep(60)",
                        state,
                    ],
                    self.root,
                    self.root / "cancelled.log",
                    cancelled=cancelled,
                )
            except RuntimeError as error:
                errors.append(str(error))

        worker = threading.Thread(target=run)
        worker.start()
        self.addCleanup(worker.join, 5)
        self.addCleanup(cancelled.set)
        deadline = time.monotonic() + 5
        while not state.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(state.is_file(), "Command did not start")
        cancelled.set()
        worker.join(5)
        self.assertFalse(worker.is_alive(), "Cancelled command did not stop")
        self.assertEqual(errors, ["Verification cancelled"])
        with self.assertRaises(ProcessLookupError):
            os.kill(json.loads(state.read_text())["pid"], 0)

    def testNativeRegressionScriptsAreRegisteredAndReportsAreUnique(self):
        registry = json.loads((ROOT / "Profiles/contract.json").read_text())
        suites = registry["suites"]
        self.assertEqual(len(suites), len({suite["id"] for suite in suites}))
        self.assertEqual(len(suites), len({suite["report"] for suite in suites}))
        for suite in suites:
            self.assertTrue((ROOT / suite["script"]).is_file(), suite["script"])
        # Package runners require artifacts/arguments supplied by release checks.
        package_only = {"native_distribution_tests.py", "native_homebrew_tests.py"}
        discovered = {
            "scripts/" + path.name
            for path in (ROOT / "scripts").glob("native_*_tests.py")
            if path.name not in package_only
        }
        registered = {suite["script"] for suite in suites if not suite["reference"]}
        self.assertFalse(discovered - registered, sorted(discovered - registered))

    def testStandardAcceptanceRunsRubyRegressionsBeforeFixtures(self):
        registry = dict(
            self.registry,
            suites=[
                {
                    "script": "fixture.py",
                    "report": "fixture.json",
                    "reference": False,
                    "apple": False,
                }
            ],
        )
        (self.root / "Profiles/contract.json").write_text(json.dumps(registry))
        (self.root / "Profiles/baseline.json").write_text("{}")
        commands = []

        def record(stages, command, report=None, env=None):
            commands.append((command, env))
            if report:
                stages.reports.append(report)

        with (
            patch.object(check_tools, "ROOT", self.root),
            patch.object(check_tools.VerificationStages, "run", record),
            patch.object(check_tools, "select_ruby", return_value=(self.binary, {})),
            patch.object(
                check_tools,
                "collect",
                return_value={
                    "status": "passed",
                    "stable_acceptance": "not_established",
                },
            ),
            patch.object(sys, "argv", ["check.py", "--skip-apple"]),
            patch.dict(
                os.environ, {"RUBYOPT": "untrusted preload", "GEM_HOME": "user gems"}
            ),
        ):
            check_tools.main()
        self.assertEqual(commands[0][0][1], "scripts/bootstrap.py")
        self.assertEqual(commands[1][0][1], "scripts/unit_tests.py")
        self.assertEqual(commands[2][0], [self.binary, "scripts/ruby_adapter_tests.rb"])
        self.assertEqual(commands[3][0][1], "fixture.py")
        self.assertNotIn("RUBYOPT", commands[2][1])
        self.assertNotIn("GEM_HOME", commands[2][1])

    def testStageCancellationAllowsNestedFixtureToStopItsOwnProcessGroup(self):
        state = self.root / "nested.json"
        child = "import json,os,signal,sys,time;signal.signal(signal.SIGINT,signal.SIG_IGN);json.dump({'pid':os.getpid()},open(sys.argv[1],'w'));time.sleep(60)"
        parent = "import sys;from pathlib import Path;sys.path.insert(0,sys.argv[1]);from processes import run_logged;run_logged([sys.executable,'-c',sys.argv[3],sys.argv[4]],Path(sys.argv[2]),Path(sys.argv[2])/'leaf.log')"
        stages = check_tools.VerificationStages()
        errors = []

        def run():
            try:
                stages.run(
                    [
                        sys.executable,
                        "-c",
                        parent,
                        str(Path(reporting.__file__).parent),
                        str(self.root),
                        child,
                        str(state),
                    ]
                )
            except RuntimeError as error:
                errors.append(str(error))

        with patch.object(check_tools, "ROOT", self.root):
            worker = threading.Thread(target=run)
            worker.start()
            self.addCleanup(worker.join, 8)
            self.addCleanup(stages.cancelled.set)
            deadline = time.monotonic() + 5
            while not state.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(state.is_file(), "Nested command did not start")
            stages.cancelled.set()
            worker.join(8)
            self.assertFalse(worker.is_alive(), "Nested fixture did not stop")
        self.assertEqual(errors, ["Verification cancelled"])
        with self.assertRaises(ProcessLookupError):
            os.kill(json.loads(state.read_text())["pid"], 0)
        result = json.loads((self.root / "test-results/check.json").read_text())
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["stages"][0]["error"], "Verification cancelled")

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

    def external_artifact_archive(self, *, include_artifacts=True, stable=True):
        path, _ = self.evidence_archive()
        with zipfile.ZipFile(path) as archive:
            files = {name: archive.read(name) for name in archive.namelist()}
        index = json.loads(files.pop("index.json"))
        report = json.loads(files["acceptance.json"])
        report["external_gates"] = json.loads(self.external_gate().read_text())["gates"]
        report["stable_acceptance"] = "established" if stable else "not_established"
        files["acceptance.json"] = json.dumps(report).encode()
        index["stable_acceptance"] = report["stable_acceptance"]
        if include_artifacts:
            index["external_artifacts"] = evidence_tools.collect_external_artifacts(
                report, files
            )
        index["files"] = {
            name: evidence_tools.digest(data) for name, data in files.items()
        }
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("index.json", json.dumps(index))
            for name, data in files.items():
                archive.writestr(name, data)
        return path

    def testPortableEvidenceIncludesExternalArtifactsIndependentOfRunnerPaths(self):
        with (
            patch.object(evidence_tools, "ROOT", self.root),
            patch.object(
                evidence_tools, "required_reports", return_value=set(self.names)
            ),
        ):
            path = self.external_artifact_archive()
            (self.root / "device.log").unlink()
            result = evidence_tools.validate(path)
            self.assertEqual(result["stable_acceptance"], "established")
            self.assertEqual(len(result["external_artifacts"]), 1)

    def testStablePortableEvidenceRejectsMissingExternalArtifact(self):
        with (
            patch.object(evidence_tools, "ROOT", self.root),
            patch.object(
                evidence_tools, "required_reports", return_value=set(self.names)
            ),
        ):
            path = self.external_artifact_archive(include_artifacts=False)
            with self.assertRaisesRegex(RuntimeError, "external gate artifact"):
                evidence_tools.validate(path)

    def testLegacyNonstableEvidenceRemainsReadableWithoutExternalArtifacts(self):
        with (
            patch.object(evidence_tools, "ROOT", self.root),
            patch.object(
                evidence_tools, "required_reports", return_value=set(self.names)
            ),
        ):
            path = self.external_artifact_archive(include_artifacts=False, stable=False)
            self.assertEqual(
                evidence_tools.validate(path)["stable_acceptance"], "not_established"
            )

    def testChangedExternalArtifactCannotBeExported(self):
        report = {
            "external_gates": json.loads(self.external_gate().read_text())["gates"]
        }
        (self.root / "device.log").write_text("changed")
        with self.assertRaisesRegex(RuntimeError, "External gate evidence changed"):
            evidence_tools.collect_external_artifacts(report, {})


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
