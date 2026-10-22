#!/usr/bin/env python3
"""Verify package build isolation and cleanup without invoking the Swift compiler."""

import contextlib
import io
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts import package
from scripts.support import evidence
from scripts.support.local_build import WORKSPACE_ENV, results_directory
from Tests import check


class PackageStorageTests(unittest.TestCase):
    def setUp(self):
        owner = tempfile.TemporaryDirectory(prefix="swiftpods-package-test-")
        self.addCleanup(owner.cleanup)
        self.workspace = Path(owner.name)
        self.root = self.workspace / "source"
        self.temporary = self.workspace / "temporary"
        self.temporary.mkdir()
        for relative, contents in {
            "Runtime/dsl.rb": "# native adapter\n",
            "README.md": "SwiftPods\n",
            "LICENSE": "MIT\n",
            "docs/Installation.md": "Installation\n",
            "Sources/ProcessSupport/ArchiveHeaders/LICENSE.txt": "Archive license\n",
        }.items():
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents)
        self.version = "0.1.0"
        self.build_error = None
        self.build_count = 0
        self.original_run = package.run_checked
        self.enterContext(patch.object(package, "ROOT", self.root))
        self.enterContext(patch.object(package, "PROFILE", {"swiftpods_version": self.version}))
        self.enterContext(patch.object(package.tempfile, "tempdir", str(self.temporary)))
        self.enterContext(patch.dict(os.environ, TMPDIR=str(self.temporary)))
        self.enterContext(patch.object(package, "environment", lambda destination: {}))
        self.enterContext(patch.object(package, "manifest", self.write_manifest))
        self.builder = self.enterContext(patch.object(package, "run_checked", side_effect=self.build))

    def write_manifest(self, destination):
        # SDK tools can leave their own temporary directories behind.
        temporary = Path(tempfile.mkdtemp(prefix="sdk-tool-", dir=os.environ["TMPDIR"]))
        (temporary / "intermediate").write_text("temporary\n")
        (destination / "compatibility.json").write_text("{}\n")

    def build(self, arguments, **options):
        if arguments[:2] != ["swift", "build"]:
            return self.original_run(arguments, **options)
        if "--show-bin-path" in arguments:
            scratch = Path(arguments[arguments.index("--scratch-path") + 1])
            return subprocess.CompletedProcess(arguments, 0, str(scratch / "release") + "\n")
        self.build_count += 1
        scratch = Path(arguments[arguments.index("--scratch-path") + 1])
        self.assertTrue(scratch.is_relative_to(self.temporary))
        build_temporary = Path(options['env']['TMPDIR'])
        self.assertTrue(build_temporary.is_relative_to(self.temporary))
        (build_temporary / 'compiler-temporary-file').write_text('temporary\n')
        for option in ('--cache-path', '--config-path', '--security-path'):
            directory = Path(arguments[arguments.index(option) + 1])
            self.assertTrue(directory.is_relative_to(self.temporary))
            directory.mkdir()
            (directory / 'compiler-metadata').write_text('temporary\n')
        binary = scratch / "release/swiftpods"
        binary.parent.mkdir(parents=True)
        binary.write_text(
            f"#!{sys.executable}\nimport json\n"
            f"print(json.dumps({{'swiftpods_version': {self.version!r}}}))\n"
        )
        binary.chmod(0o700)
        if self.build_error:
            raise self.build_error

    def run_package(self, *arguments):
        output = io.StringIO()
        with patch.object(sys, "argv", ["package.py", *map(str, arguments)]):
            with contextlib.redirect_stdout(output):
                package.main()
        return output.getvalue()

    def assert_clean(self):
        self.assertEqual(list(self.temporary.iterdir()), [])
        self.assertFalse((self.root / "dist").exists())
        self.assertFalse((self.root / ".build").exists())
        self.assertFalse((self.root / ".runtime").exists())
        self.assertEqual(os.environ.get("TMPDIR"), str(self.temporary))

    def test_default_build_verifies_the_package_and_removes_all_output(self):
        output = self.run_package()
        self.assertIn("Package verified", output)
        self.assertEqual(self.build_count, 1)
        self.assert_clean()

    def test_explicit_export_keeps_only_the_requested_package(self):
        destination = self.workspace / "export/SwiftPods"
        self.run_package("--destination", destination)
        self.assertEqual((destination / "host/dsl.rb").read_text(), "# native adapter\n")
        self.assertTrue((destination / "bin/swiftpods").is_file())
        self.assertEqual(list(destination.parent.iterdir()), [destination])
        self.assert_clean()

    def test_failed_build_removes_partial_compiler_output(self):
        self.build_error = subprocess.CalledProcessError(1, ["swift", "build"])
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_package()
        self.assert_clean()

    def test_interrupted_build_removes_partial_compiler_output(self):
        self.build_error = SystemExit(143)
        with self.assertRaises(SystemExit):
            self.run_package()
        self.assert_clean()

    def test_version_verification_failure_cleans_staging_without_exporting(self):
        self.version = "9.9.9"
        destination = self.workspace / "export/SwiftPods"
        with self.assertRaisesRegex(RuntimeError, "version differs"):
            self.run_package("--destination", destination)
        self.assertFalse(destination.exists())
        self.assertEqual(list(destination.parent.iterdir()), [])
        self.assert_clean()

    def test_existing_destination_is_preserved_without_building(self):
        destination = self.workspace / "existing"
        destination.mkdir()
        marker = destination / "keep.txt"
        marker.write_text("user data\n")
        with self.assertRaisesRegex(RuntimeError, "Destination exists"):
            self.run_package("--destination", destination)
        self.assertEqual(marker.read_text(), "user data\n")
        self.builder.assert_not_called()
        self.assert_clean()


class PackageCancellationTests(unittest.TestCase):
    def test_sigterm_stops_compiler_descendants_before_removing_temporary_files(self):
        with tempfile.TemporaryDirectory(prefix="swiftpods-package-cancel-") as owner:
            root = Path(owner)
            tools = root / "tools"
            tools.mkdir()
            state = root / "descendant.json"
            compiler = tools / "swift"
            child = (
                "import json, os, signal, time; "
                "signal.signal(signal.SIGINT, signal.SIG_IGN); "
                "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                "open(os.environ['COMPILER_STATE'] + '.pending', 'w').write(json.dumps("
                "{'pid': os.getpid(), 'temporary': os.environ['TMPDIR']})); "
                "os.replace(os.environ['COMPILER_STATE'] + '.pending', os.environ['COMPILER_STATE']); "
                "time.sleep(60)"
            )
            compiler.write_text(
                f"#!{sys.executable}\nimport subprocess, sys\n"
                f"subprocess.Popen([sys.executable, '-c', {child!r}]).wait()\n"
            )
            compiler.chmod(0o700)
            env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'],
                       COMPILER_STATE=str(state), PYTHONDONTWRITEBYTECODE='1')
            descendant = None
            with (root / "package.log").open("wb") as log:
                process = subprocess.Popen(
                    [sys.executable, "-m", "scripts.package"], cwd=package.ROOT,
                    env=env, stdout=log, stderr=log, start_new_session=True,
                )
                try:
                    deadline = time.monotonic() + 15
                    while not state.exists() and time.monotonic() < deadline:
                        if process.poll() is not None:
                            self.fail((root / "package.log").read_text())
                        time.sleep(0.02)
                    self.assertTrue(state.exists(), "Compiler did not spawn its descendant")
                    descendant = json.loads(state.read_text())
                    process.send_signal(signal.SIGTERM)
                    self.assertEqual(process.wait(timeout=10), 143)
                    status = subprocess.run(
                        ['ps', '-o', 'stat=', '-p', str(descendant['pid'])],
                        capture_output=True, text=True, check=False,
                    ).stdout.strip()
                    self.assertTrue(not status or status.startswith('Z'), status)
                    self.assertFalse(Path(descendant['temporary']).exists())
                finally:
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait()
                    if descendant:
                        try:
                            os.kill(descendant['pid'], signal.SIGKILL)
                        except ProcessLookupError:
                            pass


class PackageCheckStorageTests(unittest.TestCase):
    def test_check_keeps_the_package_until_evidence_is_exported(self):
        self.check_storage(failure=None)

    def test_failed_check_removes_the_built_package(self):
        self.check_storage(failure="check")

    def test_failed_evidence_export_removes_the_built_package(self):
        self.check_storage(failure="export")

    def test_explicit_evidence_export_survives_temporary_cleanup(self):
        self.check_storage(failure=None, export_evidence=True)

    def check_storage(self, failure, export_evidence=False):
        with tempfile.TemporaryDirectory(prefix="swiftpods-check-test-") as owner:
            owner = Path(owner)
            transient = owner / "temporary"
            transient.mkdir()
            root = owner / "source"
            report = None
            archive = owner / "evidence.zip"
            built = None
            exported = False

            def main(workspace):
                nonlocal built, report
                report = results_directory() / "check.json"
                report.write_text('{"status": "passed"}\n')
                built = workspace / "SwiftPods"
                self.assertTrue(built.is_relative_to(transient))
                built.mkdir()
                (built / "artifact").write_text("package\n")
                if failure == "check":
                    raise RuntimeError("verification failed")

            def execute(callback, name):
                callback()
                self.assertTrue((built / "artifact").is_file())

            def export(destination):
                nonlocal exported
                self.assertTrue((built / "artifact").is_file())
                if failure == "export":
                    raise RuntimeError("export failed")
                if export_evidence:
                    self.assertEqual(destination, archive.resolve())
                    destination.write_bytes(b"exported evidence")
                exported = True

            with contextlib.ExitStack() as patches:
                patches.enter_context(patch.dict(os.environ))
                os.environ.pop(WORKSPACE_ENV, None)
                patches.enter_context(patch.object(tempfile, "tempdir", str(transient)))
                patches.enter_context(patch.object(check, "ROOT", root))
                patches.enter_context(patch.object(check, "main", main))
                patches.enter_context(patch.object(check, "execute", execute))
                patches.enter_context(patch.object(evidence, "export", export))
                patches.enter_context(patch.object(sys, "argv", ["check.py", "--full", "--package"] + (["--evidence-destination", str(archive)] if export_evidence else [])))
                if failure:
                    with self.assertRaises(RuntimeError):
                        check.run_checks()
                else:
                    check.run_checks()
            self.assertIsNotNone(built)
            self.assertFalse(built.exists())
            self.assertEqual(list(transient.iterdir()), [])
            self.assertEqual(exported, failure is None)
            self.assertFalse(report.exists())
            self.assertEqual(archive.exists(), export_evidence)


if __name__ == "__main__":
    unittest.main()
