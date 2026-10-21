import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from prepare_integrations import prepare


class IntegrationDistributionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "Profiles").mkdir()
        (self.root / "Profiles/baseline.json").write_text(
            json.dumps({"swiftpods_version": "0.1.0"})
        )
        self.path = self.root / "release.json"
        self.manifest = {
            "schema_version": 1,
            "version": "0.1.0",
            "publishable": True,
            "development": False,
            "runtime_mode": "external",
            "assets": [
                {
                    "architecture": architecture,
                    "minimum_macos": "13.0",
                    "url": f"https://example.org/{architecture}.zip",
                    "sha256": "a" * 64,
                    "notarization": {"status": "Accepted"},
                }
                for architecture in ("arm64", "x86_64")
            ],
        }

    def generate(self):
        self.path.write_text(json.dumps(self.manifest))
        prepare(self.path, self.root)

    def test_binds_fastlane_to_exact_manifest_bytes_and_both_brew_archives(self):
        self.generate()
        pin = json.loads(
            (self.root / "lib/fastlane/plugin/swiftpods/release.json").read_text()
        )
        self.assertEqual(
            pin,
            {
                "version": "0.1.0",
                "manifest_sha256": hashlib.sha256(self.path.read_bytes()).hexdigest(),
            },
        )
        formula = (self.root / "Formula/swiftpods.rb").read_text()
        for asset in self.manifest["assets"]:
            self.assertIn(asset["url"], formula)
            self.assertIn(asset["sha256"], formula)
        self.assertIn('depends_on "ruby"', formula)

    def test_rejects_unpublishable_or_incomplete_releases_before_writing(self):
        for field, value in [
            ("publishable", False),
            ("development", True),
            ("runtime_mode", "embedded"),
            ("assets", self.manifest["assets"][:1]),
        ]:
            original = self.manifest[field]
            self.manifest[field] = value
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                self.generate()
            self.assertFalse((self.root / "Formula").exists())
            self.manifest[field] = original

    def test_rejects_a_stale_release_when_the_profile_has_advanced(self):
        self.manifest["version"] = "0.0.9"
        with self.assertRaisesRegex(RuntimeError, "current profile"):
            self.generate()
        self.assertFalse((self.root / "Formula").exists())


if __name__ == "__main__":
    unittest.main()
