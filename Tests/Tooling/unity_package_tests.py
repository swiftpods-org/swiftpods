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

    def test_process_arguments_are_not_interpolated_into_one_command_line(self):
        source = (PACKAGE / "Editor" / "SwiftPodsBuild.cs").read_text()
        self.assertIn('GetProperty("ArgumentList")', source)
        self.assertIn("launcherArguments.Select(QuoteArgument)", source)
        self.assertNotIn('$"install --project-directory', source)

    def test_project_file_is_only_modified_by_the_hardened_swift_installer(self):
        source = (PACKAGE / "Editor" / "SwiftPodsBuild.cs").read_text()
        self.assertNotIn("ReadAllText", source)
        self.assertNotIn("WriteAllText", source)
        self.assertNotIn("ReplacePodsPaths", source)

    def test_cli_is_an_explicit_absolute_trust_boundary_with_bounded_execution(self):
        source = (PACKAGE / "Editor" / "SwiftPodsBuild.cs").read_text()
        self.assertIn('Environment.GetEnvironmentVariable("SWIFTPODS")', source)
        self.assertIn("Path.IsPathRooted(configured)", source)
        self.assertNotIn('GetEnvironmentVariable("PATH")', source)
        self.assertIn("MaximumCommandCharacters", source)
        self.assertIn("CommandTimeout", source)
        self.assertIn('new ProcessStartInfo("/usr/bin/python3")', source)
        self.assertIn('"-I", "-c", SessionLauncher, executable', source)
        self.assertIn("os.setsid()", source)
        self.assertIn("os.execv(sys.argv[1], sys.argv[1:])", source)
        self.assertNotIn('new ProcessStartInfo("/bin/sh")', source)
        self.assertIn("proc_listallpids", source)
        self.assertIn("getsid(processId) == sessionId", source)
        self.assertIn("SignalSession(sessionId, SignalTerminate)", source)
        self.assertIn("SignalSession(sessionId, SignalKill)", source)
        self.assertEqual(source.count("Stop(process, outputTask, errorTask);"), 3)
        self.assertNotIn('GetMethod("Kill", new[] { typeof(bool) })', source)
        self.assertIn("process.Kill()", source)
        self.assertIn('GetEnvironmentVariable("SWIFTPODS_ALLOW_EXTERNAL_FILE_LISTS")', source)
        self.assertIn('arguments.Add("--allow-external-file-lists")', source)


if __name__ == "__main__":
    unittest.main()
