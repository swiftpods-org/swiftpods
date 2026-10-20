"""External CRuby selection shared by build and verification scripts."""

import json
import os
import platform
import re
import subprocess
from pathlib import Path


def clean_environment(original):
    return {
        key: value
        for key, value in original.items()
        if not key.startswith(("BUNDLE_", "BUNDLER_", "GEM_"))
        and key
        not in ("RUBYOPT", "RUBYLIB", "RUBYPATH", "RUBYHOME", "RUBYGEMS_GEMDEPS")
    }


def normalized_architecture(value):
    return {
        "aarch64": "arm64",
        "arm64e": "arm64",
        "amd64": "x86_64",
        "x64": "x86_64",
    }.get(value, value)


def select_ruby(profile, original=None):
    original = os.environ if original is None else original
    policy = profile["runtime"]
    explicit = original.get("SWIFTPODS_RUBY")
    if explicit is not None:
        if not explicit.startswith("/"):
            raise RuntimeError("SWIFTPODS_RUBY must be an absolute executable path")
        candidates = [Path(explicit)]
    else:
        candidates = [
            Path(part) / "ruby"
            for part in original.get("PATH", "").split(":")
            if part.startswith("/")
        ] + [
            Path("/usr/bin/ruby"),
            Path("/opt/homebrew/opt/ruby/bin/ruby"),
            Path("/usr/local/opt/ruby/bin/ruby"),
            Path("/opt/homebrew/opt/ruby@3.4/bin/ruby"),
            Path("/usr/local/opt/ruby@3.4/bin/ruby"),
        ]

    def version(value):
        return tuple(int(item) for item in value.split("."))

    requirement = "external CRuby >= " + policy["minimum_version"]
    maximum = policy.get("maximum_version_exclusive")
    if maximum is not None:
        requirement += ", < " + maximum
    abi = policy.get("abi")
    if abi is not None:
        requirement += ", ABI " + abi
    code = "require 'json'; require 'rbconfig'; puts({engine: RUBY_ENGINE, version: RUBY_VERSION, abi: RbConfig::CONFIG.fetch('ruby_version'), architecture: RbConfig::CONFIG.fetch('host_cpu'), platform: RUBY_PLATFORM, library: (RbConfig::CONFIG['ENABLE_SHARED'] == 'yes' ? File.join(RbConfig::CONFIG.fetch('libdir'), RbConfig::CONFIG.fetch('LIBRUBY_SO')) : '')}.to_json)"
    visited = set()
    first_failure = None
    for candidate in candidates:
        if not candidate.is_file() or not os.access(candidate, os.X_OK):
            continue
        ruby = candidate.resolve()
        if ruby in visited:
            continue
        visited.add(ruby)
        try:
            metadata = json.loads(
                subprocess.check_output(
                    [str(ruby), "-e", code], env=clean_environment(original), timeout=30
                )
            )
            selected_version = metadata.get("version", "")
            if (
                metadata.get("engine") != "ruby"
                or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", selected_version)
                or version(selected_version) < version(policy["minimum_version"])
                or (
                    maximum is not None
                    and version(selected_version) >= version(maximum)
                )
                or (abi is not None and metadata.get("abi") != abi)
            ):
                raise RuntimeError(
                    "Requires " + requirement + "; selected " + selected_version
                )
            architecture = normalized_architecture(metadata.get("architecture", ""))
            if architecture != normalized_architecture(platform.machine()):
                raise RuntimeError(
                    "Ruby architecture must match the SwiftPods build host"
                )
            metadata["architecture"] = architecture
            metadata["path"] = str(ruby)
            return ruby, metadata
        except (OSError, ValueError, subprocess.SubprocessError, RuntimeError) as error:
            if explicit is not None:
                raise RuntimeError(str(error)) from error
            if first_failure is None:
                first_failure = error
    if first_failure is not None:
        raise RuntimeError(str(first_failure)) from first_failure
    raise RuntimeError(
        "Install Ruby "
        + policy["minimum_version"]
        + " or newer, or set SWIFTPODS_RUBY explicitly"
    )
