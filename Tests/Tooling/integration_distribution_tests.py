import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from scripts.prepare_integrations import prepare


class IntegrationDistributionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        source = self.root / "Sources/swiftpods/main.swift"
        source.parent.mkdir(parents=True)
        source.write_text('let version = "0.2.0"\n')
        self.path = self.root / "release.json"
        self.manifest = {
            "schema_version": 2,
            "version": "0.2.0",
            "publishable": True,
            "development": False,
            "assets": [
                {
                    "architecture": architecture,
                    "minimum_macos": "13.0",
                    "url": f"https://example.org/{architecture}.zip",
                    "sha256": architecture[0] * 64,
                    "notarization": {"status": "Accepted"},
                }
                for architecture in ("arm64", "x86_64")
            ],
        }

    def generate(self):
        self.path.write_text(json.dumps(self.manifest))
        prepare(self.path, self.root)

    def test_formula_pins_both_archives_without_ruby(self):
        self.generate()
        formula = (self.root / "Formula/swiftpods.rb").read_text()
        for asset in self.manifest["assets"]:
            self.assertIn(asset["url"], formula)
            self.assertIn(asset["sha256"], formula)
        self.assertIn('version "0.2.0"', formula)
        self.assertIn('bin.install "bin/swiftpods"', formula)
        self.assertNotIn("ruby", formula.lower())
        self.assertNotIn("SWIFTPODS_", formula)
        self.assertEqual(
            sorted(path.name for path in self.root.rglob("*.rb")), ["swiftpods.rb"]
        )

    def test_plugin_pins_the_release_manifest(self):
        self.generate()
        pin = json.loads((self.root / "lib/fastlane/plugin/swiftpods/release.json").read_text())
        self.assertEqual(
            pin,
            {"version": "0.2.0", "manifest_sha256": hashlib.sha256(self.path.read_bytes()).hexdigest()},
        )

    def test_rejects_unpublishable_or_incomplete_releases_before_writing(self):
        unnotarized = [
            dict(asset, notarization=None) for asset in self.manifest["assets"]
        ]
        for field, value in [
            ("schema_version", 1),
            ("publishable", False),
            ("development", True),
            ("assets", self.manifest["assets"][:1]),
            ("assets", unnotarized),
        ]:
            original = self.manifest[field]
            self.manifest[field] = value
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                self.generate()
            self.assertFalse((self.root / "Formula").exists())
            self.manifest[field] = original

    def test_rejects_a_stale_release_when_the_source_version_has_advanced(self):
        self.manifest["version"] = "0.1.0"
        with self.assertRaisesRegex(RuntimeError, "current source version"):
            self.generate()
        self.assertFalse((self.root / "Formula").exists())


if __name__ == "__main__":
    unittest.main()
