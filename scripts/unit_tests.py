#!/usr/bin/env python3
"""Build once, fail on compiler warnings and record the executed Swift corpus."""

import json
import re

from processes import run_logged
from reporting import ROOT, execute


def main():
    command = [
        "swift",
        "test",
        "-Xswiftc",
        "-warnings-as-errors",
        "-Xcc",
        "-Wall",
        "-Xcc",
        "-Wextra",
        "-Xcc",
        "-Werror",
    ]
    log = ROOT / "test-results/native-units.log"
    status = run_logged(command, ROOT, log)
    text = log.read_text(errors="replace")
    if status or re.search(r"(?im)^.*\bwarning:", text):
        raise RuntimeError("Swift build/tests failed; see " + str(log))
    counts = [
        int(value)
        for value in re.findall(r"Executed (\d+) tests?, with 0 failures", text)
    ]
    if not counts:
        raise RuntimeError("No executed Swift test count in " + str(log))
    (ROOT / "test-results/native-units.json").write_text(
        json.dumps(
            {
                "status": "passed",
                "engine": "swift",
                "test_count": max(counts),
                "verified": [
                    "Swift unit corpus with compiler warnings treated as errors"
                ],
                "build_command": command,
                "log": str(log),
            },
            indent=2,
        )
        + "\n"
    )
    print("Passed", max(counts), "Swift tests")


if __name__ == "__main__":
    execute(main, "native-units.json")
