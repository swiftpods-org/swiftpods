#!/usr/bin/env python3
"""Prepare frozen, test-only gems independently of the production adapter."""

import argparse
import os
import subprocess
from pathlib import Path

from bootstrap import PROFILE, ROOT
from ruby_runtime import clean_environment, select_ruby


def prepare(home):
    home = home.resolve()
    home.mkdir(parents=True, exist_ok=True)
    ruby, _ = select_ruby(PROFILE)
    env = clean_environment(os.environ)
    env.update(
        GEM_HOME=str(home),
        GEM_PATH=str(home),
        BUNDLE_GEMFILE=str(ROOT / "Tests/Reference/Gemfile"),
        BUNDLE_FROZEN="true",
        BUNDLE_IGNORE_CONFIG="true",
        BUNDLE_APP_CONFIG=str(home / "bundle-config"),
        BUNDLE_WITHOUT="test",
        BUNDLER_VERSION="2.6.9",
    )
    bundle = home / "gems/bundler-2.6.9/exe/bundle"
    if not bundle.is_file():
        subprocess.run(
            [
                str(ruby),
                "-S",
                "gem",
                "install",
                "bundler",
                "--version",
                "2.6.9",
                "--install-dir",
                str(home),
                "--no-document",
            ],
            env=env,
            cwd=ROOT,
            check=True,
        )
    check = subprocess.run(
        [str(ruby), str(bundle), "check"],
        env=env,
        cwd=ROOT / "Tests/Reference",
        capture_output=True,
    )
    if check.returncode:
        subprocess.run(
            [str(ruby), str(bundle), "install", "--jobs", "4"],
            env=env,
            cwd=ROOT / "Tests/Reference",
            check=True,
        )
    observed = subprocess.check_output(
        [
            str(ruby),
            "-e",
            "require 'bundler/setup';require 'cocoapods';abort('Reference version mismatch') unless Pod::VERSION == '1.17.0';puts Pod::VERSION",
        ],
        env=env,
        cwd=ROOT,
        text=True,
    ).strip()
    if observed != "1.17.0":
        raise RuntimeError("Unexpected reference output")
    return home


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gem-home", type=Path, required=True)
    print(prepare(parser.parse_args().gem_home))
