#!/usr/bin/env python3
"""Check shared temporary builds, report cleanup, and cancellation."""

import contextlib
import io
import json
import os
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import bootstrap
import local_build
import reporting


class WorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.enterContext(patch.dict(os.environ))
        os.environ.pop(local_build.WORKSPACE_ENV, None)

    def test_child_outputs_survive_until_the_parent_finishes_exporting(self):
        previous = os.environ.get("TMPDIR")
        with local_build.workspace() as root:
            result = subprocess.check_output(
                [
                    sys.executable,
                    "-c",
                    """
import json, os
from local_build import workspace, fixture_directory, debug_binary, results_directory
with workspace() as root:
    fixture = fixture_directory('child-')
    (fixture / 'result.log').write_text('passed')
    print(json.dumps([str(root), str(fixture), str(debug_binary()), os.environ['TMPDIR'], str(results_directory())]))
""",
                ],
                cwd=Path(__file__).parent,
                text=True,
            )
            child_root, fixture, binary, temporary, reports = map(
                Path, json.loads(result)
            )
            self.assertEqual(root, child_root)
            self.assertEqual((fixture / "result.log").read_text(), "passed")
            self.assertTrue(binary.is_relative_to(root))
            self.assertTrue(temporary.is_relative_to(root))
            self.assertTrue(reports.is_relative_to(root))
            self.assertEqual(reports, local_build.results_directory())
            with local_build.workspace() as nested:
                self.assertEqual(nested, root)
            self.assertTrue(fixture.exists())
        self.assertFalse(root.exists())
        self.assertEqual(os.environ.get("TMPDIR"), previous)
        self.assertNotIn(local_build.WORKSPACE_ENV, os.environ)

    def test_failure_cleans_partial_builds_and_restores_environment(self):
        previous = os.environ.get("TMPDIR")
        with self.assertRaisesRegex(RuntimeError, "compile failed"):
            with local_build.workspace() as root:
                local_build.fixture_directory("failed-").joinpath("output").write_bytes(
                    b"partial"
                )
                raise RuntimeError("compile failed")
        self.assertFalse(root.exists())
        self.assertEqual(os.environ.get("TMPDIR"), previous)
        self.assertNotIn(local_build.WORKSPACE_ENV, os.environ)

    def test_termination_unwinds_and_removes_the_workspace(self):
        process = subprocess.Popen(
            [
                sys.executable,
                "-c",
                """
import signal
from local_build import workspace, fixture_directory, results_directory
with workspace() as root:
    (results_directory() / 'partial.json').write_text('{}')
    fixture_directory('interrupted-').joinpath('partial').write_text('partial')
    print(root, flush=True)
    signal.pause()
""",
            ],
            cwd=Path(__file__).parent,
            stdout=subprocess.PIPE,
            text=True,
        )
        try:
            root = Path(process.stdout.readline().strip())
            self.assertTrue(root.is_dir())
            process.send_signal(signal.SIGTERM)
            self.assertEqual(process.wait(timeout=10), 143)
            self.assertFalse(root.exists())
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdout.close()

    def test_build_and_test_use_the_same_owned_scratch_and_compiler_caches(self):
        with local_build.workspace() as root:
            for action in ("build", "test"):
                command = local_build.swift_command(action)
                for option in (
                    "--scratch-path",
                    "--cache-path",
                    "--config-path",
                    "--security-path",
                ):
                    self.assertTrue(
                        Path(command[command.index(option) + 1]).is_relative_to(root)
                    )
                self.assertIn("-warnings-as-errors", command)
            self.assertTrue(local_build.debug_binary().is_relative_to(root))

    def test_repeated_bootstrap_removes_backups_and_preserves_prior_runtime_on_failure(
        self,
    ):
        with local_build.workspace() as root:
            with (
                patch.object(bootstrap, "select_ruby"),
                patch.object(bootstrap, "manifest"),
            ):
                bootstrap.main()
                prefix = bootstrap.runtime_prefix()
                marker = prefix / "previous-marker"
                marker.write_text("prior runtime")
                with patch.object(
                    bootstrap, "manifest", side_effect=RuntimeError("manifest failed")
                ):
                    with self.assertRaisesRegex(RuntimeError, "manifest failed"):
                        bootstrap.main()
                self.assertEqual(marker.read_text(), "prior runtime")
                bootstrap.main()
                self.assertFalse(marker.exists())
                self.assertEqual(
                    sorted(p.name for p in root.iterdir()), ["runtime", "temporary"]
                )

    def test_reports_and_fixture_logs_exist_only_until_the_owner_finishes(self):
        with tempfile.TemporaryDirectory() as source:
            source = Path(source)
            with (
                patch.object(reporting, "ROOT", source),
                patch.object(reporting, "snapshot_metadata", return_value={}),
                patch.object(reporting, "verify_snapshot"),
                patch.object(reporting, "binary_identity", return_value=None),
            ):
                with local_build.workspace() as root:
                    reports = local_build.results_directory()
                    fixture = local_build.fixture_directory("logs-")
                    (fixture / "compile.log").write_text("compiler diagnostic")

                    def passed():
                        (reports / "suite.json").write_text(
                            json.dumps({"fixture": str(fixture)})
                        )

                    reporting.execute(passed, "suite.json")
                    report = json.loads((reports / "suite.json").read_text())
                    self.assertEqual(report["status"], "passed")
                    self.assertEqual(Path(report["fixture"]), fixture)
                    self.assertTrue((fixture / "compile.log").exists())
                self.assertFalse(root.exists())
                self.assertEqual(list(source.iterdir()), [])

    def test_failed_suite_prints_diagnostics_then_cleans_reports_and_builds(self):
        with tempfile.TemporaryDirectory() as source:
            source = Path(source)
            root = None
            observed = []
            output = io.StringIO()
            write_report = reporting.write_report

            def record(path, value):
                observed.append(dict(value))
                write_report(path, value)

            def fail():
                nonlocal root
                root = local_build.workspace_root()
                fixture = local_build.fixture_directory("failed-")
                (fixture / "compile.log").write_text("error: compile failed")
                (fixture / "partial.o").write_bytes(b"partial")
                raise RuntimeError("build failed")

            with (
                patch.object(reporting, "ROOT", source),
                patch.object(reporting, "prepare_debug"),
                patch.object(reporting, "snapshot_metadata", return_value={}),
                patch.object(reporting, "write_report", side_effect=record),
                contextlib.redirect_stderr(output),
            ):
                with self.assertRaisesRegex(RuntimeError, "build failed"):
                    reporting.execute(fail, "failed-suite.json")
            self.assertFalse(root.exists())
            self.assertEqual(observed[-1]["status"], "failed")
            self.assertIn("error: compile failed", output.getvalue())
            self.assertEqual(list(source.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
