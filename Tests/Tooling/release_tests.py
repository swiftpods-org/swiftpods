#!/usr/bin/env python3
"""Regress release signing, preparation, notarization binding and publication."""

import contextlib
import hashlib
import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from scripts import publish_release, release, sign_release


def write_version(root, version):
    path = root / "Sources/swiftpods/main.swift"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('import Foundation\n\nlet version = "' + version + '"\n')


def write_archive(path, files):
    with zipfile.ZipFile(path, "w") as archive:
        for name, (contents, mode) in files.items():
            member = zipfile.ZipInfo("SwiftPods/" + name)
            member.external_attr = mode << 16
            archive.writestr(member, contents)


class SigningTests(unittest.TestCase):
    def setUp(self):
        owner = tempfile.TemporaryDirectory(prefix="swiftpods-signing-test-")
        self.addCleanup(owner.cleanup)
        self.root = Path(owner.name)
        write_version(self.root, "0.2.0")
        self.bundle = self.root / "SwiftPods"
        (self.bundle / "bin").mkdir(parents=True)
        (self.bundle / "bin/swiftpods").write_bytes(b"fixture executable")
        self.fingerprint = "A" * 40
        self.identities = (
            f'  1) {self.fingerprint} "Developer ID Application: Fixture (TEAM)"\n'
            "  1 valid identities found\n"
        )
        self.reported = "0.2.0"
        self.enterContext(patch.object(sign_release, "ROOT", self.root))

    def output(self, command, **options):
        if command[:2] == ["git", "status"]:
            return b""
        if command[:2] == ["/usr/bin/security", "find-identity"]:
            return self.identities
        if command[1:] == ["version", "--json"]:
            return json.dumps({"version": self.reported}).encode()
        self.fail("Unexpected signing probe: " + repr(command))

    def sign(self):
        def run(*arguments):
            if arguments[0] == "/usr/bin/ditto":
                Path(arguments[-1]).write_bytes(b"fixture signed archive")

        with (
            patch.object(
                sys,
                "argv",
                ["sign_release.py", str(self.bundle), "--identity", self.fingerprint],
            ),
            patch.object(
                sign_release.subprocess, "check_output", side_effect=self.output
            ),
            patch.object(sign_release, "run", side_effect=run) as commands,
            contextlib.redirect_stdout(io.StringIO()),
        ):
            sign_release.main()
        return [call.args for call in commands.call_args_list]

    def test_signs_the_executable_with_the_selected_identity_before_archiving(self):
        sign, verify, archive = self.sign()
        self.assertEqual(sign[:2], ("/usr/bin/codesign", "--force"))
        self.assertEqual(sign[sign.index("--sign") + 1], self.fingerprint)
        self.assertIn("runtime", sign)
        self.assertEqual(sign[-1], self.bundle.resolve() / "bin/swiftpods")
        self.assertEqual(verify[:3], ("/usr/bin/codesign", "--verify", "--strict"))
        self.assertEqual(archive[0], "/usr/bin/ditto")
        checksum = hashlib.sha256(b"fixture signed archive").hexdigest()
        self.assertEqual(
            (self.root / "SwiftPods.zip.sha256").read_text(),
            checksum + "  SwiftPods.zip\n",
        )

    def test_ambiguous_identity_is_rejected_before_signing(self):
        self.identities += self.identities.replace("Fixture", "Other")
        with self.assertRaisesRegex(RuntimeError, "uniquely select"):
            self.sign()
        self.assertFalse((self.root / "SwiftPods.zip").exists())

    def test_signed_executable_must_report_the_source_version(self):
        self.reported = "0.1.0"
        with self.assertRaisesRegex(RuntimeError, "version differs"):
            self.sign()
        self.assertFalse((self.root / "SwiftPods.zip").exists())


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="swiftpods-release-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "scripts").mkdir()
        (self.root / "scripts/install.py").write_text("# installer fixture\n")
        write_version(self.root, "0.2.0")
        self.directory = self.root / "release"
        self.directory.mkdir()
        self.commit = "1" * 40
        self.status = b""
        self.metadata = {}
        archives, receipts = [], []
        for architecture in ("arm64", "x86_64"):
            archive = self.root / (architecture + ".zip")
            archive.write_bytes((architecture + " archive").encode())
            archives.append(archive)
            receipt = self.root / (architecture + ".notary.json")
            receipt.write_text(
                json.dumps(
                    {
                        "id": architecture + "-submission",
                        "status": "Accepted",
                        "archive_sha256": hashlib.sha256(
                            archive.read_bytes()
                        ).hexdigest(),
                    }
                )
            )
            receipts.append(receipt)
            self.metadata[archive] = {
                "architecture": architecture,
                "minimum_macos": "13.0",
                "signed_by": "Developer ID Application: Fixture (TEAM)",
            }
        self.args = SimpleNamespace(
            bundle=[],
            archive=archives,
            notarization=receipts,
            version="0.2.0",
            development=False,
        )
        for replacement in (
            patch.object(release, "ROOT", self.root),
            patch.object(
                release, "inspect_archive", side_effect=lambda path: self.metadata[path]
            ),
            patch.object(
                release.subprocess,
                "check_output",
                side_effect=lambda command, **_: (
                    self.status if command[1] == "status" else self.commit
                ),
            ),
        ):
            replacement.start()
            self.addCleanup(replacement.stop)

    def prepare(self):
        with contextlib.redirect_stdout(io.StringIO()):
            release.prepare(self.args, self.directory)
        return json.loads((self.directory / "release.json").read_text())

    def test_notarized_release_is_publishable_without_runtime_or_evidence_fields(self):
        manifest = self.prepare()
        self.assertTrue(manifest["publishable"])
        self.assertEqual(
            set(manifest),
            {
                "schema_version",
                "development",
                "publishable",
                "source_revision",
                "version",
                "assets",
                "installer_sha256",
            },
        )
        self.assertEqual(manifest["source_revision"], {"commit": self.commit})
        self.assertEqual(
            [asset["filename"] for asset in manifest["assets"]],
            [
                "swiftpods-0.2.0-macos-13.0-arm64.zip",
                "swiftpods-0.2.0-macos-13.0-x86_64.zip",
            ],
        )
        paths, _ = publish_release.validate(
            self.directory, self.args.version, self.commit
        )
        self.assertEqual(len(paths), 5)

    def test_release_version_must_match_the_source_version(self):
        self.args.version = "0.2.1"
        with self.assertRaisesRegex(RuntimeError, "source version"):
            self.prepare()

    def test_dirty_checkout_is_rejected_unless_development(self):
        self.status = b" M Sources/swiftpods/main.swift\n"
        with self.assertRaisesRegex(RuntimeError, "clean committed revision"):
            self.prepare()

    def test_notarization_from_a_different_archive_is_rejected(self):
        self.args.archive[0].write_bytes(b"changed after notarization")
        with self.assertRaisesRegex(RuntimeError, "matching accepted notarization"):
            self.prepare()

    def test_rejected_notarization_is_rejected(self):
        receipt = json.loads(self.args.notarization[0].read_text())
        receipt["status"] = "Invalid"
        self.args.notarization[0].write_text(json.dumps(receipt))
        with self.assertRaisesRegex(RuntimeError, "notarization receipt"):
            self.prepare()

    def test_duplicate_notarization_is_rejected(self):
        self.args.notarization.append(self.args.notarization[0])
        with self.assertRaisesRegex(RuntimeError, "duplicate notarization"):
            self.prepare()

    def test_unsigned_distribution_cannot_be_published(self):
        self.metadata[self.args.archive[0]]["signed_by"] = None
        with self.assertRaisesRegex(RuntimeError, "Developer ID signing"):
            self.prepare()

    def test_development_fixture_remains_unpublishable(self):
        self.args.development = True
        self.args.notarization = []
        self.status = b" M README.md\n"
        for metadata in self.metadata.values():
            metadata["signed_by"] = None
        self.assertFalse(self.prepare()["publishable"])
        with self.assertRaisesRegex(RuntimeError, "not publishable"):
            publish_release.validate(self.directory, self.args.version, self.commit)

    def test_changed_public_archive_is_rejected_before_upload(self):
        manifest = self.prepare()
        (self.directory / manifest["assets"][0]["filename"]).write_bytes(b"tampered")
        with self.assertRaisesRegex(RuntimeError, "asset changed"):
            publish_release.publish(self.directory, self.args.version, self.commit)

    def test_missing_checksum_is_rejected(self):
        self.prepare()
        (self.directory / "SHA256SUMS").write_text("")
        with self.assertRaisesRegex(RuntimeError, "checksum list"):
            publish_release.validate(self.directory, self.args.version, self.commit)

    def test_source_commit_mismatch_is_rejected(self):
        self.prepare()
        with self.assertRaisesRegex(RuntimeError, "tagged revision"):
            publish_release.validate(self.directory, self.args.version, "2" * 40)

    def test_retargeted_remote_tag_is_rejected_before_creating_a_release(self):
        self.prepare()
        with (
            patch.object(publish_release, "existing_release", return_value=None),
            patch.object(
                publish_release.subprocess, "check_output", return_value="2" * 40
            ),
            patch.object(publish_release.subprocess, "run") as run,
            self.assertRaisesRegex(RuntimeError, "Remote tag"),
        ):
            publish_release.publish(self.directory, self.args.version, self.commit)
        run.assert_not_called()

    def test_all_assets_upload_to_a_draft_before_it_becomes_visible(self):
        self.prepare()
        with (
            patch.object(publish_release, "existing_release", return_value=None),
            patch.object(
                publish_release.subprocess, "check_output", return_value=self.commit
            ),
            patch.object(publish_release.subprocess, "run") as run,
        ):
            publish_release.publish(self.directory, self.args.version, self.commit)
        create, edit = [call.args[0] for call in run.call_args_list]
        self.assertEqual(create[:3], ["gh", "release", "create"])
        self.assertIn("--draft", create)
        self.assertEqual(sum(argument.endswith(".zip") for argument in create), 2)
        self.assertEqual(edit[:3], ["gh", "release", "edit"])
        self.assertIn("--draft=false", edit)

    def test_upload_failure_leaves_the_draft_hidden(self):
        self.prepare()
        with (
            patch.object(publish_release, "existing_release", return_value=None),
            patch.object(
                publish_release.subprocess, "check_output", return_value=self.commit
            ),
            patch.object(
                publish_release.subprocess,
                "run",
                side_effect=RuntimeError("upload failed"),
            ) as run,
            self.assertRaisesRegex(RuntimeError, "upload failed"),
        ):
            publish_release.publish(self.directory, self.args.version, self.commit)
        self.assertEqual(run.call_count, 1)

    def test_published_version_is_never_replaced(self):
        self.prepare()
        with (
            patch.object(
                publish_release, "existing_release", return_value={"draft": False}
            ),
            patch.object(publish_release.subprocess, "run") as run,
            self.assertRaisesRegex(RuntimeError, "already published"),
        ):
            publish_release.publish(self.directory, self.args.version, self.commit)
        run.assert_not_called()

    def test_api_errors_are_not_treated_as_a_missing_release(self):
        for message in ["HTTP 401", "HTTP 403", "HTTP 503", "connection failed"]:
            with (
                self.subTest(message=message),
                patch.object(
                    publish_release.subprocess,
                    "check_output",
                    side_effect=subprocess.CalledProcessError(
                        1, ["gh", "api"], stderr=message
                    ),
                ),
                self.assertRaises(subprocess.CalledProcessError),
            ):
                publish_release.existing_release("v0.2.0")


class ArchiveInspectionTests(unittest.TestCase):
    def setUp(self):
        owner = tempfile.TemporaryDirectory(prefix="swiftpods-inspection-test-")
        self.addCleanup(owner.cleanup)
        self.root = Path(owner.name)

    @unittest.skipUnless(
        sys.platform == "darwin" and shutil.which("xcrun"), "requires Xcode tools"
    )
    def test_platform_is_read_from_the_archived_executable(self):
        source = self.root / "main.c"
        source.write_text("int main(void) { return 0; }\n")
        executable = self.root / "swiftpods"
        subprocess.run(
            [
                "xcrun",
                "clang",
                "-arch",
                "x86_64",
                "-mmacosx-version-min=13.0",
                source,
                "-o",
                executable,
            ],
            check=True,
        )
        archive = self.root / "SwiftPods.zip"
        write_archive(
            archive,
            {
                "bin/swiftpods": (executable.read_bytes(), 0o100755),
                "LICENSE": (b"MIT\n", 0o100644),
                "README.md": (b"SwiftPods\n", 0o100644),
            },
        )
        metadata = release.inspect_archive(archive)
        self.assertEqual(metadata["architecture"], "x86_64")
        self.assertEqual(metadata["minimum_macos"], "13.0")
        self.assertIsNone(metadata["signed_by"])

    def test_unexpected_contents_are_rejected_before_inspecting_the_executable(self):
        files = {
            "bin/swiftpods": (b"#!/bin/sh\n", 0o100755),
            "LICENSE": (b"MIT\n", 0o100644),
            "README.md": (b"SwiftPods\n", 0o100644),
        }
        for name, change in [
            ("extra", {"extra.txt": (b"", 0o100644)}),
            ("missing", {"LICENSE": None}),
        ]:
            with (
                self.subTest(name),
                patch.object(release.subprocess, "check_output") as probe,
            ):
                archive = self.root / (name + ".zip")
                write_archive(
                    archive,
                    {key: value for key, value in {**files, **change}.items() if value},
                )
                with self.assertRaisesRegex(RuntimeError, "must contain exactly"):
                    release.inspect_archive(archive)
                probe.assert_not_called()


if __name__ == "__main__":
    unittest.main()
