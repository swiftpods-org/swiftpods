#!/usr/bin/env python3
"""Read the SwiftPods version from its only source, the command line's version line."""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VERSION_FILE = "Sources/swiftpods/main.swift"


def parse_version(text):
    match = re.search(
        r'^let version = "([0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?)"$', text, re.M
    )
    if not match:
        raise RuntimeError("No valid version line in " + VERSION_FILE)
    return match.group(1)


def source_version(root=ROOT):
    return parse_version((root / VERSION_FILE).read_text())


if __name__ == "__main__":
    print(source_version())
