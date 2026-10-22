#!/usr/bin/env python3
"""Regress release preparation, notarization binding and atomic publication."""

import contextlib
import hashlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from scripts import publish_release, release, sign_release


class SigningIdentityTests(unittest.TestCase):
    def test_certificate_fingerprint_keeps_the_canonical_name_in_release_metadata(self):
        with tempfile.TemporaryDirectory(prefix="swiftpods-signing-test-") as owner:
            bundle = Path(owner) / "SwiftPods"
            (bundle / "bin").mkdir(parents=True)
            (bundle / "bin/swiftpods").write_bytes(b"fixture executable")
            fingerprint = "A" * 40
            name = "Developer ID Application: Fixture (TEAM)"

            def output(command, **options):
                if command[:2] == ["git", "status"]:
                    return b""
                if command[:2] == ["/usr/bin/security", "find-identity"]:
                    return f'  1) {fingerprint} "{name}"\n  1 valid identities found\n'
                if command[0] == "/usr/bin/file":
                    return "Mach-O 64-bit executable arm64"
                self.fail("Unexpected signing probe: " + repr(command))

            def run(*arguments):
                if arguments[0] == "/usr/bin/ditto":
                    Path(arguments[-1]).write_bytes(b"fixture signed archive")

            with (
                patch.object(sys, "argv", ["sign_release.py", str(bundle), "--identity", fingerprint]),
                patch.object(sign_release.subprocess, "check_output", side_effect=output),
                patch.object(sign_release, "manifest", side_effect=lambda path: (path / "compatibility.json").write_text('{}')),
                patch.object(sign_release, "run", side_effect=run) as commands,
                contextlib.redirect_stdout(io.StringIO()),
            ):
                sign_release.main()
            metadata = json.loads((bundle / "compatibility.json").read_text())
            self.assertEqual(metadata["signing"]["identity"], name)
            self.assertTrue(any(call.args[:2] == ("/usr/bin/codesign", "--force")
                                and call.args[call.args.index("--sign") + 1] == fingerprint
                                for call in commands.call_args_list))
            self.assertTrue(any("-N" in call.args and call.args[call.args.index("-N") + 1] == name
                                for call in commands.call_args_list))


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="swiftpods-release-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "scripts").mkdir()
        (self.root / "scripts/install.py").write_text("# installer fixture\n")
        self.directory = self.root / "release"
        self.directory.mkdir()
        self.commit = "1" * 40
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
                "swiftpods_version": "0.1.0",
                "runtime": {"mode": "external"},
                "swiftpods_source": {
                    "base_commit": self.commit,
                    "files_digest": "source",
                    "worktree_has_changes": False,
                },
                "build_host": {"architecture": architecture},
                "minimum_macos": "15.0",
                "files": {},
                "bundle_digest": architecture,
                "status": "release",
                "signing": {
                    "identity": "Developer ID Application: Fixture",
                    "notarization_requested": True,
                },
            }
        evidence = self.root / "evidence.zip"
        evidence.write_bytes(b"fixture evidence")
        self.index = {
            "bundles": [
                {"bundle_digest": architecture} for architecture in ("arm64", "x86_64")
            ],
            "stable_acceptance": "not_established",
        }
        self.args = SimpleNamespace(
            bundle=[],
            archive=archives,
            evidence=[evidence],
            notarization=receipts,
            version="0.1.0",
            development=False,
        )
        for replacement in (
            patch.object(release, "ROOT", self.root),
            patch.object(
                release,
                "inspect_archive",
                side_effect=lambda path: (self.metadata[path], "manifest"),
            ),
            patch.object(
                release, "validate_evidence", side_effect=lambda *_: self.index
            ),
            patch("scripts.support.reporting.source_digest", return_value="source"),
            patch.object(
                release.subprocess,
                "check_output",
                side_effect=lambda command, **_: (
                    b"" if command[1] == "status" else self.commit
                ),
            ),
        ):
            replacement.start()
            self.addCleanup(replacement.stop)

    def prepare(self):
        with contextlib.redirect_stdout(io.StringIO()):
            release.prepare(self.args, self.directory)
        return json.loads((self.directory / "release.json").read_text())

    def test_verified_notarized_release_does_not_claim_full_platform_certification(
        self,
    ):
        manifest = self.prepare()
        self.assertTrue(manifest["publishable"])
        self.assertEqual(manifest["stable_acceptance"], "not_established")
        paths, _ = publish_release.validate(
            self.directory, self.args.version, self.commit
        )
        self.assertEqual(len(paths), 5)
        self.assertFalse(any(path.name.startswith("evidence-") for path in paths))

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
        self.metadata[self.args.archive[0]]["signing"] = {}
        with self.assertRaisesRegex(RuntimeError, "Developer ID signing"):
            self.prepare()

    def test_notarized_release_without_test_evidence_has_no_acceptance_claims(self):
        self.args.evidence = []
        manifest = self.prepare()
        self.assertTrue(manifest["publishable"])
        self.assertEqual(manifest["acceptance"], [])
        self.assertEqual(manifest["stable_acceptance"], "not_established")
        publish_release.validate(self.directory, self.args.version, self.commit)

    def test_development_fixture_remains_unpublishable(self):
        self.args.development = True
        self.args.notarization = []
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

    def test_replacement_requires_the_exact_previous_tag_object(self):
        with (
            patch.object(publish_release.subprocess, "check_output") as read,
            patch.object(publish_release.subprocess, "run") as run,
            self.assertRaisesRegex(RuntimeError, "exact previous tag object"),
        ):
            publish_release.replace_release("v0.1.0", self.commit, "latest")
        read.assert_not_called()
        run.assert_not_called()

    def test_replacement_does_not_delete_a_retargeted_release(self):
        with (
            patch.object(
                publish_release.subprocess,
                "check_output",
                return_value=json.dumps({"object": {"sha": "b" * 40}}),
            ),
            patch.object(publish_release.subprocess, "run") as run,
            self.assertRaisesRegex(RuntimeError, "Remote tag changed"),
        ):
            publish_release.replace_release("v0.1.0", self.commit, "a" * 40)
        run.assert_not_called()

    def test_immutable_release_is_never_deleted(self):
        with (
            patch.object(
                publish_release.subprocess,
                "check_output",
                side_effect=[
                    json.dumps({"object": {"sha": "a" * 40}}),
                    json.dumps({"immutable": True}),
                ],
            ),
            patch.object(publish_release.subprocess, "run") as run,
            self.assertRaisesRegex(RuntimeError, "immutable release"),
        ):
            publish_release.replace_release("v0.1.0", self.commit, "a" * 40)
        run.assert_not_called()

    def test_invalid_replacement_assets_leave_the_existing_release_intact(self):
        manifest = self.prepare()
        (self.directory / manifest["assets"][0]["filename"]).write_bytes(b"tampered")
        with (
            patch.object(publish_release.subprocess, "check_output") as read,
            patch.object(publish_release.subprocess, "run") as run,
            self.assertRaisesRegex(RuntimeError, "asset changed"),
        ):
            publish_release.publish(
                self.directory, self.args.version, self.commit, "a" * 40
            )
        read.assert_not_called()
        run.assert_not_called()

    def test_explicit_replacement_updates_only_the_selected_tag_then_uploads_a_draft(
        self,
    ):
        self.prepare()
        with (
            patch.object(
                publish_release.subprocess,
                "check_output",
                side_effect=[
                    json.dumps({"object": {"sha": "a" * 40}}),
                    json.dumps({"immutable": False}),
                    self.commit,
                ],
            ),
            patch.object(publish_release.subprocess, "run") as run,
        ):
            publish_release.publish(
                self.directory, self.args.version, self.commit, "a" * 40
            )
        delete, retag, create, publish = [call.args[0] for call in run.call_args_list]
        self.assertEqual(delete[:4], ["gh", "release", "delete", "v0.1.0"])
        self.assertNotIn("--cleanup-tag", delete)
        self.assertIn("repos/swiftpods-org/swiftpods/git/refs/tags/v0.1.0", retag)
        self.assertIn("sha=" + self.commit, retag)
        self.assertIn("force=true", retag)
        self.assertEqual(create[:4], ["gh", "release", "create", "v0.1.0"])
        self.assertIn("--draft", create)
        self.assertIn("--draft=false", publish)


if __name__ == "__main__":
    unittest.main()
