#!/usr/bin/env python3
"""Regress pinned installation: checksums, archive safety and version verification."""

import contextlib
import hashlib
import io
import json
import shutil
import stat
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from scripts import install as installer

BASE = "https://github.com/swiftpods-org/swiftpods/releases/download/v0.2.0/"


def archive_bytes(version="0.2.0", root="SwiftPods", extra=()):
    payload = io.BytesIO()
    with zipfile.ZipFile(payload, "w") as archive:
        binary = zipfile.ZipInfo(root + "/bin/swiftpods")
        binary.external_attr = 0o100755 << 16
        archive.writestr(
            binary, "#!/bin/sh\necho '" + json.dumps({"version": version}) + "'\n"
        )
        archive.writestr(root + "/LICENSE", "MIT\n")
        for member, contents in extra:
            archive.writestr(member, contents)
    return payload.getvalue()


class InstallTests(unittest.TestCase):
    def setUp(self):
        owner = tempfile.TemporaryDirectory(prefix="swiftpods-install-test-")
        self.addCleanup(owner.cleanup)
        self.root = Path(owner.name)
        self.prefix = self.root / "installed"

    def manifest(self, data):
        return {
            "schema_version": 2,
            "version": "0.2.0",
            "development": False,
            "publishable": True,
            "assets": [
                {
                    "os": "macos",
                    "architecture": "arm64",
                    "minimum_macos": "13.0",
                    "sha256": hashlib.sha256(data).hexdigest(),
                    "url": BASE + "swiftpods-0.2.0-macos-13.0-arm64.zip",
                }
            ],
        }

    def install_local(self, data, manifest=None):
        archive = self.root / "archive.zip"
        archive.write_bytes(data)
        path = self.root / "release.json"
        path.write_text(json.dumps(manifest or self.manifest(data)))
        argv = [
            "install.py",
            "--version",
            "0.2.0",
            "--manifest",
            str(path),
            "--manifest-sha256",
            hashlib.sha256(path.read_bytes()).hexdigest(),
            "--archive",
            str(archive),
            "--prefix",
            str(self.prefix),
        ]
        with (
            patch("sys.argv", argv),
            patch.object(installer.platform, "machine", return_value="arm64"),
            patch.object(installer.platform, "mac_ver", return_value=("15.0", "", "")),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            installer.main()

    def test_downloads_the_pinned_release_from_the_main_repository(self):
        data = archive_bytes()
        manifest = self.manifest(data)
        encoded = json.dumps(manifest).encode()
        responses = {BASE + "release.json": encoded, manifest["assets"][0]["url"]: data}

        def download(url, **_):
            response = io.BytesIO(responses[url])
            response.url = url
            return response

        argv = [
            "install.py",
            "--version",
            "0.2.0",
            "--manifest-sha256",
            hashlib.sha256(encoded).hexdigest(),
            "--prefix",
            str(self.prefix),
        ]
        with (
            patch("sys.argv", argv),
            patch.object(
                installer.urllib.request, "urlopen", side_effect=download
            ) as fetch,
            patch.object(installer, "select_asset", return_value=manifest["assets"][0]),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            installer.main()
        self.assertEqual(
            [call.args[0] for call in fetch.call_args_list], list(responses)
        )
        self.assertTrue((self.prefix / "bin/swiftpods").is_file())
        self.assertFalse((self.prefix / "bin/swiftpods").is_symlink())
        self.assertEqual(
            json.loads((self.prefix / ".installation.json").read_text())[
                "archive_sha256"
            ],
            manifest["assets"][0]["sha256"],
        )

    def test_rejects_unpublishable_remote_manifests_before_selecting_an_archive(self):
        argv = [
            "install.py",
            "--version",
            "0.2.0",
            "--manifest-sha256",
            "a" * 64,
            "--prefix",
            str(self.prefix),
        ]
        for development, publishable in ((True, False), (False, False), (None, True)):
            manifest = {"development": development, "publishable": publishable}
            with (
                self.subTest(development=development, publishable=publishable),
                patch("sys.argv", argv),
                patch.object(
                    installer,
                    "checked_bytes",
                    return_value=json.dumps(manifest).encode(),
                ),
                patch.object(installer, "select_asset") as select,
                self.assertRaisesRegex(RuntimeError, "not a publishable"),
            ):
                installer.main()
            select.assert_not_called()

    def test_rejects_a_manifest_of_another_schema(self):
        manifest = self.manifest(b"")
        manifest["schema_version"] = 1
        with self.assertRaisesRegex(RuntimeError, "schema/version mismatch"):
            installer.select_asset(
                manifest, "0.2.0", architecture="arm64", macos="15.0"
            )

    def test_treats_a_missing_macos_patch_component_as_zero(self):
        manifest = self.manifest(b"")
        asset = dict(manifest["assets"][0], minimum_macos="13.0.0")
        manifest["assets"] = [asset]
        self.assertEqual(
            installer.select_asset(
                manifest, "0.2.0", architecture="arm64", macos="13.0"
            ),
            asset,
        )
        with self.assertRaisesRegex(RuntimeError, "No compatible SwiftPods asset"):
            installer.select_asset(
                manifest, "0.2.0", architecture="arm64", macos="12.9.9"
            )

    def test_executable_reporting_another_version_is_not_installed(self):
        with self.assertRaisesRegex(RuntimeError, "version differs"):
            self.install_local(archive_bytes(version="0.1.0"))
        self.assertFalse(self.prefix.exists())
        self.assertEqual(
            sorted(path.name for path in self.root.iterdir()),
            ["archive.zip", "release.json"],
        )

    def test_archive_root_may_use_any_name(self):
        for name in ["prefix", "archive", "installed"]:
            with self.subTest(root=name):
                self.install_local(archive_bytes(root=name))
                self.assertTrue((self.prefix / "bin/swiftpods").is_file())
                self.assertTrue((self.prefix / ".installation.json").is_file())
                shutil.rmtree(self.prefix)

    def test_repeated_installation_accepts_only_the_same_release(self):
        data = archive_bytes()
        self.install_local(data)
        self.install_local(data)
        other = archive_bytes(extra=[("SwiftPods/README.md", "changed\n")])
        with self.assertRaisesRegex(RuntimeError, "not this exact release"):
            self.install_local(other)
        (self.prefix / "bin/swiftpods").write_text("#!/bin/sh\necho '{}'\n")
        with self.assertRaisesRegex(RuntimeError, "version differs"):
            self.install_local(data)

    def test_unsafe_archive_members_are_rejected(self):
        for name, extra in [
            ("parent", [("SwiftPods/../escape", "x")]),
            ("absolute", [("/escape", "x")]),
            ("second root", [("Other/file", "x")]),
        ]:
            with (
                self.subTest(name),
                tempfile.TemporaryDirectory(dir=self.root) as staging,
            ):
                with self.assertRaises(RuntimeError):
                    installer.extract_archive(archive_bytes(extra=extra), Path(staging))

    def test_escaping_symlinks_are_rejected(self):
        payload = io.BytesIO()
        with zipfile.ZipFile(payload, "w") as archive:
            link = zipfile.ZipInfo("SwiftPods/bin/swiftpods")
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(link, "../../../outside")
        with tempfile.TemporaryDirectory(dir=self.root) as staging:
            with self.assertRaisesRegex(RuntimeError, "symlink"):
                installer.extract_archive(payload.getvalue(), Path(staging))


if __name__ == "__main__":
    unittest.main()
