"""Regressions for external Ruby selection; run locally, without installing Ruby."""

import json
import platform
import shlex
import tempfile
import unittest
from pathlib import Path

from scripts.support.ruby_runtime import normalized_architecture, select_ruby


class RubyRuntimeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="swiftpods-ruby-selection-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.profile = {"runtime": {"mode": "external", "minimum_version": "2.6.0"}}

    def ruby(self, directory="interpreter", version="2.6.10", prelude="", **values):
        executable = self.root / directory / "ruby"
        executable.parent.mkdir(parents=True, exist_ok=True)
        metadata = {
            "engine": "ruby",
            "version": version,
            "abi": "2.6.0",
            "architecture": platform.machine(),
            "platform": "fixture",
            "library": "",
            **values,
        }
        executable.write_text(
            "#!/bin/sh\n"
            + prelude
            + "printf '%s\\n' "
            + shlex.quote(json.dumps(metadata))
            + "\n"
        )
        executable.chmod(0o755)
        return executable

    def select(self, ruby):
        return select_ruby(self.profile, {"SWIFTPODS_RUBY": str(ruby)})

    def test_ruby_26_and_newer_major_versions_do_not_require_a_fixed_abi(self):
        for version, abi in (
            ("2.6.0", "2.6.0"),
            ("2.6.10", "2.6.0"),
            ("4.0.5", "4.0.0"),
        ):
            with self.subTest(version=version):
                _, metadata = self.select(self.ruby(version=version, abi=abi))
                self.assertEqual(metadata["version"], version)

    def test_explicit_old_or_malformed_versions_are_rejected(self):
        for version in ("2.5.9", "2.6", "2.6.0\n", "unknown"):
            with self.subTest(version=version), self.assertRaisesRegex(
                RuntimeError, "Requires external CRuby"
            ):
                self.select(self.ruby(version=version))

    def test_old_profiles_still_enforce_their_explicit_upper_bound_and_abi(self):
        self.profile["runtime"].update(
            minimum_version="3.4.11", maximum_version_exclusive="3.5.0", abi="3.4.0"
        )
        self.select(self.ruby(version="3.4.11", abi="3.4.0"))
        for version, abi in (("3.5.0", "3.4.0"), ("3.4.11", "2.6.0")):
            with self.subTest(version=version, abi=abi), self.assertRaises(
                RuntimeError
            ):
                self.select(self.ruby(version=version, abi=abi))

    def test_path_order_is_respected_and_incompatible_interpreters_are_skipped(self):
        first = self.ruby(directory="first", version="2.5.9")
        second = self.ruby(directory="second")
        third = self.ruby(directory="third", version="4.0.5")
        selected, _ = select_ruby(
            self.profile,
            {"PATH": ":".join(str(path.parent) for path in (first, second, third))},
        )
        self.assertEqual(selected, second.resolve())

    def test_bad_explicit_ruby_never_falls_back_to_path(self):
        rejected = self.ruby(directory="explicit", version="2.5.9")
        fallback = self.ruby(directory="fallback")
        with self.assertRaisesRegex(RuntimeError, "selected 2.5.9"):
            select_ruby(
                self.profile,
                {"SWIFTPODS_RUBY": str(rejected), "PATH": str(fallback.parent)},
            )

    def test_architecture_aliases_are_accepted_and_foreign_architectures_are_rejected(
        self,
    ):
        architecture = normalized_architecture(platform.machine())
        alias = "aarch64" if architecture == "arm64" else "amd64"
        _, metadata = self.select(self.ruby(architecture=alias))
        self.assertEqual(metadata["architecture"], architecture)
        with self.assertRaisesRegex(RuntimeError, "architecture"):
            self.select(self.ruby(architecture="wrong-arch"))

    def test_bundler_and_ruby_environment_does_not_reach_the_probe(self):
        prelude = '[ -z "${BUNDLER_SETUP+x}${BUNDLE_GEMFILE+x}${GEM_HOME+x}${RUBYOPT+x}" ] || exit 21\n'
        ruby = self.ruby(prelude=prelude)
        selected, _ = select_ruby(
            self.profile,
            {
                "SWIFTPODS_RUBY": str(ruby),
                "BUNDLER_SETUP": "/missing/setup.rb",
                "BUNDLE_GEMFILE": "/missing/Gemfile",
                "GEM_HOME": "/missing/gems",
                "RUBYOPT": "-rmissing",
            },
        )
        self.assertEqual(selected, ruby.resolve())

    def test_explicit_relative_and_missing_paths_fail(self):
        for path in ("relative/ruby", str(self.root / "missing/ruby")):
            with self.subTest(path=path), self.assertRaises(RuntimeError):
                select_ruby(self.profile, {"SWIFTPODS_RUBY": path})


if __name__ == "__main__":
    unittest.main()
