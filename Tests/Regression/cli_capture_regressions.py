"""Verification captures retain diagnostics and terminate owned children on timeout."""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from scripts.support.processes import run_captured


def run_regressions(fixture):
    with tempfile.TemporaryDirectory(
        prefix="cli-capture-", dir=fixture.root
    ) as temporary:
        parent = Path(temporary)
        success = fixture.root / "cli-capture-success"
        result = run_captured(
            [
                sys.executable,
                "-c",
                "import sys;print('stdout-value');print('stderr-value',file=sys.stderr)",
            ],
            parent,
            success,
            env=fixture.env,
            timeout=10,
        )
        assert (
            result.returncode == 0
            and result.stdout == "stdout-value\n"
            and result.stderr == "stderr-value\n"
        )
        assert (
            success.with_name(success.name + ".stdout.log").read_text() == result.stdout
        )
        assert (
            success.with_name(success.name + ".stderr.log").read_text() == result.stderr
        )
        fixture.verified.append(
            "cli_capture_separates_stdout_stderr_and_keeps_durable_logs"
        )
        failure = fixture.root / "cli-capture-failure"
        result = run_captured(
            [
                sys.executable,
                "-c",
                "import sys;print('expected-failure',file=sys.stderr);sys.exit(17)",
            ],
            parent,
            failure,
            env=fixture.env,
            timeout=10,
        )
        assert result.returncode == 17 and result.stderr == "expected-failure\n"
        fixture.verified.append(
            "cli_capture_preserves_nonzero_child_status_and_diagnostics"
        )
        pidfile = parent / "child-pid"
        stopped = parent / "child-stopped"
        child = (
            "import os,signal,sys,time\nfrom pathlib import Path\n"
            "def stop(signum,frame):\n Path(sys.argv[2]).write_text('SIGINT');sys.exit(0)\n"
            "signal.signal(signal.SIGINT,stop)\nPath(sys.argv[1]).write_text(str(os.getpid()))\n"
            "time.sleep(60)\n"
        )
        script = (
            "import subprocess,sys,time\nfrom pathlib import Path\n"
            "child=subprocess.Popen([sys.executable,'-c',sys.argv[1],sys.argv[2],sys.argv[3]])\n"
            "while not Path(sys.argv[2]).exists():time.sleep(0.01)\n"
            "print('parent-ready',flush=True);print('child-ready',file=sys.stderr,flush=True)\n"
            "try:child.wait()\nexcept KeyboardInterrupt:child.wait(timeout=2)\n"
        )
        prefix = fixture.root / "cli-capture-timeout"
        try:
            run_captured(
                [sys.executable, "-c", script, child, pidfile, stopped],
                parent,
                prefix,
                env=fixture.env,
                timeout=5,
            )
        except subprocess.TimeoutExpired:
            pass
        else:
            raise AssertionError("Expected timeout")
        assert pidfile.exists() and stopped.read_text() == "SIGINT"
        pid = int(pidfile.read_text())
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError("Captured command left its child running")
        assert (
            "parent-ready" in prefix.with_name(prefix.name + ".stdout.log").read_text()
        )
        assert (
            "child-ready" in prefix.with_name(prefix.name + ".stderr.log").read_text()
        )
        (fixture.root / "cli-capture-timeout.json").write_text(
            json.dumps(
                {
                    "timed_out": True,
                    "child_signal": "SIGINT",
                    "child_reaped": True,
                    "partial_streams_preserved": True,
                },
                indent=2,
            )
            + "\n"
        )
        fixture.verified.append(
            "cli_capture_timeout_signals_and_reaps_child_and_preserves_partial_streams"
        )
