#!/usr/bin/env python3
"""Regress pinned installation: checksums, archive safety and version verification."""

import contextlib
import hashlib
import io
import json
import os
import re
import signal
import shutil
import stat
import subprocess
import tempfile
import time
import unittest
import zipfile
from pathlib import Path
from types import SimpleNamespace
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
        self.authenticated_execution_patcher = patch.object(
            installer,
            "authenticated_run",
            side_effect=self.fake_authenticated_run,
        )
        self.authenticated_execution = self.authenticated_execution_patcher.start()
        self.addCleanup(self.authenticated_execution_patcher.stop)

    def fake_authenticated_run(
        self,
        _executable,
        descriptor,
        arguments,
        _cwd,
        _environment,
        _timeout,
        evidence,
        maximum_output_bytes=installer.MAX_COMMAND_OUTPUT_BYTES,
    ):
        self.assertGreaterEqual(maximum_output_bytes, 0)
        installer.require_authenticated_executable(descriptor, evidence)
        if arguments == ["version", "--json"]:
            contents = os.pread(descriptor, 64 * 1024, 0)
            match = re.search(br'"version"\s*:\s*"([^"]+)"', contents)
            version = match.group(1).decode() if match else "0.2.0"
            return installer.AuthenticatedCommandResult(
                0, json.dumps({"version": version}).encode(), b""
            )
        return installer.AuthenticatedCommandResult(0, b"command output\n", b"")

    def add_acl(self, path, rule):
        result = subprocess.run(
            ["/bin/chmod", "+a", rule, str(path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if result.returncode != 0:
            self.skipTest("The test filesystem does not support Darwin ACLs")

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

    def install_local(
        self, data, manifest=None, offline=False, runtime=None, execute=None
    ):
        archive = self.root / "archive.zip"
        archive.write_bytes(data)
        path = self.root / "release.json"
        path.write_text(json.dumps(manifest or self.manifest(data)))
        argv = [
            "install.py",
            "--version",
            "0.2.0",
            "--manifest-sha256",
            hashlib.sha256(path.read_bytes()).hexdigest(),
            "--prefix",
            str(self.prefix),
        ]
        if offline:
            argv.append("--offline")
        else:
            argv += ["--manifest", str(path), "--archive", str(archive)]
        if runtime is not None:
            argv += ["--runtime-directory", str(runtime)]
        if execute is not None:
            argv += ["--execute"] + execute
        output = io.StringIO()
        with (
            patch("sys.argv", argv),
            patch.object(installer.platform, "machine", return_value="arm64"),
            patch.object(installer.platform, "mac_ver", return_value=("15.0", "", "")),
            contextlib.redirect_stdout(output),
        ):
            installer.main()
        return output.getvalue().strip()

    def test_downloads_the_pinned_release_from_the_main_repository(self):
        data = archive_bytes()
        manifest = self.manifest(data)
        manifest["schema_version"] = 3
        manifest["publisher"] = {
            "authority": "Developer ID Application: Fixture (TEAMID1234)",
            "team_id": "TEAMID1234",
            "certificate_sha1": "A" * 40,
            "certificate_sha256": "b" * 64,
        }
        encoded = json.dumps(manifest).encode()
        responses = {BASE + "release.json": encoded, manifest["assets"][0]["url"]: data}

        def download(url, _limit):
            return responses[url]

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
            patch.object(installer, "remote_bytes", side_effect=download) as fetch,
            patch.object(installer, "select_asset", return_value=manifest["assets"][0]),
            patch.object(installer, "verify_executable_publisher") as verify_publisher,
            contextlib.redirect_stdout(io.StringIO()),
        ):
            installer.main()
        self.assertEqual(
            [call.args[0] for call in fetch.call_args_list], list(responses)
        )
        self.assertTrue((self.prefix / "bin/swiftpods").is_file())
        verify_publisher.assert_called_once()
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

    def test_schema_two_cannot_downgrade_a_new_release(self):
        manifest = self.manifest(b"")
        manifest["version"] = "0.3.2"
        with self.assertRaisesRegex(RuntimeError, "only for legacy"):
            installer.select_asset(
                manifest, "0.3.2", architecture="arm64", macos="15.0"
            )

    def test_schema_three_publishable_manifest_requires_exact_publisher(self):
        manifest = self.manifest(b"")
        manifest["schema_version"] = 3
        with self.assertRaisesRegex(RuntimeError, "publisher evidence"):
            installer.expected_publisher(manifest)

        certificate = b"fixture developer id leaf certificate"
        manifest["publisher"] = {
            "authority": "Developer ID Application: Fixture (TEAMID1234)",
            "team_id": "TEAMID1234",
            "certificate_sha1": hashlib.sha1(certificate).hexdigest().upper(),
            "certificate_sha256": hashlib.sha256(certificate).hexdigest(),
        }
        self.assertEqual(installer.expected_publisher(manifest), manifest["publisher"])

    def test_exact_publisher_certificate_and_team_are_verified(self):
        executable = self.root / "swiftpods"
        executable.write_bytes(b"signed fixture")
        certificate = b"fixture developer id leaf certificate"
        publisher = {
            "authority": "Developer ID Application: Fixture (TEAMID1234)",
            "team_id": "TEAMID1234",
            "certificate_sha1": hashlib.sha1(certificate).hexdigest().upper(),
            "certificate_sha256": hashlib.sha256(certificate).hexdigest(),
        }

        def codesign(arguments, **_options):
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

        with patch.object(installer.subprocess, "run", side_effect=codesign):
            installer.verify_executable_publisher(
                executable,
                publisher,
                self.root,
                self.root,
                {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"},
            )
            with self.assertRaisesRegex(RuntimeError, "differs from the pinned"):
                installer.verify_executable_publisher(
                    executable,
                    {**publisher, "team_id": "OTHERID123"},
                    self.root,
                    self.root,
                    {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"},
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
        with self.assertRaisesRegex(RuntimeError, "content verification"):
            self.install_local(data)

    def test_tampered_cached_executable_is_not_run_during_verification(self):
        data = archive_bytes()
        self.install_local(data)
        marker = self.root / "executed"
        executable = self.prefix / "bin/swiftpods"
        executable.write_text(
            "#!/bin/sh\ntouch " + str(marker) + "\necho '{\"version\": \"0.2.0\"}'\n"
        )
        executable.chmod(0o755)
        with self.assertRaisesRegex(RuntimeError, "content verification"):
            self.install_local(data)
        self.assertFalse(marker.exists())

    def test_authenticated_cache_can_be_reused_offline(self):
        data = archive_bytes()
        self.install_local(data)
        self.install_local(data, offline=True)

    def test_runtime_copy_is_authenticated_and_offline_compatible(self):
        data = archive_bytes()
        runtime = self.root / "runtime-online"
        runtime.mkdir(mode=0o700)
        path = Path(self.install_local(data, runtime=runtime))
        self.assertEqual(path, runtime.resolve() / "swiftpods")
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o500)

        offline_runtime = self.root / "runtime-offline"
        offline_runtime.mkdir(mode=0o700)
        offline_path = Path(self.install_local(data, offline=True, runtime=offline_runtime))
        self.assertEqual(offline_path, offline_runtime.resolve() / "swiftpods")
        self.assertEqual(
            subprocess.check_output([offline_path, "version", "--json"]),
            subprocess.check_output([path, "version", "--json"]),
        )

        marker = self.root / "mutable-cache-executed"
        cached = self.prefix / "bin/swiftpods"
        cached.write_text("#!/bin/sh\ntouch " + str(marker) + "\necho '{}'")
        cached.chmod(0o755)
        subprocess.check_call([path, "version", "--json"], stdout=subprocess.DEVNULL)
        self.assertFalse(marker.exists())

    def test_execute_is_delegated_to_the_authenticated_runtime_supervisor(self):
        with patch.dict(
            os.environ,
            {
                "HOME": str(self.root),
                "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
                "SSH_AUTH_SOCK": "/private/tmp/ssh-agent.sock",
                "SWIFTPODS_PROJECT_CONTEXT": "preserved",
                "PYTHONPATH": "/tmp/injected-python",
                "DYLD_INSERT_LIBRARIES": "/tmp/injected.dylib",
                "GIT_CONFIG_PARAMETERS": "'alias.pwn=!touch /tmp/pwned'",
            },
        ):
            output = self.install_local(
                archive_bytes(), execute=["check", "--offline", "--json"]
            )
        self.assertEqual(output, "command output")
        self.assertEqual(
            self.authenticated_execution.call_args.args[2],
            ["check", "--offline", "--json"],
        )
        environment = self.authenticated_execution.call_args.args[4]
        self.assertEqual(environment["HOME"], str(self.root))
        self.assertEqual(
            environment["DEVELOPER_DIR"],
            "/Applications/Xcode.app/Contents/Developer",
        )
        self.assertEqual(environment["SSH_AUTH_SOCK"], "/private/tmp/ssh-agent.sock")
        self.assertEqual(environment["SWIFTPODS_PROJECT_CONTEXT"], "preserved")
        self.assertNotIn("PYTHONPATH", environment)
        self.assertNotIn("DYLD_INSERT_LIBRARIES", environment)
        self.assertNotIn("GIT_CONFIG_PARAMETERS", environment)

    def test_runtime_copy_removes_inherited_extended_acl(self):
        data = archive_bytes()
        runtime = self.root / "runtime-with-acl"
        runtime.mkdir(mode=0o700)
        self.add_acl(
            runtime,
            "everyone allow list,search,add_file,add_subdirectory,delete_child",
        )
        descriptor = os.open(runtime, os.O_RDONLY)
        try:
            self.assertTrue(installer.descriptor_has_extended_acl(descriptor))
        finally:
            os.close(descriptor)

        executable = Path(self.install_local(data, runtime=runtime))
        descriptor = os.open(runtime, os.O_RDONLY)
        file_descriptor = os.open(executable, os.O_RDONLY)
        try:
            self.assertFalse(installer.descriptor_has_extended_acl(descriptor))
            self.assertFalse(installer.descriptor_has_extended_acl(file_descriptor))
        finally:
            os.close(file_descriptor)
            os.close(descriptor)

    def test_runtime_parent_must_not_be_shared_writable(self):
        data = archive_bytes()
        shared = self.root / "shared-runtime-parent"
        shared.mkdir(mode=0o700)
        runtime = shared / "runtime"
        runtime.mkdir(mode=0o700)
        shared.chmod(0o777)
        try:
            with self.assertRaisesRegex(RuntimeError, "shared writes"):
                self.install_local(data, runtime=runtime)
        finally:
            shared.chmod(0o700)
        self.assertFalse(self.prefix.exists())
        self.assertEqual(list(runtime.iterdir()), [])

    def test_runtime_parent_must_not_have_an_extended_acl(self):
        data = archive_bytes()
        parent = self.root / "acl-runtime-parent"
        parent.mkdir(mode=0o700)
        runtime = parent / "runtime"
        runtime.mkdir(mode=0o700)
        self.add_acl(
            parent,
            "everyone allow add_file,add_subdirectory,delete_child",
        )
        try:
            with self.assertRaisesRegex(RuntimeError, "extended ACL"):
                self.install_local(data, runtime=runtime)
        finally:
            subprocess.run(
                ["/bin/chmod", "-N", str(parent)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
        self.assertFalse(self.prefix.exists())
        self.assertEqual(list(runtime.iterdir()), [])

    def test_fresh_local_installation_may_be_explicitly_offline(self):
        data = archive_bytes()
        archive = self.root / "local-offline.zip"
        archive.write_bytes(data)
        manifest = self.root / "local-offline.json"
        manifest.write_text(json.dumps(self.manifest(data)))
        argv = [
            "install.py",
            "--version",
            "0.2.0",
            "--manifest-sha256",
            hashlib.sha256(manifest.read_bytes()).hexdigest(),
            "--prefix",
            str(self.prefix),
            "--offline",
            "--manifest",
            str(manifest),
            "--archive",
            str(archive),
        ]
        with (
            patch("sys.argv", argv),
            patch.object(installer.platform, "machine", return_value="arm64"),
            patch.object(installer.platform, "mac_ver", return_value=("15.0", "", "")),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            installer.main()
        self.assertTrue((self.prefix / "bin/swiftpods").is_file())

    def test_legacy_cache_requires_one_online_verification(self):
        data = archive_bytes()
        self.install_local(data)
        (self.prefix / installer.CACHED_MANIFEST).unlink()
        (self.prefix / installer.CACHED_ARCHIVE).unlink()
        with self.assertRaisesRegex(RuntimeError, "legacy.*online|no authenticated manifest"):
            self.install_local(data, offline=True)
        self.install_local(data)
        self.assertTrue((self.prefix / installer.CACHED_MANIFEST).is_file())
        self.assertTrue((self.prefix / installer.CACHED_ARCHIVE).is_file())

    def test_declared_content_digest_is_checked_before_execution(self):
        data = archive_bytes()
        manifest = self.manifest(data)
        manifest["assets"][0]["content_sha256"] = "0" * 64
        with self.assertRaisesRegex(RuntimeError, "content verification"):
            self.install_local(data, manifest)
        self.assertFalse(self.prefix.exists())

    def test_version_probe_uses_a_fixed_non_injectable_environment(self):
        data = archive_bytes()
        with tempfile.TemporaryDirectory(dir=self.root) as staging:
            root = installer.extract_archive(data, Path(staging))
            digest = installer.distribution_digest(root)
            self.authenticated_execution.reset_mock()
            with patch.dict(
                os.environ, {"DYLD_INSERT_LIBRARIES": "/tmp/attacker.dylib"}
            ):
                installer.verify_distribution(root, "0.2.0", digest)
        arguments = self.authenticated_execution.call_args.args
        self.assertEqual(arguments[4], {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"
        })
        self.assertNotIn("DYLD_INSERT_LIBRARIES", arguments[4])
        self.assertEqual(arguments[3], root)
        self.assertEqual(arguments[2], ["version", "--json"])
        self.assertNotEqual(Path(arguments[0]), root / "bin/swiftpods")

    def test_internal_version_probe_nests_runtime_below_a_private_parent(self):
        data = archive_bytes()
        shared_temp = self.root / "shared-temp"
        shared_temp.mkdir(mode=0o1777)
        observed = {}

        def check_version(executable, *_arguments, **_kwargs):
            runtime = Path(executable).parent
            private_parent = runtime.parent
            observed["private_parent"] = private_parent
            self.assertEqual(private_parent.parent, root.parent.resolve())
            self.assertNotEqual(private_parent, shared_temp.resolve())
            self.assertEqual(stat.S_IMODE(private_parent.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(runtime.stat().st_mode), 0o700)
            return installer.AuthenticatedCommandResult(
                0, json.dumps({"version": "0.2.0"}).encode(), b""
            )

        try:
            with tempfile.TemporaryDirectory(dir=self.root) as staging:
                root = installer.extract_archive(data, Path(staging))
                digest = installer.distribution_digest(root)
                with (
                    patch.object(installer.tempfile, "tempdir", str(shared_temp)),
                    patch.object(installer, "authenticated_run", side_effect=check_version),
                ):
                    installer.verify_distribution(root, "0.2.0", digest)
                self.assertFalse(observed["private_parent"].exists())
        finally:
            shared_temp.chmod(0o700)

    def test_executable_replacement_between_digest_and_copy_is_not_run(self):
        data = archive_bytes()
        with tempfile.TemporaryDirectory(dir=self.root) as staging:
            root = installer.extract_archive(data, Path(staging))
            expected = installer.distribution_digest(root)
            marker = self.root / "replacement-executed"
            original_digest = installer.distribution_digest

            def digest_then_replace(distribution, evidence=None):
                result = original_digest(distribution, evidence)
                executable = distribution / "bin/swiftpods"
                executable.write_text(
                    "#!/bin/sh\ntouch " + str(marker) + "\necho '{\"version\": \"0.2.0\"}'\n"
                )
                executable.chmod(0o755)
                return result

            runtime = self.root / "runtime-race"
            runtime.mkdir(mode=0o700)
            with (
                patch.object(installer, "distribution_digest", side_effect=digest_then_replace),
                self.assertRaisesRegex(RuntimeError, "changed before it could be copied"),
            ):
                installer.verify_distribution(root, "0.2.0", expected, runtime)
            self.assertFalse(marker.exists())

    def test_same_inode_mutation_after_publisher_verification_is_not_run(self):
        data = archive_bytes()
        publisher = {
            "authority": "Developer ID Application: Fixture (TEAMID1234)",
            "team_id": "TEAMID1234",
            "certificate_sha1": "A" * 40,
            "certificate_sha256": "b" * 64,
        }
        runtime = self.root / "runtime-publisher-race"
        runtime.mkdir(mode=0o700)

        with tempfile.TemporaryDirectory(dir=self.root) as staging:
            root = installer.extract_archive(data, Path(staging))
            digest = installer.distribution_digest(root)
            self.authenticated_execution.reset_mock()

            def mutate_after_verification(executable, *_arguments, **_options):
                path = Path(executable)
                before = path.stat()
                contents = path.read_bytes()
                replacement = bytes([contents[0] ^ 0x01]) + contents[1:]
                path.chmod(0o700)
                with path.open("r+b", buffering=0) as stream:
                    stream.write(replacement)
                    stream.flush()
                    os.fsync(stream.fileno())
                path.chmod(0o500)
                after = path.stat()
                self.assertEqual(
                    (after.st_dev, after.st_ino, after.st_size),
                    (before.st_dev, before.st_ino, before.st_size),
                )

            with (
                patch.object(
                    installer,
                    "verify_executable_publisher",
                    side_effect=mutate_after_verification,
                ),
                self.assertRaisesRegex(RuntimeError, "changed before execution"),
            ):
                installer.verify_distribution(
                    root, "0.2.0", digest, runtime, publisher=publisher
                )

            self.authenticated_execution.assert_not_called()

    def test_download_and_expansion_limits_are_enforced(self):
        data = archive_bytes(extra=[("SwiftPods/large", "x" * 32)])
        with (
            patch.object(installer, "MAX_EXPANDED_BYTES", 16),
            self.assertRaisesRegex(RuntimeError, "size limit"),
            tempfile.TemporaryDirectory(dir=self.root) as staging,
        ):
            installer.extract_archive(data, Path(staging))
        path = self.root / "large"
        path.write_bytes(b"x" * 32)
        with (
            patch.object(installer, "MAX_DOWNLOAD_BYTES", 16),
            self.assertRaisesRegex(RuntimeError, "size limit"),
        ):
            installer.checked_bytes(str(path), hashlib.sha256(path.read_bytes()).hexdigest(), local=True)
        with (
            patch.object(
                installer.os,
                "fstat",
                return_value=SimpleNamespace(st_mode=stat.S_IFREG | 0o600, st_size=0),
            ),
            self.assertRaisesRegex(RuntimeError, "size limit"),
        ):
            installer.checked_bytes(
                str(path), hashlib.sha256(path.read_bytes()).hexdigest(), local=True, max_bytes=16
            )

    def test_remote_download_has_a_hard_wall_clock_deadline(self):
        def slow_download(_url, _limit):
            time.sleep(1)
            return b""

        started = time.monotonic()
        with (
            patch.object(installer, "REMOTE_TIMEOUT_SECONDS", 0.02),
            patch.object(installer, "remote_bytes", side_effect=slow_download),
            self.assertRaisesRegex(RuntimeError, "time limit"),
        ):
            installer.checked_bytes(BASE + "release.json", hashlib.sha256(b"").hexdigest())
        self.assertLess(time.monotonic() - started, 0.5)

    def test_remote_download_pins_the_vetted_address_and_tls_hostname(self):
        endpoint = (
            installer.socket.AF_INET,
            installer.socket.SOCK_STREAM,
            installer.socket.IPPROTO_TCP,
            ("93.184.216.34", 443),
        )

        class Response:
            status = 200

            def getheader(self, _name):
                return None

            def read(self, _size):
                if hasattr(self, "done"):
                    return b""
                self.done = True
                return b"payload"

            def close(self):
                pass

        class Connection:
            def close(self):
                pass

        with (
            patch.object(installer, "public_endpoints", return_value=[endpoint]),
            patch.object(
                installer,
                "request_pinned_https",
                return_value=(Connection(), Response()),
            ) as request,
        ):
            self.assertEqual(
                installer.remote_bytes("https://example.com/signed?token=secret", 64),
                b"payload",
            )
        self.assertEqual(request.call_args.args[0], "example.com")
        self.assertEqual(request.call_args.args[1], "/signed?token=secret")
        self.assertEqual(request.call_args.args[2], [endpoint])

    def test_pinned_connection_uses_the_vetted_peer_but_original_sni_name(self):
        endpoint = (
            installer.socket.AF_INET,
            installer.socket.SOCK_STREAM,
            installer.socket.IPPROTO_TCP,
            ("93.184.216.34", 443),
        )

        class Socket:
            def settimeout(self, value):
                self.timeout = value

            def connect(self, address):
                self.address = address

            def close(self):
                self.closed = True

        class Context:
            verify_mode = installer.ssl.CERT_REQUIRED
            check_hostname = True

            def wrap_socket(self, connection, server_hostname):
                self.connection = connection
                self.server_hostname = server_hostname
                return connection

        connection_socket = Socket()
        context = Context()
        with (
            patch.object(installer.socket, "socket", return_value=connection_socket),
            patch.object(installer.ssl, "create_default_context", return_value=context),
        ):
            connection = installer.PinnedHTTPSConnection(
                "downloads.example.com", endpoint, 7
            )
            connection.connect()
        self.assertEqual(connection_socket.address, endpoint[3])
        self.assertEqual(connection_socket.timeout, 7)
        self.assertEqual(context.server_hostname, "downloads.example.com")

    def test_remote_redirect_to_private_address_is_rejected_before_connect(self):
        public = (
            installer.socket.AF_INET,
            installer.socket.SOCK_STREAM,
            installer.socket.IPPROTO_TCP,
            "",
            ("93.184.216.34", 443),
        )
        private = (
            installer.socket.AF_INET,
            installer.socket.SOCK_STREAM,
            installer.socket.IPPROTO_TCP,
            "",
            ("127.0.0.1", 443),
        )

        class Redirect:
            status = 302

            def getheader(self, name):
                if name == "Location":
                    return "https://127.0.0.1/internal?token=signed-secret"
                return None

            def close(self):
                pass

        class Connection:
            def close(self):
                pass

        def resolve(hostname, *_args, **_kwargs):
            return [private if hostname == "127.0.0.1" else public]

        with (
            patch.object(installer.socket, "getaddrinfo", side_effect=resolve),
            patch.object(
                installer,
                "request_pinned_https",
                return_value=(Connection(), Redirect()),
            ) as request,
            self.assertRaises(RuntimeError) as raised,
        ):
            installer.remote_bytes("https://example.com/release", 64)
        self.assertEqual(request.call_count, 1)
        self.assertIn("public address", str(raised.exception))
        self.assertNotIn("signed-secret", str(raised.exception))

    def test_remote_download_rejects_multicast_even_when_ipaddress_marks_it_global(self):
        multicast = (
            installer.socket.AF_INET,
            installer.socket.SOCK_STREAM,
            installer.socket.IPPROTO_TCP,
            "",
            ("224.0.0.1", 443),
        )
        with (
            patch.object(installer.socket, "getaddrinfo", return_value=[multicast]),
            self.assertRaisesRegex(RuntimeError, "public address"),
        ):
            installer.public_endpoints("multicast.example")

    def test_cached_evidence_does_not_follow_symlinks(self):
        target = self.root / "manifest"
        target.write_bytes(b"trusted")
        link = self.root / "cached-manifest"
        link.symlink_to(target)
        checksum = hashlib.sha256(b"trusted").hexdigest()
        self.assertEqual(installer.checked_bytes(link, checksum, local=True), b"trusted")
        with self.assertRaisesRegex(RuntimeError, "safely read"):
            installer.checked_bytes(link, checksum, local=True, nofollow=True)

    def test_fifo_inputs_are_rejected_without_blocking(self):
        fifo = self.root / "release.fifo"
        os.mkfifo(fifo, 0o600)
        started = time.monotonic()
        with self.assertRaisesRegex(RuntimeError, "regular file"):
            installer.local_bytes(fifo, installer.MAX_DOWNLOAD_BYTES, nofollow=True)
        self.assertLess(time.monotonic() - started, 0.5)

        runtime = self.root / "runtime"
        runtime.mkdir(mode=0o700)
        with self.assertRaisesRegex(RuntimeError, "changed before it could be copied"):
            installer.copy_authenticated_executable(
                fifo,
                runtime / "swiftpods",
                {"sha256": hashlib.sha256(b"").hexdigest(), "size": 0, "mode": 0o755},
            )

    def test_distribution_inventory_does_not_follow_cycles_or_escaping_links(self):
        root = self.root / "distribution"
        root.mkdir()
        (root / "loop").symlink_to(".")
        installer.distribution_digest(root)
        (root / "escape").symlink_to("../outside")
        with self.assertRaisesRegex(RuntimeError, "symlink escapes"):
            installer.distribution_digest(root)

    def test_extraction_and_inventory_reject_shared_writable_payloads(self):
        previous = os.umask(0)
        try:
            with tempfile.TemporaryDirectory(dir=self.root) as staging:
                root = installer.extract_archive(archive_bytes(), Path(staging))
                self.assertEqual(stat.S_IMODE(root.stat().st_mode), 0o755)
                executable = root / "bin/swiftpods"
                self.assertEqual(stat.S_IMODE(executable.stat().st_mode) & 0o022, 0)
                installer.distribution_digest(root)
                executable.chmod(0o775)
                with self.assertRaisesRegex(RuntimeError, "unsafe writable"):
                    installer.distribution_digest(root)
        finally:
            os.umask(previous)

    def test_installation_receipt_is_private_under_a_permissive_umask(self):
        previous = os.umask(0)
        try:
            self.install_local(archive_bytes())
        finally:
            os.umask(previous)
        receipt = self.prefix / installer.INSTALLATION_RECEIPT
        self.assertEqual(stat.S_IMODE(receipt.stat().st_mode), 0o600)

    def test_rejects_a_group_or_world_writable_install_parent(self):
        os.chmod(self.root, 0o777)
        try:
            with self.assertRaisesRegex(RuntimeError, "shared writes"):
                self.install_local(archive_bytes())
        finally:
            os.chmod(self.root, 0o700)
        self.assertFalse(self.prefix.exists())

    def test_rejects_an_install_parent_with_an_extended_acl(self):
        self.add_acl(self.root, "everyone allow add_file,add_subdirectory,delete_child")
        try:
            with self.assertRaisesRegex(RuntimeError, "extended ACL"):
                self.install_local(archive_bytes())
        finally:
            subprocess.run(
                ["/bin/chmod", "-N", str(self.root)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
        self.assertFalse(self.prefix.exists())

    def test_final_install_uses_the_bound_parent_and_staging_descriptors(self):
        with patch.object(Path, "rename", side_effect=AssertionError("path rename used")):
            self.install_local(archive_bytes())
        self.assertTrue((self.prefix / "bin/swiftpods").is_file())

    def test_final_install_never_replaces_a_destination_that_appeared(self):
        staging = self.root / "staging"
        staging.mkdir()
        source = staging / "SwiftPods"
        source.mkdir()
        (source / "marker").write_text("authenticated")
        destination = self.root / "installed"
        destination.mkdir()
        source_descriptor = os.open(staging, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        destination_descriptor = os.open(
            self.root, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
        )
        try:
            with self.assertRaisesRegex(RuntimeError, "Destination appeared"):
                installer.rename_directory_no_replace(
                    source.name,
                    destination.name,
                    source_descriptor,
                    destination_descriptor,
                )
        finally:
            os.close(destination_descriptor)
            os.close(source_descriptor)
        self.assertTrue((source / "marker").is_file())
        self.assertEqual(list(destination.iterdir()), [])

    def test_distribution_inventory_rejects_extended_file_acl(self):
        with tempfile.TemporaryDirectory(dir=self.root) as staging:
            root = installer.extract_archive(archive_bytes(), Path(staging))
            executable = root / "bin/swiftpods"
            self.add_acl(executable, "everyone allow write")
            with self.assertRaisesRegex(RuntimeError, "access controls"):
                installer.distribution_digest(root)

    def test_cleanup_refuses_a_replaced_parent_directory(self):
        parent = self.root / "parent"
        parent.mkdir()
        identity = installer.directory_identity(parent)
        staging = parent / ".swiftpods-install-abcdef"
        staging.mkdir()
        original_parent = self.root / "original-parent"
        parent.rename(original_parent)
        parent.mkdir()
        with self.assertRaisesRegex(RuntimeError, "parent changed"):
            installer.remove_staging(staging, parent, identity)
        self.assertTrue((original_parent / staging.name).is_dir())

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


class AuthenticatedExecutionTests(unittest.TestCase):
    def setUp(self):
        owner = tempfile.TemporaryDirectory(prefix="swiftpods-spawn-test-")
        self.addCleanup(owner.cleanup)
        self.root = Path(owner.name)

    def copied_executable(self, source, name):
        path = self.root / name
        shutil.copyfile(source, path)
        path.chmod(0o500)
        return path

    def copied_true(self, name):
        return self.copied_executable("/usr/bin/true", name)

    def assert_process_was_reaped(self, process):
        with self.assertRaises(ChildProcessError):
            os.waitpid(process, os.WNOHANG)

    def test_authenticated_mapped_executable_is_resumed(self):
        executable = self.copied_true("candidate")
        descriptor = os.open(executable, os.O_RDONLY | os.O_CLOEXEC)
        try:
            result = installer.authenticated_run(
                executable,
                descriptor,
                [],
                self.root,
                {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
                5,
                installer.authenticated_executable_evidence(descriptor),
            )
        finally:
            os.close(descriptor)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(result.stderr, b"")

    def test_keyboard_interrupt_immediately_after_spawn_kills_and_reaps_child(self):
        executable = self.copied_true("interrupted-before-authentication")
        descriptor = os.open(executable, os.O_RDONLY | os.O_CLOEXEC)
        spawned = []

        def interrupt(process, *_arguments):
            spawned.append(process)
            raise KeyboardInterrupt()

        try:
            with (
                patch.object(
                    installer,
                    "authenticate_and_supervise_spawned_process",
                    side_effect=interrupt,
                ),
                self.assertRaises(KeyboardInterrupt),
            ):
                installer.authenticated_run(
                    executable,
                    descriptor,
                    [],
                    self.root,
                    {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
                    5,
                    installer.authenticated_executable_evidence(descriptor),
                )
        finally:
            os.close(descriptor)
        self.assertEqual(len(spawned), 1)
        self.assert_process_was_reaped(spawned[0])

    def test_enumeration_failure_fallback_preserves_primary_interrupt(self):
        executable = self.copied_true("interrupted-enumeration-failure")
        descriptor = os.open(executable, os.O_RDONLY | os.O_CLOEXEC)
        spawned = []

        def interrupt(process, *_arguments):
            spawned.append(process)
            raise KeyboardInterrupt()

        try:
            with (
                patch.object(
                    installer,
                    "authenticate_and_supervise_spawned_process",
                    side_effect=interrupt,
                ),
                patch.object(
                    installer,
                    "session_process_identifiers",
                    side_effect=installer.SessionEnumerationError(
                        "deterministic enumeration failure"
                    ),
                ),
                self.assertRaises(KeyboardInterrupt),
            ):
                installer.authenticated_run(
                    executable,
                    descriptor,
                    [],
                    self.root,
                    {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
                    5,
                    installer.authenticated_executable_evidence(descriptor),
                )
        finally:
            os.close(descriptor)
        self.assertEqual(len(spawned), 1)
        self.assert_process_was_reaped(spawned[0])

    def test_enumeration_fallback_does_not_hide_a_real_cleanup_failure(self):
        executable = self.copied_true("interrupted-cleanup-failure")
        descriptor = os.open(executable, os.O_RDONLY | os.O_CLOEXEC)
        spawned = []

        def interrupt(process, *_arguments):
            spawned.append(process)
            raise KeyboardInterrupt()

        try:
            with (
                patch.object(
                    installer,
                    "authenticate_and_supervise_spawned_process",
                    side_effect=interrupt,
                ),
                patch.object(
                    installer,
                    "session_process_identifiers",
                    side_effect=installer.SessionEnumerationError(
                        "deterministic enumeration failure"
                    ),
                ),
                patch.object(
                    installer.os,
                    "killpg",
                    side_effect=PermissionError("deterministic cleanup failure"),
                ),
                self.assertRaisesRegex(
                    PermissionError, "deterministic cleanup failure"
                ),
            ):
                installer.authenticated_run(
                    executable,
                    descriptor,
                    [],
                    self.root,
                    {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
                    5,
                    installer.authenticated_executable_evidence(descriptor),
                )
        finally:
            os.close(descriptor)
        self.assertEqual(len(spawned), 1)
        self.assert_process_was_reaped(spawned[0])

    def test_keyboard_interrupt_during_supervision_kills_and_reaps_child(self):
        executable = self.copied_executable("/bin/sleep", "interrupted-command")
        descriptor = os.open(executable, os.O_RDONLY | os.O_CLOEXEC)
        real_kill = os.kill
        resumed = []

        def observe(process, command):
            if command == signal.SIGCONT:
                resumed.append(process)
            return real_kill(process, command)

        try:
            with (
                patch.object(installer.os, "kill", side_effect=observe),
                patch.object(
                    installer.select, "select", side_effect=KeyboardInterrupt
                ),
                self.assertRaises(KeyboardInterrupt),
            ):
                installer.authenticated_run(
                    executable,
                    descriptor,
                    ["30"],
                    self.root,
                    {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
                    5,
                    installer.authenticated_executable_evidence(descriptor),
                )
        finally:
            os.close(descriptor)
        self.assertEqual(len(resumed), 1)
        self.assert_process_was_reaped(resumed[0])

    def test_sigterm_unwinds_cleanup_and_restores_default_handler(self):
        executable = self.copied_true("terminated-before-authentication")
        descriptor = os.open(executable, os.O_RDONLY | os.O_CLOEXEC)
        spawned = []
        original_handler = signal.getsignal(signal.SIGTERM)

        def terminate(process, *_arguments):
            spawned.append(process)
            installed_handler = signal.getsignal(signal.SIGTERM)
            self.assertTrue(callable(installed_handler))
            installed_handler(signal.SIGTERM, None)

        signal.signal(signal.SIGTERM, signal.SIG_DFL)
        try:
            with (
                patch.object(
                    installer,
                    "authenticate_and_supervise_spawned_process",
                    side_effect=terminate,
                ),
                self.assertRaises(SystemExit) as termination,
            ):
                installer.authenticated_run(
                    executable,
                    descriptor,
                    [],
                    self.root,
                    {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
                    5,
                    installer.authenticated_executable_evidence(descriptor),
                )
            self.assertEqual(termination.exception.code, 128 + signal.SIGTERM)
            self.assertEqual(signal.getsignal(signal.SIGTERM), signal.SIG_DFL)
        finally:
            signal.signal(signal.SIGTERM, original_handler)
            os.close(descriptor)
        self.assertEqual(len(spawned), 1)
        self.assert_process_was_reaped(spawned[0])

    def test_path_substitution_is_rejected_before_sigcont(self):
        expected = self.copied_true("expected")
        candidate = self.copied_true("candidate")
        descriptor = os.open(expected, os.O_RDONLY | os.O_CLOEXEC)
        real_kill = os.kill
        resumed = []

        def observe(process, command):
            if command == signal.SIGCONT:
                resumed.append(process)
            return real_kill(process, command)

        try:
            with (
                patch.object(installer.os, "kill", side_effect=observe),
                self.assertRaisesRegex(RuntimeError, "unauthenticated executable"),
            ):
                installer.authenticated_run(
                    candidate,
                    descriptor,
                    [],
                    self.root,
                    {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
                    5,
                    installer.authenticated_executable_evidence(descriptor),
                )
        finally:
            os.close(descriptor)
        self.assertEqual(resumed, [])


if __name__ == "__main__":
    unittest.main()
