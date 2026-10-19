"""Run verification commands with ownership of their process groups and logs."""

import os
import signal
import subprocess
import threading
import time
from contextlib import contextmanager


@contextmanager
def termination_signals():
    """Let SIGTERM unwind owned processes, including threaded fixture runners."""
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
def run_captured(arguments, cwd, log_prefix, env=None, timeout=None):
    """Keep separate durable streams and cancel the owned group on any interruption."""
    command = [str(argument) for argument in arguments]
    stdout = log_prefix.with_name(log_prefix.name + ".stdout.log")
    stderr = log_prefix.with_name(log_prefix.name + ".stderr.log")
    with stdout.open("wb") as output, stderr.open("wb") as error:
        process = subprocess.Popen(
            command,
            cwd=cwd,
            env=env,
            stdout=output,
            stderr=error,
            start_new_session=True,
        )
        try:
            status = process.wait(timeout=timeout)
        except BaseException:
            cancel_process_group(process)
            raise
    return subprocess.CompletedProcess(
        command, status, stdout.read_text(), stderr.read_text()
    )


@termination_signals()
def run_logged(
    arguments, cwd, log, env=None, timeout=None, cancelled=None, cancellation_grace=2
):
    """Return the exit code; cancellation and timeout always stop the owned group."""
    command = [str(argument) for argument in arguments]
    with log.open("wb") as output:
        if cancelled is not None and cancelled.is_set():
            raise RuntimeError("Verification cancelled before command started")
        process = subprocess.Popen(
            command,
            cwd=cwd,
            env=env,
            stdout=output,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        started = time.monotonic()
        try:
            while True:
                if cancelled is not None and cancelled.is_set():
                    raise RuntimeError("Verification cancelled")
                remaining = (
                    None if timeout is None else timeout - (time.monotonic() - started)
                )
                if remaining is not None and remaining <= 0:
                    raise subprocess.TimeoutExpired(command, timeout)
                try:
                    return process.wait(
                        timeout=min(0.1, remaining) if remaining is not None else 0.1
                    )
                except subprocess.TimeoutExpired:
                    continue
        except BaseException:
            cancel_process_group(process, grace_period=cancellation_grace)
            raise
