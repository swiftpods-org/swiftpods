#!/usr/bin/env python3
"""Check the Unity package against the source version and Unity's import rules."""

import json
import re
import unittest

from scripts.support.version import ROOT, source_version

PACKAGE = ROOT / "Unity"


class UnityPackageTests(unittest.TestCase):
    def test_version_matches_the_source_version(self):
        manifest = json.loads((PACKAGE / "package.json").read_text())
        self.assertEqual(manifest["version"], source_version())

    def test_every_asset_has_a_meta_file_with_its_own_guid(self):
        # Unity ignores assets without a .meta file in a package installed from Git.
        guids = []
        for path in sorted(PACKAGE.rglob("*")):
            if path.suffix == ".meta":
                self.assertTrue(path.with_suffix("").exists(), path)
                guids += re.findall(r"^guid: ([0-9a-f]{32})$", path.read_text(), re.M)
            else:
                self.assertTrue(path.with_name(path.name + ".meta").exists(), path)
        self.assertEqual(len(guids), len(set(guids)))
        self.assertEqual(len(guids), len(list(PACKAGE.rglob("*.meta"))))


if __name__ == "__main__":
    unittest.main()
