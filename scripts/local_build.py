"""Own local compiler output and fixtures until verification and export finish."""

import os
import subprocess
import tempfile
from contextlib import contextmanager
from pathlib import Path

from processes import run_logged, termination_signals

WORKSPACE_ENV = "SWIFTPODS_CHECK_ROOT"
ROOT = Path(__file__).resolve().parents[1]


def workspace_root():
    value = os.environ.get(WORKSPACE_ENV)
    if not value:
        raise RuntimeError("Local builds require an owned verification workspace")
    return Path(value)


def results_directory():
    directory = workspace_root() / "reports"
    directory.mkdir(exist_ok=True)
    return directory


@contextmanager
def workspace():
    """Subprocesses share their caller's workspace; only its owner removes it."""
    if os.environ.get(WORKSPACE_ENV):
        yield workspace_root()
        return
    with (
        termination_signals(),
        tempfile.TemporaryDirectory(prefix="swiftpods-check-") as temporary,
    ):
        root = Path(temporary)
        tool_temporary = root / "temporary"
        tool_temporary.mkdir()
        previous = {name: os.environ.get(name) for name in (WORKSPACE_ENV, "TMPDIR")}
        os.environ[WORKSPACE_ENV] = str(root)
        os.environ["TMPDIR"] = str(tool_temporary)
        try:
            yield root
        finally:
            for name, value in previous.items():
                if value is None:
                    os.environ.pop(name, None)
                else:
                    os.environ[name] = value


def fixture_directory(prefix):
    # All fixtures survive aggregation/export, then disappear with their owner.
    parent = workspace_root() / "fixtures"
    parent.mkdir(exist_ok=True)
    return Path(tempfile.mkdtemp(prefix=prefix, dir=parent))


def debug_binary():
    return workspace_root() / "build/debug/swiftpods"


def swift_command(action):
    root = workspace_root()
    return [
        "swift",
        action,
        "--scratch-path",
        str(root / "build"),
        "--cache-path",
        str(root / "cache"),
        "--config-path",
        str(root / "configuration"),
        "--security-path",
        str(root / "security"),
        "-Xswiftc",
        "-warnings-as-errors",
        "-Xcc",
        "-Wall",
        "-Xcc",
        "-Wextra",
        "-Xcc",
        "-Werror",
    ]


def prepare_debug():
    """Make an individually invoked CLI suite independent of checkout outputs."""
    from bootstrap import main as bootstrap

    bootstrap()
    log = results_directory() / "local-build.log"
    command = swift_command("build")
    if run_logged(command, ROOT, log):
        raise subprocess.CalledProcessError(1, command)
