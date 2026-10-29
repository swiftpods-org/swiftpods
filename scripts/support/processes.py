"""Run build commands with ownership of their process groups."""

import os
import signal
import subprocess
import threading
from contextlib import contextmanager


@contextmanager
def termination_signals():
    """Let SIGTERM unwind owned processes and their temporary files."""
    installed = (
        threading.current_thread() is threading.main_thread()
        and signal.getsignal(signal.SIGTERM) == signal.SIG_DFL
    )

    def terminate(signum, frame):
        # A repeated termination request must not interrupt descendant cleanup.
        signal.signal(signum, signal.SIG_IGN)
        raise SystemExit(128 + signum)

    if installed:
        signal.signal(signal.SIGTERM, terminate)
    try:
        yield
    finally:
        if installed:
            signal.signal(signal.SIGTERM, signal.SIG_DFL)


def cancel_process_group(process, grace_period=2):
    """Stop descendants even if their immediate parent exits first."""
    try:
        os.killpg(process.pid, signal.SIGINT)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=grace_period)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


@termination_signals()
def run_checked(arguments, *, timeout=None, **options):
    """Run a checked command, stopping its entire process group before unwinding."""
    command = [str(argument) for argument in arguments]
    process = subprocess.Popen(command, start_new_session=True, **options)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
        result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
        result.check_returncode()
        return result
    except BaseException:
        cancel_process_group(process)
        raise
