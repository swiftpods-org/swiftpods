#!/usr/bin/env python3
"""Regress release signing, preparation, notarization binding and publication."""

import contextlib
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from scripts import (
    apple_signing,
    publish_release,
    release,
    sign_release,
    smoke_release,
    verify_notarization,
)


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


class AppleSignatureInspectionTests(unittest.TestCase):
    def test_certificate_prefix_is_one_codesign_option_argument(self):
        owner = tempfile.TemporaryDirectory(prefix="swiftpods-signature-inspection-test-")
        self.addCleanup(owner.cleanup)
        executable = Path(owner.name) / "swiftpods"
        executable.write_bytes(b"signed fixture")
        certificate = b"fixture developer id leaf certificate"
        commands = []

        def codesign(arguments, **_options):
            commands.append(arguments)
            extraction = next(
                (
                    argument
                    for argument in arguments
                    if isinstance(argument, str)
                    and argument.startswith("--extract-certificates=")
                ),
                None,
            )
            if extraction is not None:
                self.assertNotIn("--extract-certificates", arguments)
                prefix = Path(extraction.split("=", 1)[1])
                Path(str(prefix) + "0").write_bytes(certificate)
                return SimpleNamespace(
                    returncode=0,
                    stderr=(
                        "Authority=Developer ID Application: Fixture (TEAMID1234)\n"
                        "TeamIdentifier=TEAMID1234\n"
                    ),
                )
            return SimpleNamespace(returncode=0, stderr=b"")

        with patch.object(apple_signing.subprocess, "run", side_effect=codesign):
            publisher = apple_signing.inspect_signature(executable)

        self.assertEqual(len(commands), 2)
        self.assertEqual(publisher["team_id"], "TEAMID1234")
        self.assertEqual(
            publisher["certificate_sha1"], hashlib.sha1(certificate).hexdigest().upper()
        )
        self.assertEqual(
            publisher["certificate_sha256"], hashlib.sha256(certificate).hexdigest()
        )


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
        self.team_id = "TEAMID1234"
        self.identities = (
            f'  1) {self.fingerprint} "Developer ID Application: Fixture ({self.team_id})"\n'
            "  1 valid identities found\n"
        )
        self.signed_fingerprint = self.fingerprint
        self.signed_team_id = self.team_id
        self.enterContext(patch.object(sign_release, "ROOT", self.root))

    def output(self, command, **options):
        if command[:2] == ["git", "status"]:
            return b""
        if command[:2] == ["/usr/bin/security", "find-identity"]:
            return self.identities
        self.fail("Unexpected signing probe: " + repr(command))

    def sign(self):
        def run(*arguments):
            if arguments[0] == "/usr/bin/ditto":
                Path(arguments[-1]).write_bytes(b"fixture signed archive")

        with (
            patch.object(
                sys,
                "argv",
                [
                    "sign_release.py", str(self.bundle),
                    "--identity", self.fingerprint,
                    "--team-id", self.team_id,
                ],
            ),
            patch.object(
                sign_release.subprocess, "check_output", side_effect=self.output
            ),
            patch.object(
                sign_release,
                "inspect_signature",
                return_value={
                    "authority": f"Developer ID Application: Fixture ({self.team_id})",
                    "team_id": self.signed_team_id,
                    "certificate_sha1": self.signed_fingerprint,
                    "certificate_sha256": "b" * 64,
                },
            ),
            patch.object(sign_release, "run", side_effect=run) as commands,
            contextlib.redirect_stdout(io.StringIO()),
        ):
            sign_release.main()
        return [call.args for call in commands.call_args_list]

    def test_signs_the_executable_with_the_selected_identity_before_archiving(self):
        sign, archive = self.sign()
        self.assertEqual(sign[:2], ("/usr/bin/codesign", "--force"))
        self.assertEqual(sign[sign.index("--sign") + 1], self.fingerprint)
        self.assertIn("runtime", sign)
        self.assertEqual(sign[-1], self.bundle.resolve() / "bin/swiftpods")
        self.assertEqual(archive[0], "/usr/bin/ditto")
        checksum = hashlib.sha256(b"fixture signed archive").hexdigest()
        self.assertEqual(
            (self.root / "SwiftPods.zip.sha256").read_text(),
            checksum + "  SwiftPods.zip\n",
        )

    def test_ambiguous_identity_is_rejected_before_signing(self):
        self.identities += self.identities.replace("Fixture", "Other")
        with self.assertRaisesRegex(RuntimeError, "exactly one"):
            self.sign()
        self.assertFalse((self.root / "SwiftPods.zip").exists())

    def test_signing_process_never_executes_the_candidate(self):
        commands = self.sign()
        self.assertEqual([command[0] for command in commands], ["/usr/bin/codesign", "/usr/bin/ditto"])

    def test_signed_publisher_must_match_the_pinned_team_and_fingerprint(self):
        for field, value in (
            ("signed_fingerprint", "B" * 40),
            ("signed_team_id", "OTHERID123"),
        ):
            original = getattr(self, field)
            setattr(self, field, value)
            with self.subTest(field=field), self.assertRaisesRegex(
                RuntimeError, "pinned certificate or Team ID"
            ):
                self.sign()
            self.assertFalse((self.root / "SwiftPods.zip").exists())
            setattr(self, field, original)

    def test_signing_tools_do_not_inherit_dynamic_loader_injection(self):
        with patch.dict(
            os.environ,
            {
                "DYLD_INSERT_LIBRARIES": "/tmp/attacker.dylib",
                "LD_PRELOAD": "/tmp/attacker.so",
                "CODESIGN_ALLOCATE": "/tmp/attacker",
                "DEVELOPER_DIR": "/tmp/FakeXcode.app/Contents/Developer",
                "TOOLCHAINS": "attacker",
                "SWIFTPODS_SIGNING_PASSWORD": "secret",
            },
        ):
            environment = sign_release.release_environment()
        self.assertNotIn("DYLD_INSERT_LIBRARIES", environment)
        self.assertNotIn("LD_PRELOAD", environment)
        self.assertNotIn("CODESIGN_ALLOCATE", environment)
        self.assertNotIn("DEVELOPER_DIR", environment)
        self.assertNotIn("TOOLCHAINS", environment)
        self.assertNotIn("SWIFTPODS_SIGNING_PASSWORD", environment)
        self.assertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")


class XcodeToolTrustTests(unittest.TestCase):
    def setUp(self):
        owner = tempfile.TemporaryDirectory(prefix="swiftpods-xcode-trust-test-")
        self.addCleanup(owner.cleanup)
        self.root = Path(owner.name).resolve()
        self.bundle = self.root / "Xcode_Fixture.app"
        self.selected = self.bundle / "Contents/Developer"
        self.candidate = self.selected / "usr/bin/notarytool"
        self.candidate.parent.mkdir(parents=True)
        self.candidate.write_bytes(b"fixture executable")
        self.candidate.chmod(0o755)

    def selected_tool(self, command, **options):
        self.assertEqual(options["env"], apple_signing.apple_tool_environment())
        if command == ["/usr/bin/xcode-select", "-p"]:
            return str(self.selected) + "\n"
        if command == ["/usr/bin/xcrun", "--find", "notarytool"]:
            return str(self.candidate) + "\n"
        self.fail("Unexpected Xcode tool probe: " + repr(command))

    def trust(self, signature_status=0):
        with (
            patch.object(apple_signing, "APPLICATIONS_DIRECTORY", self.root),
            patch.object(
                apple_signing.subprocess,
                "check_output",
                side_effect=self.selected_tool,
            ),
            patch.object(
                apple_signing.subprocess,
                "run",
                return_value=SimpleNamespace(returncode=signature_status),
            ) as verification,
            patch.dict(
                os.environ,
                {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted"},
            ),
        ):
            result = apple_signing.trusted_xcode_tool("notarytool")
        return result, verification

    def test_hosted_runner_owned_xcode_requires_an_exact_apple_signature(self):
        result, verification = self.trust()
        self.assertEqual(result, str(self.candidate))
        command = verification.call_args.args[0]
        self.assertEqual(command[0:4], [
            "/usr/bin/codesign", "--verify", "--strict", "--verbose=2"
        ])
        self.assertEqual(
            command[4],
            '-R=identifier "com.apple.gke.notary.tool" and anchor apple',
        )
        self.assertEqual(command[5], self.candidate)
        environment = verification.call_args.kwargs["env"]
        self.assertEqual(set(environment), {"HOME", "LANG", "LC_ALL", "PATH", "TMPDIR"})
        self.assertNotIn("SWIFTPODS_NOTARY_KEY", environment)

    def test_hosted_runner_owned_xcode_rejects_an_invalid_apple_signature(self):
        with self.assertRaisesRegex(RuntimeError, "valid Apple signature"):
            self.trust(signature_status=1)

    def test_user_owned_xcode_is_not_trusted_outside_a_github_hosted_runner(self):
        with (
            patch.object(apple_signing, "APPLICATIONS_DIRECTORY", self.root),
            patch.object(
                apple_signing.subprocess,
                "check_output",
                side_effect=self.selected_tool,
            ),
            patch.object(apple_signing.subprocess, "run") as verification,
            patch.dict(
                os.environ,
                {"GITHUB_ACTIONS": "", "RUNNER_ENVIRONMENT": ""},
            ),
            self.assertRaisesRegex(RuntimeError, "unexpected owner"),
        ):
            apple_signing.trusted_xcode_tool("notarytool")
        verification.assert_not_called()

    def test_shared_writable_xcode_path_is_rejected_before_signature_check(self):
        self.candidate.parent.chmod(0o775)
        with (
            patch.object(apple_signing, "APPLICATIONS_DIRECTORY", self.root),
            patch.object(
                apple_signing.subprocess,
                "check_output",
                side_effect=self.selected_tool,
            ),
            patch.object(apple_signing.subprocess, "run") as verification,
            patch.dict(
                os.environ,
                {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted"},
            ),
            self.assertRaisesRegex(RuntimeError, "shared write permissions"),
        ):
            apple_signing.trusted_xcode_tool("notarytool")
        verification.assert_not_called()

    @unittest.skipUnless(
        sys.platform == "darwin"
        and os.environ.get("GITHUB_ACTIONS") == "true"
        and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted",
        "requires a GitHub-hosted macOS image",
    )
    def test_github_hosted_selected_notarytool_satisfies_the_live_policy(self):
        self.assertTrue(
            Path(apple_signing.trusted_xcode_tool("notarytool")).is_absolute()
        )


class NotarizationVerificationTests(unittest.TestCase):
    def setUp(self):
        owner = tempfile.TemporaryDirectory(prefix="swiftpods-notary-verification-test-")
        self.addCleanup(owner.cleanup)
        self.root = Path(owner.name)
        self.archive = self.root / "SwiftPods.zip"
        self.archive.write_bytes(b"exact signed archive")
        self.digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.submission = "12345678-1234-1234-1234-123456789abc"
        self.receipt = self.root / "SwiftPods.zip.notary.json"
        self.receipt.write_text(
            json.dumps(
                {
                    "id": self.submission,
                    "status": "Accepted",
                    "archive_sha256": self.digest,
                }
            )
        )

    def test_apple_info_and_log_bind_the_exact_archive(self):
        with (
            patch.object(verify_notarization, "trusted_xcode_tool", return_value="/trusted/notarytool"),
            patch.object(
                verify_notarization,
                "query_notarytool",
                side_effect=[
                    {"id": self.submission, "status": "Accepted"},
                    {
                        "jobId": self.submission,
                        "status": "Accepted",
                        "sha256": self.digest,
                        "archiveFilename": self.archive.name,
                    },
                ],
            ) as query,
        ):
            self.assertEqual(
                verify_notarization.verify(
                    self.archive, self.receipt, ["--key", "/private/key.p8"]
                ),
                self.submission,
            )
        self.assertEqual(
            [call.args[1] for call in query.call_args_list], ["info", "log"]
        )

    def test_unrelated_accepted_submission_is_rejected_by_apple_digest(self):
        with (
            patch.object(verify_notarization, "trusted_xcode_tool", return_value="/trusted/notarytool"),
            patch.object(
                verify_notarization,
                "query_notarytool",
                side_effect=[
                    {"id": self.submission, "status": "Accepted"},
                    {
                        "jobId": self.submission,
                        "status": "Accepted",
                        "sha256": "f" * 64,
                        "archiveFilename": self.archive.name,
                    },
                ],
            ),
            self.assertRaisesRegex(RuntimeError, "exact archive bytes"),
        ):
            verify_notarization.verify(
                self.archive, self.receipt, ["--key", "/private/key.p8"]
            )


class SignedSmokeTests(unittest.TestCase):
    def setUp(self):
        owner = tempfile.TemporaryDirectory(prefix="swiftpods-signed-smoke-test-")
        self.addCleanup(owner.cleanup)
        self.bundle = Path(owner.name) / "SwiftPods"
        executable = self.bundle / "bin/swiftpods"
        executable.parent.mkdir(parents=True)
        executable.write_text("fixture executable")
        executable.chmod(0o700)

    def test_smoke_uses_only_an_allowlisted_environment(self):
        with (
            patch.object(sys, "argv", ["smoke_release.py", str(self.bundle)]),
            patch.object(smoke_release, "inspect_signature", return_value={"signed": True}),
            patch.object(smoke_release, "verify_distribution") as verify,
            patch.dict(os.environ, {"SWIFTPODS_SIGNING_PASSWORD": "secret"}),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            smoke_release.main()
        executable, environment, temporary = verify.call_args.args
        self.assertEqual(executable, (self.bundle / "bin/swiftpods").resolve())
        self.assertEqual(set(environment), {"HOME", "LANG", "LC_ALL", "PATH", "TMPDIR"})
        self.assertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        self.assertEqual(environment["TMPDIR"], str(temporary))
        self.assertNotIn("SWIFTPODS_SIGNING_PASSWORD", environment)

    def test_unsigned_candidate_is_rejected_before_execution(self):
        with (
            patch.object(sys, "argv", ["smoke_release.py", str(self.bundle)]),
            patch.object(smoke_release, "inspect_signature", return_value=None),
            patch.object(smoke_release, "verify_distribution") as verify,
            self.assertRaisesRegex(RuntimeError, "code-signature"),
        ):
            smoke_release.main()
        verify.assert_not_called()


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
        self.tag_object = "c" * 40
        self.status = b""
        self.metadata = {}
        self.publisher = {
            "authority": "Developer ID Application: Fixture (TEAMID1234)",
            "team_id": "TEAMID1234",
            "certificate_sha1": "A" * 40,
            "certificate_sha256": "b" * 64,
        }
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
                "publisher": self.publisher.copy(),
                "content_sha256": ("a" if architecture == "arm64" else "b") * 64,
            }
        self.args = SimpleNamespace(
            bundle=[],
            archive=archives,
            notarization=receipts,
            version="0.2.0",
            tag_object=self.tag_object,
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

    def release_record(self, *, draft, selected_paths=None):
        paths, checksum = publish_release.validate(
            self.directory, self.args.version, self.commit, self.tag_object
        )
        selected = paths if selected_paths is None else selected_paths
        return {
            "tag_name": "v" + self.args.version,
            "draft": draft,
            "immutable": not draft,
            "prerelease": False,
            "name": "SwiftPods " + self.args.version,
            "body": publish_release.release_notes(
                self.args.version, checksum, self.publisher, self.tag_object
            ),
            "assets": [
                {"name": path.name, "size": path.stat().st_size} for path in selected
            ],
        }

    def replace_manifest_tag_object(self, tag_object):
        manifest_path = self.directory / "release.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["source_revision"]["tag_object"] = tag_object
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
        checksum = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
        checksum_path = self.directory / "SHA256SUMS"
        lines = checksum_path.read_text().splitlines()
        checksum_path.write_text(
            "\n".join(
                checksum + "  release.json"
                if line.endswith("  release.json")
                else line
                for line in lines
            )
            + "\n"
        )

    def test_notarized_release_is_publishable_without_runtime_or_evidence_fields(self):
        manifest = self.prepare()
        self.assertTrue(manifest["publishable"])
        self.assertEqual(
            set(manifest),
            {
                "schema_version",
                "development",
                "publishable",
                "publisher",
                "source_revision",
                "version",
                "assets",
                "installer_sha256",
            },
        )
        self.assertEqual(manifest["schema_version"], 3)
        self.assertEqual(manifest["publisher"], self.publisher)
        self.assertEqual(
            manifest["source_revision"],
            {"commit": self.commit, "tag_object": self.tag_object},
        )
        self.assertEqual(
            [asset["filename"] for asset in manifest["assets"]],
            [
                "swiftpods-0.2.0-macos-13.0-arm64.zip",
                "swiftpods-0.2.0-macos-13.0-x86_64.zip",
            ],
        )
        paths, _ = publish_release.validate(
            self.directory, self.args.version, self.commit, self.tag_object
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
        self.metadata[self.args.archive[0]]["publisher"] = None
        with self.assertRaisesRegex(RuntimeError, "Developer ID publisher"):
            self.prepare()

    def test_release_architectures_must_have_the_same_exact_publisher(self):
        self.metadata[self.args.archive[0]]["publisher"] = {
            **self.publisher,
            "certificate_sha256": "c" * 64,
        }
        with self.assertRaisesRegex(RuntimeError, "same exact Developer ID publisher"):
            self.prepare()

    def test_development_fixture_remains_unpublishable(self):
        self.args.development = True
        self.args.tag_object = None
        self.args.notarization = []
        self.status = b" M README.md\n"
        for metadata in self.metadata.values():
            metadata["publisher"] = None
        manifest = self.prepare()
        self.assertFalse(manifest["publishable"])
        self.assertEqual(manifest["source_revision"], {"commit": self.commit})
        with self.assertRaisesRegex(RuntimeError, "not publishable"):
            publish_release.validate(
                self.directory, self.args.version, self.commit, self.tag_object
            )

    def test_production_release_requires_a_valid_annotated_tag_object(self):
        for value in (None, "short", "G" * 40):
            self.args.tag_object = value
            with self.subTest(value=value), self.assertRaisesRegex(
                RuntimeError, "tag object"
            ):
                self.prepare()

    def test_changed_public_archive_is_rejected_before_upload(self):
        manifest = self.prepare()
        (self.directory / manifest["assets"][0]["filename"]).write_bytes(b"tampered")
        with self.assertRaisesRegex(RuntimeError, "asset changed"):
            publish_release.publish(
                self.directory, self.args.version, self.commit, self.tag_object
            )

    def test_missing_checksum_is_rejected(self):
        self.prepare()
        (self.directory / "SHA256SUMS").write_text("")
        with self.assertRaisesRegex(RuntimeError, "checksum list"):
            publish_release.validate(
                self.directory, self.args.version, self.commit, self.tag_object
            )

    def test_unexpected_public_asset_is_rejected(self):
        self.prepare()
        (self.directory / "unexpected.txt").write_text("not part of the release")
        with self.assertRaisesRegex(RuntimeError, "unexpected public asset"):
            publish_release.validate(
                self.directory, self.args.version, self.commit, self.tag_object
            )

    def test_source_commit_mismatch_is_rejected(self):
        self.prepare()
        with self.assertRaisesRegex(RuntimeError, "tagged revision"):
            publish_release.validate(
                self.directory, self.args.version, "2" * 40, self.tag_object
            )

    def test_manifest_source_tag_object_must_match_the_expected_object(self):
        self.prepare()
        with self.assertRaisesRegex(RuntimeError, "tagged revision"):
            publish_release.validate(
                self.directory, self.args.version, self.commit, "d" * 40
            )

    def test_prior_draft_notes_require_a_canonical_source_identity(self):
        checksum = "f" * 64
        body = publish_release.release_notes(
            self.args.version, checksum, self.publisher, self.tag_object
        )
        self.assertEqual(
            publish_release.recorded_release_notes_checksum(
                body, self.args.version, self.publisher, self.tag_object
            ),
            checksum,
        )
        for changed in (
            body.replace(checksum, checksum.upper()),
            body.replace(self.tag_object, "d" * 40),
            body.replace(self.publisher["team_id"], "OTHERID123"),
            body.replace(self.publisher["certificate_sha256"], "c" * 64),
            body + "\n",
        ):
            with self.subTest(changed=changed):
                self.assertIsNone(
                    publish_release.recorded_release_notes_checksum(
                        changed,
                        self.args.version,
                        self.publisher,
                        self.tag_object,
                    )
                )

    def test_remote_source_tag_requires_the_exact_annotated_object(self):
        tag = "v" + self.args.version
        with patch.object(
            publish_release,
            "github_json",
            side_effect=[
                {
                    "ref": "refs/tags/" + tag,
                    "object": {"type": "tag", "sha": self.tag_object},
                },
                {
                    "sha": self.tag_object,
                    "tag": tag,
                    "object": {"type": "commit", "sha": self.commit},
                },
            ],
        ) as github_json:
            publish_release.validate_remote_source_tag(
                tag, self.tag_object, self.commit
            )
        self.assertEqual(
            [call.args[0] for call in github_json.call_args_list],
            ["git/ref/tags/" + tag, "git/tags/" + self.tag_object],
        )

    def test_lightweight_source_tag_is_rejected_even_at_the_expected_commit(self):
        tag = "v" + self.args.version
        with (
            patch.object(
                publish_release,
                "github_json",
                return_value={
                    "ref": "refs/tags/" + tag,
                    "object": {"type": "commit", "sha": self.commit},
                },
            ) as github_json,
            self.assertRaisesRegex(RuntimeError, "not annotated"),
        ):
            publish_release.validate_remote_source_tag(
                tag, self.tag_object, self.commit
            )
        github_json.assert_called_once_with("git/ref/tags/" + tag)

    def test_replaced_tag_object_is_rejected_even_if_it_peels_to_the_same_commit(self):
        tag = "v" + self.args.version
        replacement = "d" * 40
        with (
            patch.object(
                publish_release,
                "github_json",
                return_value={
                    "ref": "refs/tags/" + tag,
                    "object": {"type": "tag", "sha": replacement},
                },
            ) as github_json,
            self.assertRaisesRegex(RuntimeError, "tag object changed"),
        ):
            publish_release.validate_remote_source_tag(
                tag, self.tag_object, self.commit
            )
        # The replacement object is never trusted or peeled merely because it
        # could name the same commit as the object selected by metadata.
        github_json.assert_called_once_with("git/ref/tags/" + tag)

    def test_nested_annotated_source_tag_is_rejected(self):
        tag = "v" + self.args.version
        with (
            patch.object(
                publish_release,
                "github_json",
                side_effect=[
                    {
                        "ref": "refs/tags/" + tag,
                        "object": {"type": "tag", "sha": self.tag_object},
                    },
                    {
                        "sha": self.tag_object,
                        "tag": tag,
                        "object": {"type": "tag", "sha": "e" * 40},
                    },
                ],
            ),
            self.assertRaisesRegex(RuntimeError, "does not peel to the tested commit"),
        ):
            publish_release.validate_remote_source_tag(
                tag, self.tag_object, self.commit
            )

    def test_retargeted_remote_tag_is_rejected_before_creating_a_release(self):
        self.prepare()
        with (
            patch.object(publish_release, "existing_release", return_value=None),
            patch.object(
                publish_release,
                "validate_remote_source_tag",
                side_effect=RuntimeError("Remote tag object changed"),
            ),
            patch.object(publish_release.subprocess, "run") as run,
            self.assertRaisesRegex(RuntimeError, "Remote tag"),
        ):
            publish_release.publish(
                self.directory, self.args.version, self.commit, self.tag_object
            )
        run.assert_not_called()

    def test_all_assets_upload_to_a_draft_before_it_becomes_visible(self):
        self.prepare()
        paths, _ = publish_release.validate(
            self.directory, self.args.version, self.commit, self.tag_object
        )
        empty_draft = self.release_record(draft=True, selected_paths=[])
        complete_draft = self.release_record(draft=True)
        published = self.release_record(draft=False)
        with (
            patch.object(
                publish_release,
                "existing_release",
                side_effect=[None, empty_draft, complete_draft, published],
            ),
            patch.object(publish_release, "validate_remote_source_tag"),
            patch.object(publish_release, "verify_downloaded_payload") as verify_remote,
            patch.object(publish_release.subprocess, "run") as run,
        ):
            publish_release.publish(
                self.directory, self.args.version, self.commit, self.tag_object
            )
        create, edit_draft, upload, edit_public = [
            call.args[0] for call in run.call_args_list
        ]
        self.assertEqual(create[:3], ["gh", "release", "create"])
        self.assertIn("--draft", create)
        self.assertEqual(sum(argument.endswith(".zip") for argument in create), 0)
        self.assertIn("--draft=true", edit_draft)
        self.assertEqual(upload[:3], ["gh", "release", "upload"])
        self.assertIn("--clobber", upload)
        self.assertEqual(
            {Path(argument).name for argument in upload if Path(argument).name in {path.name for path in paths}},
            {path.name for path in paths},
        )
        self.assertIn("--draft=false", edit_public)
        self.assertEqual(verify_remote.call_count, 2)

    def test_upload_failure_leaves_the_draft_hidden(self):
        self.prepare()
        empty_draft = self.release_record(draft=True, selected_paths=[])
        with (
            patch.object(
                publish_release,
                "existing_release",
                side_effect=[None, empty_draft],
            ),
            patch.object(publish_release, "validate_remote_source_tag"),
            patch.object(
                publish_release.subprocess,
                "run",
                side_effect=[None, None, RuntimeError("upload failed")],
            ) as run,
            self.assertRaisesRegex(RuntimeError, "upload failed"),
        ):
            publish_release.publish(
                self.directory, self.args.version, self.commit, self.tag_object
            )
        self.assertEqual(run.call_count, 3)
        self.assertNotIn("--draft=false", run.call_args_list[-1].args[0])

    def test_partial_draft_is_reconciled_only_from_the_validated_payload(self):
        self.prepare()
        paths, _ = publish_release.validate(
            self.directory, self.args.version, self.commit, self.tag_object
        )
        partial = self.release_record(draft=True, selected_paths=paths[:2])
        complete = self.release_record(draft=True)
        published = self.release_record(draft=False)
        with (
            patch.object(
                publish_release,
                "existing_release",
                side_effect=[partial, partial, complete, published],
            ),
            patch.object(publish_release, "validate_remote_source_tag"),
            patch.object(publish_release, "verify_downloaded_payload"),
            patch.object(publish_release.subprocess, "run") as run,
        ):
            checksum = publish_release.publish(
                self.directory, self.args.version, self.commit, self.tag_object
            )
        self.assertRegex(checksum, r"^[0-9a-f]{64}$")
        commands = [call.args[0] for call in run.call_args_list]
        self.assertNotIn(["gh", "release", "create"], [command[:3] for command in commands])
        self.assertEqual(commands[1][:3], ["gh", "release", "upload"])
        self.assertIn("--clobber", commands[1])

    def test_draft_with_a_prior_valid_checksum_converges_to_the_current_payload(self):
        self.prepare()
        paths, checksum = publish_release.validate(
            self.directory, self.args.version, self.commit, self.tag_object
        )
        prior_checksum = "f" * 64 if checksum != "f" * 64 else "e" * 64
        prior = self.release_record(draft=True, selected_paths=paths[:1])
        prior["body"] = publish_release.release_notes(
            self.args.version, prior_checksum, self.publisher, self.tag_object
        )
        current_partial = self.release_record(draft=True, selected_paths=paths[:1])
        complete = self.release_record(draft=True)
        published = self.release_record(draft=False)
        written_notes = []

        def record_notes(command, **_):
            if "--notes-file" in command:
                written_notes.append(
                    Path(command[command.index("--notes-file") + 1]).read_text()
                )

        with (
            patch.object(
                publish_release,
                "existing_release",
                side_effect=[prior, current_partial, complete, published],
            ),
            patch.object(publish_release, "validate_remote_source_tag"),
            patch.object(publish_release, "verify_downloaded_payload"),
            patch.object(
                publish_release.subprocess, "run", side_effect=record_notes
            ),
        ):
            self.assertEqual(
                publish_release.publish(
                    self.directory,
                    self.args.version,
                    self.commit,
                    self.tag_object,
                ),
                checksum,
            )
        expected_notes = publish_release.release_notes(
            self.args.version, checksum, self.publisher, self.tag_object
        )
        self.assertTrue(written_notes)
        self.assertTrue(all(notes == expected_notes for notes in written_notes))
        self.assertNotIn(prior_checksum, expected_notes)

    def test_draft_cannot_be_rebound_to_a_replaced_tag_object_on_a_new_run(self):
        self.prepare()
        original_draft = self.release_record(draft=True, selected_paths=[])
        replacement = "d" * 40
        self.replace_manifest_tag_object(replacement)
        with (
            patch.object(
                publish_release, "existing_release", return_value=original_draft
            ),
            patch.object(publish_release.subprocess, "run") as run,
            self.assertRaisesRegex(RuntimeError, "source tag object"),
        ):
            publish_release.publish(
                self.directory, self.args.version, self.commit, replacement
            )
        run.assert_not_called()

    def test_draft_with_an_unexpected_asset_is_never_modified(self):
        self.prepare()
        draft = self.release_record(draft=True)
        draft["assets"].append({"name": "foreign.bin", "size": 1})
        with (
            patch.object(publish_release, "existing_release", return_value=draft),
            patch.object(publish_release, "validate_remote_source_tag"),
            patch.object(publish_release.subprocess, "run") as run,
            self.assertRaisesRegex(RuntimeError, "unexpected release assets"),
        ):
            publish_release.publish(
                self.directory, self.args.version, self.commit, self.tag_object
            )
        run.assert_not_called()

    def test_downloaded_draft_bytes_must_equal_the_validated_local_payload(self):
        self.prepare()
        paths, checksum = publish_release.validate(
            self.directory, self.args.version, self.commit, self.tag_object
        )

        def download(command, **_):
            destination = Path(command[command.index("--dir") + 1])
            for path in self.directory.iterdir():
                shutil.copy2(path, destination / path.name)
            archive = next(destination.glob("swiftpods-*.zip"))
            archive.write_bytes(b"tampered remote bytes")

        with (
            patch.object(publish_release.subprocess, "run", side_effect=download),
            self.assertRaisesRegex(RuntimeError, "asset changed"),
        ):
            publish_release.verify_downloaded_payload(
                "v" + self.args.version,
                self.args.version,
                self.commit,
                self.tag_object,
                paths,
                checksum,
            )

    def test_exact_published_version_is_accepted_but_never_replaced(self):
        self.prepare()
        published = self.release_record(draft=False)
        with (
            patch.object(publish_release, "existing_release", return_value=published),
            patch.object(publish_release, "validate_remote_source_tag"),
            patch.object(publish_release, "verify_downloaded_payload") as verify_remote,
            patch.object(publish_release.subprocess, "run") as run,
        ):
            publish_release.publish(
                self.directory, self.args.version, self.commit, self.tag_object
            )
        run.assert_not_called()
        verify_remote.assert_called_once()

    def test_mutable_published_release_is_rejected(self):
        self.prepare()
        published = self.release_record(draft=False)
        published["immutable"] = False
        with (
            patch.object(publish_release, "existing_release", return_value=published),
            patch.object(publish_release.subprocess, "run") as run,
            self.assertRaisesRegex(RuntimeError, "immutable releases"),
        ):
            publish_release.publish(
                self.directory, self.args.version, self.commit, self.tag_object
            )
        run.assert_not_called()

    def test_mismatched_published_version_is_never_replaced(self):
        self.prepare()
        published = self.release_record(draft=False)
        published["body"] = "different"
        with (
            patch.object(publish_release, "existing_release", return_value=published),
            patch.object(publish_release.subprocess, "run") as run,
            self.assertRaisesRegex(RuntimeError, "metadata"),
        ):
            publish_release.publish(
                self.directory, self.args.version, self.commit, self.tag_object
            )
        run.assert_not_called()

    def test_public_release_cannot_be_adopted_by_a_replaced_tag_object_on_a_new_run(self):
        self.prepare()
        original_release = self.release_record(draft=False)
        replacement = "d" * 40
        self.replace_manifest_tag_object(replacement)
        with (
            patch.object(
                publish_release, "existing_release", return_value=original_release
            ),
            patch.object(publish_release.subprocess, "run") as run,
            self.assertRaisesRegex(RuntimeError, "metadata"),
        ):
            publish_release.publish(
                self.directory, self.args.version, self.commit, replacement
            )
        run.assert_not_called()

    def test_exact_published_payload_can_be_verified_for_integration_resume(self):
        self.prepare()
        paths, checksum = publish_release.validate(
            self.directory, self.args.version, self.commit, self.tag_object
        )
        published = self.release_record(draft=False)
        with (
            patch.object(publish_release, "existing_release", return_value=published),
            patch.object(
                publish_release, "validate_remote_source_tag"
            ),
            patch.object(publish_release, "verify_downloaded_payload") as verify_remote,
        ):
            self.assertEqual(
                publish_release.verify_published(
                    self.directory,
                    self.args.version,
                    self.commit,
                    self.tag_object,
                ),
                checksum,
            )
        verify_remote.assert_called_once()

    def test_published_payload_must_match_its_recorded_manifest_and_asset_set(self):
        self.prepare()
        paths, checksum = publish_release.validate(
            self.directory, self.args.version, self.commit, self.tag_object
        )
        published = self.release_record(draft=False)
        for field, value, message in (
            ("body", "`release.json` SHA-256: `" + "f" * 64 + "`\n", "metadata"),
            ("assets", published["assets"][:-1], "asset set"),
        ):
            changed = dict(published)
            changed[field] = value
            with (
                self.subTest(field=field),
                patch.object(
                    publish_release, "existing_release", return_value=changed
                ),
                patch.object(
                    publish_release, "validate_remote_source_tag"
                ),
                patch.object(publish_release, "verify_downloaded_payload"),
                self.assertRaisesRegex(RuntimeError, message),
            ):
                publish_release.verify_published(
                    self.directory,
                    self.args.version,
                    self.commit,
                    self.tag_object,
                )

    def test_published_payload_rejects_a_retargeted_source_tag(self):
        self.prepare()
        paths, checksum = publish_release.validate(
            self.directory, self.args.version, self.commit, self.tag_object
        )
        published = self.release_record(draft=False)
        with (
            patch.object(publish_release, "existing_release", return_value=published),
            patch.object(
                publish_release,
                "validate_remote_source_tag",
                side_effect=RuntimeError("exact source tag"),
            ),
            patch.object(publish_release, "verify_downloaded_payload"),
            self.assertRaisesRegex(RuntimeError, "exact source tag"),
        ):
            publish_release.verify_published(
                self.directory,
                self.args.version,
                self.commit,
                self.tag_object,
            )

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

    def test_draft_is_found_after_release_by_tag_returns_404(self):
        draft = {"tag_name": "v0.2.0", "draft": True}
        missing = subprocess.CalledProcessError(
            1, ["gh", "api"], stderr="gh: Not Found (HTTP 404)"
        )
        with patch.object(
            publish_release.subprocess,
            "check_output",
            side_effect=[missing, json.dumps([[draft]])],
        ) as check_output:
            self.assertEqual(publish_release.existing_release("v0.2.0"), draft)
        self.assertIn("--paginate", check_output.call_args_list[1].args[0])
        self.assertIn("--slurp", check_output.call_args_list[1].args[0])

    def test_missing_release_requires_an_exhaustive_draft_lookup(self):
        missing = subprocess.CalledProcessError(
            1, ["gh", "api"], stderr="gh: Not Found (HTTP 404)"
        )
        with patch.object(
            publish_release.subprocess,
            "check_output",
            side_effect=[missing, "[[], []]"],
        ):
            self.assertIsNone(publish_release.existing_release("v0.2.0"))

    def test_duplicate_release_records_are_rejected_as_ambiguous(self):
        missing = subprocess.CalledProcessError(
            1, ["gh", "api"], stderr="gh: Not Found (HTTP 404)"
        )
        draft = {"tag_name": "v0.2.0", "draft": True}
        with (
            patch.object(
                publish_release.subprocess,
                "check_output",
                side_effect=[missing, json.dumps([[draft], [draft]])],
            ),
            self.assertRaisesRegex(RuntimeError, "ambiguous release metadata"),
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
        self.assertIsNone(metadata["publisher"])
        self.assertRegex(metadata["content_sha256"], r"^[0-9a-f]{64}$")

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
