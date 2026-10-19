"""A child PID remains owned until every pending signal has completed."""

import json
import tempfile
from pathlib import Path

from bootstrap import ROOT
from vendor_fixture import run

MODES = [
    "basic",
    "pending",
    "self-wait",
    "self-terminate",
    "duplicate-wait",
    "failed-wait",
    "concurrent-wait",
    "terminate",
]


def run_regressions(fixture, source_root=ROOT):
    with tempfile.TemporaryDirectory(
        prefix="process-lifetime-", dir=fixture.root
    ) as temporary:
        build = Path(temporary)
        for sanitized in [False, True]:
            prefix = "process-lifetime-tsan" if sanitized else "process-lifetime"
            binary = build / prefix
            command = [
                "xcrun",
                "clang",
                "-std=c11",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-mmacosx-version-min=13.0",
                "-g",
                "-O1",
                "-Dkill=fixture_kill",
                "-I",
                source_root / "Sources/ProcessSupport/include",
                source_root / "Sources/ProcessSupport/ProcessSupport.c",
                ROOT / "Tests/Fixtures/ProcessLifetimeFixture.c",
                "-o",
                binary,
            ]
            if sanitized:
                command.append("-fsanitize=thread")
            run(command, ROOT, fixture.root / (prefix + "-build.log"), env=fixture.env)
            environment = dict(fixture.env)
            if sanitized:
                environment["TSAN_OPTIONS"] = (
                    "halt_on_error=0:abort_on_error=0:exitcode=66"
                )
            for mode in ["pending", "concurrent-wait"] if sanitized else MODES:
                text = run(
                    [binary, mode],
                    ROOT,
                    fixture.root / (prefix + "-" + mode + ".log"),
                    env=environment,
                    timeout=10,
                )
                assert "ThreadSanitizer" not in text, text
                result = json.loads(text)
                assert result["mode"] == mode and result["released_signals"] == 0, (
                    result
                )
                if mode in ["pending", "terminate"]:
                    assert result["held"] == 1 and result["completed_early"] == 0, (
                        result
                    )
                (fixture.root / (prefix + "-" + mode + ".json")).write_text(
                    json.dumps(result, indent=2) + "\n"
                )
                fixture.verified.append(
                    "process_pid_lifetime_"
                    + mode
                    + ("_thread_sanitizer" if sanitized else "")
                )
