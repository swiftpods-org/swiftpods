#!/usr/bin/env python3
"""Install a pinned SwiftPods release into a private prefix.

The release manifest SHA-256 is required and must come from the caller's pinned
configuration. Never modifies shell profiles or replaces a prefix owned by
another installation.
"""

import argparse
import contextlib
import ctypes
import errno
import hashlib
import http.client
import ipaddress
import json
import os
import platform
import re
import select
import signal
import shutil
import socket
import ssl
import stat
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import zipfile
from pathlib import Path, PurePosixPath


MAX_DOWNLOAD_BYTES = 256 * 1024 * 1024
MAX_MANIFEST_BYTES = 1024 * 1024
MAX_ARCHIVE_ENTRIES = 256
MAX_DISTRIBUTION_ENTRIES = 256
MAX_EXPANDED_BYTES = 512 * 1024 * 1024
MAX_MEMBER_BYTES = 256 * 1024 * 1024
MAX_PATH_COMPONENTS = 16
BUFFER_SIZE = 1024 * 1024
REMOTE_TIMEOUT_SECONDS = 120
MAX_REDIRECTS = 5
MAX_COMMAND_OUTPUT_BYTES = 64 * 1024 * 1024
COMMAND_TIMEOUT_SECONDS = 30 * 60
CACHED_MANIFEST = ".swiftpods-release.json"
CACHED_ARCHIVE = ".swiftpods-release.zip"
INSTALLATION_RECEIPT = ".installation.json"
METADATA_FILES = {CACHED_MANIFEST, CACHED_ARCHIVE, INSTALLATION_RECEIPT}
ACL_TYPE_EXTENDED = 0x00000100
# Schema 2 predates publisher pinning. Keep the already-published releases installable, but never let a new release
# downgrade its manifest to schema 2 and thereby bypass the Developer ID certificate check.
LEGACY_SCHEMA_V2_VERSIONS = frozenset(
    {"0.2.0", "0.2.1", "0.2.2", "0.2.3", "0.3.0", "0.3.1"}
)


_LIBC = ctypes.CDLL(None, use_errno=True)
_LIBC.acl_init.argtypes = [ctypes.c_int]
_LIBC.acl_init.restype = ctypes.c_void_p
_LIBC.acl_free.argtypes = [ctypes.c_void_p]
_LIBC.acl_free.restype = ctypes.c_int
_LIBC.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
_LIBC.acl_get_fd_np.restype = ctypes.c_void_p
_LIBC.acl_get_entry.argtypes = [
    ctypes.c_void_p,
    ctypes.c_int,
    ctypes.POINTER(ctypes.c_void_p),
]
_LIBC.acl_get_entry.restype = ctypes.c_int
_LIBC.acl_set_fd_np.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
_LIBC.acl_set_fd_np.restype = ctypes.c_int

RENAME_EXCL = 0x00000004
RENAME_NOREPLACE = 0x00000001


class DownloadTimeout(Exception):
    pass


class AuthenticatedCommandResult:
    def __init__(self, returncode, stdout, stderr):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


class SessionEnumerationError(RuntimeError):
    """The authenticated command's isolated session could not be enumerated."""


class DistributionVerification:
    def __init__(self, executable, execution=None):
        self.executable = executable
        self.execution = execution


class DarwinProcRegionInfo(ctypes.Structure):
    _fields_ = [
        ("protection", ctypes.c_uint32),
        ("maximum_protection", ctypes.c_uint32),
        ("inheritance", ctypes.c_uint32),
        ("flags", ctypes.c_uint32),
        ("offset", ctypes.c_uint64),
        ("behavior", ctypes.c_uint32),
        ("user_wired_count", ctypes.c_uint32),
        ("user_tag", ctypes.c_uint32),
        ("pages_resident", ctypes.c_uint32),
        ("pages_shared_now_private", ctypes.c_uint32),
        ("pages_swapped_out", ctypes.c_uint32),
        ("pages_dirtied", ctypes.c_uint32),
        ("reference_count", ctypes.c_uint32),
        ("shadow_depth", ctypes.c_uint32),
        ("share_mode", ctypes.c_uint32),
        ("private_pages_resident", ctypes.c_uint32),
        ("shared_pages_resident", ctypes.c_uint32),
        ("object_identifier", ctypes.c_uint32),
        ("depth", ctypes.c_uint32),
        ("address", ctypes.c_uint64),
        ("size", ctypes.c_uint64),
    ]


class DarwinVInfoStat(ctypes.Structure):
    _fields_ = [
        ("device", ctypes.c_uint32),
        ("mode", ctypes.c_uint16),
        ("link_count", ctypes.c_uint16),
        ("inode", ctypes.c_uint64),
        ("user", ctypes.c_uint32),
        ("group", ctypes.c_uint32),
        ("access_time", ctypes.c_int64),
        ("access_time_nanoseconds", ctypes.c_int64),
        ("modification_time", ctypes.c_int64),
        ("modification_time_nanoseconds", ctypes.c_int64),
        ("change_time", ctypes.c_int64),
        ("change_time_nanoseconds", ctypes.c_int64),
        ("birth_time", ctypes.c_int64),
        ("birth_time_nanoseconds", ctypes.c_int64),
        ("size", ctypes.c_int64),
        ("blocks", ctypes.c_int64),
        ("block_size", ctypes.c_int32),
        ("flags", ctypes.c_uint32),
        ("generation", ctypes.c_uint32),
        ("raw_device", ctypes.c_uint32),
        ("spare", ctypes.c_int64 * 2),
    ]


class DarwinVnodeInfo(ctypes.Structure):
    _fields_ = [
        ("status", DarwinVInfoStat),
        ("vnode_type", ctypes.c_int32),
        ("padding", ctypes.c_int32),
        ("filesystem_identifier", ctypes.c_int32 * 2),
    ]


class DarwinVnodeInfoPath(ctypes.Structure):
    _fields_ = [
        ("information", DarwinVnodeInfo),
        ("path", ctypes.c_char * 1024),
    ]


class DarwinProcRegionWithPathInfo(ctypes.Structure):
    _fields_ = [
        ("region", DarwinProcRegionInfo),
        ("vnode", DarwinVnodeInfoPath),
    ]


class PinnedHTTPSConnection(http.client.HTTPSConnection):
    """An HTTPS connection whose TCP peer is one already-vetted address."""

    def __init__(self, hostname, endpoint, timeout):
        super().__init__(
            hostname,
            port=443,
            timeout=timeout,
            context=ssl.create_default_context(),
        )
        self.endpoint = endpoint

    def connect(self):
        family, socket_type, protocol, socket_address = self.endpoint
        connection = socket.socket(family, socket_type, protocol)
        try:
            connection.settimeout(self.timeout)
            connection.connect(socket_address)
            self.sock = self._context.wrap_socket(
                connection, server_hostname=self.host
            )
        except Exception:
            connection.close()
            raise


def descriptor_has_extended_acl(descriptor):
    """Return whether a Darwin descriptor has an effective extended ACL."""
    ctypes.set_errno(0)
    acl = _LIBC.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED)
    if not acl:
        problem = ctypes.get_errno()
        if problem in (errno.ENOENT, errno.ENOTSUP, errno.EOPNOTSUPP):
            return False
        raise RuntimeError("Cannot inspect access controls: " + os.strerror(problem))
    try:
        entry = ctypes.c_void_p()
        if _LIBC.acl_get_entry(acl, 0, ctypes.byref(entry)) != 0:
            problem = ctypes.get_errno()
            raise RuntimeError(
                "Cannot inspect access controls: " + os.strerror(problem)
            )
        return entry.value is not None
    finally:
        _LIBC.acl_free(acl)


def clear_descriptor_acl(descriptor):
    """Remove inherited extended ACL entries from a descriptor we own."""
    empty = _LIBC.acl_init(0)
    if not empty:
        raise RuntimeError("Cannot allocate an empty access-control list")
    try:
        ctypes.set_errno(0)
        if _LIBC.acl_set_fd_np(descriptor, empty, ACL_TYPE_EXTENDED) != 0:
            problem = ctypes.get_errno()
            if problem not in (errno.ENOTSUP, errno.EOPNOTSUPP):
                raise RuntimeError(
                    "Cannot remove inherited access controls: "
                    + os.strerror(problem)
                )
    finally:
        _LIBC.acl_free(empty)


def rename_directory_no_replace(
    source_name, destination_name, source_descriptor, destination_descriptor
):
    """Atomically publish one directory without replacing an entry that raced us."""
    source = os.fsencode(source_name)
    destination = os.fsencode(destination_name)
    system = platform.system()
    if system == "Darwin":
        operation = getattr(_LIBC, "renameatx_np", None)
        flag = RENAME_EXCL
    else:
        operation = getattr(_LIBC, "renameat2", None)
        flag = RENAME_NOREPLACE
    if operation is None:
        raise RuntimeError(
            "This platform cannot atomically install SwiftPods without replacing a destination"
        )
    operation.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    operation.restype = ctypes.c_int
    ctypes.set_errno(0)
    if operation(
        source_descriptor,
        source,
        destination_descriptor,
        destination,
        flag,
    ) == 0:
        return
    problem = ctypes.get_errno()
    if problem in (errno.EEXIST, errno.ENOTEMPTY):
        raise RuntimeError("Destination appeared during installation: " + destination_name)
    raise RuntimeError(
        "Cannot atomically publish the SwiftPods installation: " + os.strerror(problem)
    )


def secure_private_directory(path, mode=0o700):
    """Bind, own and remove inherited ACLs from one private real directory."""
    flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise RuntimeError("Cannot safely open private directory: " + str(path)) from error
    try:
        opened = os.fstat(descriptor)
        linked = Path(path).lstat()
        if (
            not stat.S_ISDIR(opened.st_mode)
            or opened.st_uid != os.geteuid()
            or opened.st_dev != linked.st_dev
            or opened.st_ino != linked.st_ino
        ):
            raise RuntimeError("Private directory is not an owned stable directory")
        clear_descriptor_acl(descriptor)
        os.fchmod(descriptor, mode)
        if descriptor_has_extended_acl(descriptor):
            raise RuntimeError("Private directory retains an extended access-control list")
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


@contextlib.contextmanager
def hard_deadline(seconds):
    """A process-wide hard deadline for the installer's main-thread network operation."""
    if (
        not hasattr(signal, "setitimer")
        or threading.current_thread() is not threading.main_thread()
    ):
        raise RuntimeError("This platform cannot enforce the release download time limit")

    def expired(_signal, _frame):
        raise DownloadTimeout()

    previous_handler = signal.getsignal(signal.SIGALRM)
    previous_timer = signal.getitimer(signal.ITIMER_REAL)
    if previous_timer[0] > 0:
        raise RuntimeError("Another process alarm prevents a safe release download")
    signal.signal(signal.SIGALRM, expired)
    try:
        signal.setitimer(signal.ITIMER_REAL, seconds)
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_handler)


def local_bytes(location, max_bytes, nofollow=False):
    # O_NONBLOCK makes a FIFO/device replacement reach fstat instead of hanging in open().
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NONBLOCK", 0)
    if nofollow:
        flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(location, flags)
    except OSError as error:
        raise RuntimeError("Cannot safely read local release file: " + str(location)) from error
    try:
        information = os.fstat(descriptor)
        if not stat.S_ISREG(information.st_mode):
            raise RuntimeError("Local release input must be a regular file")
        if information.st_size > max_bytes:
            raise RuntimeError("Release download exceeds the size limit")
        chunks, size = [], 0
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            while True:
                chunk = stream.read(BUFFER_SIZE)
                if not chunk:
                    break
                size += len(chunk)
                if size > max_bytes:
                    raise RuntimeError("Release download exceeds the size limit")
                chunks.append(chunk)
        final_information = os.fstat(descriptor)
        if (
            final_information.st_dev != information.st_dev
            or final_information.st_ino != information.st_ino
            or final_information.st_size != size
            or information.st_size != size
        ):
            raise RuntimeError("Local release file changed while it was being read")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def parsed_https_location(location):
    """Return a certificate hostname and origin-form target without logging the URL."""
    try:
        parts = urllib.parse.urlsplit(location)
        port = parts.port
        hostname = parts.hostname
    except (TypeError, ValueError, UnicodeError):
        raise RuntimeError("Release download has an invalid HTTPS URL") from None
    if (
        parts.scheme.lower() != "https"
        or hostname is None
        or parts.username is not None
        or parts.password is not None
        or parts.fragment
        or port not in (None, 443)
    ):
        raise RuntimeError("Release downloads require a plain HTTPS URL on port 443")
    try:
        hostname = hostname.encode("idna").decode("ascii")
    except UnicodeError:
        raise RuntimeError("Release download has an invalid HTTPS hostname") from None
    if not hostname or len(hostname) > 253 or any(
        character in hostname for character in ("\0", "\r", "\n")
    ):
        raise RuntimeError("Release download has an invalid HTTPS hostname")
    target = urllib.parse.urlunsplit(("", "", parts.path or "/", parts.query, ""))
    return hostname, target


def public_endpoints(hostname):
    """Resolve once and retain only globally routable TCP peers for this hop."""
    try:
        records = socket.getaddrinfo(
            hostname,
            443,
            family=socket.AF_UNSPEC,
            type=socket.SOCK_STREAM,
            proto=socket.IPPROTO_TCP,
        )
    except OSError:
        raise RuntimeError("Release hostname could not be resolved safely") from None
    endpoints = []
    seen = set()
    for family, socket_type, protocol, _canonical_name, socket_address in records:
        try:
            address = ipaddress.ip_address(socket_address[0])
        except ValueError:
            continue
        if (
            not address.is_global
            or address.is_private
            or address.is_loopback
            or address.is_link_local
            or address.is_multicast
            or address.is_reserved
            or address.is_unspecified
        ):
            continue
        key = (family, socket_type, protocol, socket_address)
        if key not in seen:
            seen.add(key)
            endpoints.append((family, socket_type, protocol, socket_address))
    if not endpoints:
        raise RuntimeError("Release hostname does not resolve to a public address")
    return endpoints


def request_pinned_https(hostname, target, endpoints):
    """Issue one GET to a vetted peer while retaining TLS hostname validation."""
    for endpoint in endpoints:
        connection = PinnedHTTPSConnection(
            hostname, endpoint, REMOTE_TIMEOUT_SECONDS
        )
        try:
            connection.request(
                "GET",
                target,
                headers={
                    "Accept": "application/octet-stream",
                    "Accept-Encoding": "identity",
                    "Connection": "close",
                    "User-Agent": "SwiftPodsInstaller/1",
                },
            )
            return connection, connection.getresponse()
        except (OSError, ssl.SSLError, http.client.HTTPException):
            connection.close()
    raise RuntimeError("Release download could not connect safely")


def remote_bytes(location, max_bytes):
    """Download one HTTPS object with DNS pinning and per-hop SSRF validation."""
    current = location
    redirect_codes = {301, 302, 303, 307, 308}
    try:
        for redirect_count in range(MAX_REDIRECTS + 1):
            hostname, target = parsed_https_location(current)
            endpoints = public_endpoints(hostname)
            connection, response = request_pinned_https(hostname, target, endpoints)
            try:
                if response.status in redirect_codes:
                    redirect = response.getheader("Location")
                    if redirect is None or redirect_count == MAX_REDIRECTS:
                        raise RuntimeError("Release download has an invalid redirect chain")
                    current = urllib.parse.urljoin(current, redirect)
                    # Parse before the next loop so malformed/special schemes never reach DNS.
                    parsed_https_location(current)
                    continue
                if response.status != 200:
                    raise RuntimeError("Release download returned an unexpected HTTP status")
                length = response.getheader("Content-Length")
                if length is not None:
                    try:
                        declared_length = int(length)
                    except ValueError:
                        raise RuntimeError(
                            "Release download has an invalid Content-Length"
                        ) from None
                    if declared_length < 0 or declared_length > max_bytes:
                        raise RuntimeError("Release download exceeds the size limit")
                chunks, size = [], 0
                while True:
                    chunk = response.read(BUFFER_SIZE)
                    if not chunk:
                        break
                    size += len(chunk)
                    if size > max_bytes:
                        raise RuntimeError("Release download exceeds the size limit")
                    chunks.append(chunk)
                return b"".join(chunks)
            finally:
                response.close()
                connection.close()
    except DownloadTimeout:
        raise
    except RuntimeError:
        raise
    except (OSError, ssl.SSLError, http.client.HTTPException):
        # Do not include a possibly signed redirect URL in diagnostics or causes.
        raise RuntimeError("Release download failed safely") from None
    raise RuntimeError("Release download has an invalid redirect chain")


def checked_bytes(location, expected, local=False, max_bytes=None, nofollow=False):
    if max_bytes is None:
        max_bytes = MAX_DOWNLOAD_BYTES
    if local:
        data = local_bytes(location, max_bytes, nofollow=nofollow)
    else:
        try:
            with hard_deadline(REMOTE_TIMEOUT_SECONDS):
                data = remote_bytes(location, max_bytes)
        except DownloadTimeout as error:
            raise RuntimeError("Release download exceeded the time limit") from None
    if (
        not re.fullmatch("[a-f0-9]{64}", expected)
        or hashlib.sha256(data).hexdigest() != expected
    ):
        raise RuntimeError("Release SHA-256 mismatch")
    return data


def select_asset(manifest, version, architecture=None, macos=None):
    if manifest.get("schema_version") not in (2, 3) or manifest.get("version") != version:
        raise RuntimeError("Release manifest schema/version mismatch")
    if manifest.get("schema_version") == 2 and version not in LEGACY_SCHEMA_V2_VERSIONS:
        raise RuntimeError("Release manifest schema 2 is allowed only for legacy SwiftPods versions")
    architecture = architecture or platform.machine()
    macos = macos or platform.mac_ver()[0]
    if not macos:
        raise RuntimeError("SwiftPods requires macOS")

    def numbers(value):
        components = tuple(map(int, value.split(".")))
        return components + (0,) * max(0, 3 - len(components))

    candidates = [
        asset
        for asset in manifest["assets"]
        if asset["os"] == "macos"
        and asset["architecture"] == architecture
        and numbers(asset["minimum_macos"]) <= numbers(macos)
    ]
    if not candidates:
        raise RuntimeError(
            "No compatible SwiftPods asset for macOS " + macos + " " + architecture
        )
    asset = max(candidates, key=lambda asset: numbers(asset["minimum_macos"]))
    content = asset.get("content_sha256")
    if content is not None and not re.fullmatch("[a-f0-9]{64}", content):
        raise RuntimeError("Release manifest has an invalid content SHA-256")
    return asset


def expected_publisher(manifest):
    """Return schema-v3 publisher evidence; schema v2 remains legacy-compatible."""
    if manifest.get("schema_version") == 2:
        return None
    publisher = manifest.get("publisher")
    production = (
        manifest.get("development") is False
        and manifest.get("publishable") is True
    )
    if publisher is None and not production:
        return None
    if (
        not isinstance(publisher, dict)
        or set(publisher) != {
            "authority",
            "team_id",
            "certificate_sha1",
            "certificate_sha256",
        }
        or not isinstance(publisher.get("authority"), str)
        or not publisher["authority"].startswith("Developer ID Application: ")
        or not isinstance(publisher.get("team_id"), str)
        or re.fullmatch(r"[A-Z0-9]{10}", publisher["team_id"]) is None
        or not isinstance(publisher.get("certificate_sha1"), str)
        or re.fullmatch(r"[0-9A-F]{40}", publisher["certificate_sha1"]) is None
        or not isinstance(publisher.get("certificate_sha256"), str)
        or re.fullmatch(r"[0-9a-f]{64}", publisher["certificate_sha256"]) is None
    ):
        raise RuntimeError("Release manifest has invalid Developer ID publisher evidence")
    return publisher


def extract_archive(data, staging):
    import io

    if len(data) > MAX_DOWNLOAD_BYTES:
        raise RuntimeError("Release archive exceeds the size limit")
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        members = archive.infolist()
        if len(members) > MAX_ARCHIVE_ENTRIES:
            raise RuntimeError("Release archive contains too many entries")
        declared = sum(member.file_size for member in members)
        if declared > MAX_EXPANDED_BYTES:
            raise RuntimeError("Release archive expands beyond the size limit")
        seen = set()
        expanded = 0
        for member in members:
            name = PurePosixPath(member.filename)
            if (
                name.is_absolute()
                or ".." in name.parts
                or "\\" in member.filename
                or not name.parts
                or len(name.parts) > MAX_PATH_COMPONENTS
            ):
                raise RuntimeError("Unsafe release archive path: " + member.filename)
            if member.flag_bits & 1:
                raise RuntimeError("Encrypted release archive member")
            if member.file_size > MAX_MEMBER_BYTES:
                raise RuntimeError("Release archive member exceeds the size limit")
            if name in seen:
                raise RuntimeError("Duplicate release archive path: " + member.filename)
            seen.add(name)
            destination = staging.joinpath(*name.parts)
            if not destination.resolve().is_relative_to(staging.resolve()):
                raise RuntimeError("Release archive path escapes extraction root")
            mode = member.external_attr >> 16
            if stat.S_ISLNK(mode):
                # Parent links must be evaluated before creating any member.
                if member.file_size > 4096:
                    raise RuntimeError("Release symlink target is too long")
                link = archive.read(member).decode("utf-8")
                target = (destination.parent / link).resolve()
                if Path(link).is_absolute() or not target.is_relative_to(
                    staging.resolve()
                ):
                    raise RuntimeError("Unsafe release symlink")
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.symlink_to(link)
            elif member.is_dir():
                destination.mkdir(parents=True, exist_ok=True)
                destination.chmod(0o755)
            elif stat.S_IFMT(mode) in (0, stat.S_IFREG):
                destination.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(member) as source, destination.open("xb") as stream:
                    written = 0
                    while True:
                        chunk = source.read(BUFFER_SIZE)
                        if not chunk:
                            break
                        written += len(chunk)
                        expanded += len(chunk)
                        if written > MAX_MEMBER_BYTES or expanded > MAX_EXPANDED_BYTES:
                            raise RuntimeError("Release archive expands beyond the size limit")
                        stream.write(chunk)
                    if written != member.file_size:
                        raise RuntimeError("Release archive member has an invalid size")
                # Archive modes and a permissive caller umask must never leave an authenticated payload
                # writable by another local principal after verification.
                destination.chmod(((mode & 0o777) or 0o644) & ~0o022)
            else:
                raise RuntimeError("Special file in release archive")
    # Catch a dangling link that became escaping only after another link was
    # created later in the archive, before running any extracted executable.
    for path in staging.rglob("*"):
        if not path.resolve().is_relative_to(staging.resolve()):
            raise RuntimeError("Composed release symlink escapes extraction root")
        if path.is_dir() and not path.is_symlink():
            # Also normalize implicit parent directories created for file members.
            path.chmod(0o755)
    roots = list(staging.iterdir())
    if len(roots) != 1 or not roots[0].is_dir() or roots[0].is_symlink():
        raise RuntimeError("Release archive must contain one distribution directory")
    for name in METADATA_FILES:
        reserved = roots[0] / name
        if reserved.exists() or reserved.is_symlink():
            raise RuntimeError("Release archive contains reserved installer metadata")
    return roots[0]


def distribution_digest(root, file_evidence=None):
    """A deterministic digest of payload paths, modes, symlinks and regular-file bytes."""
    root = Path(root)
    root_status = root.lstat()
    if (
        not stat.S_ISDIR(root_status.st_mode)
        or root.is_symlink()
        or root_status.st_uid != os.geteuid()
        or stat.S_IMODE(root_status.st_mode) & 0o022
    ):
        raise RuntimeError("Installed release root must be an owned non-writable real directory")
    root_descriptor = secure_private_directory(root, stat.S_IMODE(root_status.st_mode))
    os.close(root_descriptor)
    root_resolved = root.resolve()
    paths, pending = [], [root]
    while pending:
        directory = pending.pop()
        directory_status = directory.lstat()
        if (
            not stat.S_ISDIR(directory_status.st_mode)
            or directory.is_symlink()
            or directory_status.st_uid != os.geteuid()
            or stat.S_IMODE(directory_status.st_mode) & 0o022
        ):
            raise RuntimeError("Release directory changed while it was being verified")
        with os.scandir(directory) as entries:
            for entry in entries:
                path = Path(entry.path)
                relative = path.relative_to(root)
                if len(relative.parts) == 1 and relative.parts[0] in METADATA_FILES:
                    continue
                if len(relative.parts) > MAX_PATH_COMPONENTS:
                    raise RuntimeError("Installed release path is too deep")
                paths.append(path)
                if len(paths) > MAX_DISTRIBUTION_ENTRIES:
                    raise RuntimeError("Installed release contains too many entries")
                status = entry.stat(follow_symlinks=False)
                if stat.S_ISDIR(status.st_mode):
                    pending.append(path)
    digest = hashlib.sha256()
    expanded = 0
    for path in sorted(paths, key=lambda path: path.relative_to(root).as_posix()):
        relative_path = path.relative_to(root).as_posix()
        relative = relative_path.encode()
        status = path.lstat()
        if status.st_uid != os.geteuid() or (
            (stat.S_ISDIR(status.st_mode) or stat.S_ISREG(status.st_mode))
            and stat.S_IMODE(status.st_mode) & 0o022
        ):
            raise RuntimeError("Installed release contains an unsafe writable or unowned path")
        if stat.S_ISLNK(status.st_mode):
            if not path.resolve().is_relative_to(root_resolved):
                raise RuntimeError("Installed release symlink escapes its root")
            kind, mode, contents = b"L", 0, path.readlink().as_posix().encode()
        elif stat.S_ISDIR(status.st_mode):
            descriptor = os.open(
                path,
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0)
                | getattr(os, "O_NONBLOCK", 0),
            )
            try:
                opened = os.fstat(descriptor)
                if (
                    opened.st_dev != status.st_dev
                    or opened.st_ino != status.st_ino
                    or descriptor_has_extended_acl(descriptor)
                ):
                    raise RuntimeError(
                        "Release directory changed or has unsafe access controls"
                    )
            finally:
                os.close(descriptor)
            kind, mode, contents = b"D", 0, b""
        elif stat.S_ISREG(status.st_mode):
            if status.st_size > MAX_MEMBER_BYTES:
                raise RuntimeError("Installed release member exceeds the size limit")
            kind, mode = b"F", stat.S_IMODE(status.st_mode)
            file_digest = hashlib.sha256()
            read = 0
            flags = (
                os.O_RDONLY
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0)
                | getattr(os, "O_NONBLOCK", 0)
            )
            try:
                descriptor = os.open(path, flags)
            except OSError as error:
                raise RuntimeError("Release file changed while it was being verified") from error
            try:
                opened = os.fstat(descriptor)
                if (
                    not stat.S_ISREG(opened.st_mode)
                    or opened.st_dev != status.st_dev
                    or opened.st_ino != status.st_ino
                    or opened.st_size != status.st_size
                    or descriptor_has_extended_acl(descriptor)
                ):
                    raise RuntimeError(
                        "Release file changed or has unsafe access controls"
                    )
                with os.fdopen(descriptor, "rb", closefd=False) as stream:
                    while chunk := stream.read(BUFFER_SIZE):
                        read += len(chunk)
                        expanded += len(chunk)
                        if read > MAX_MEMBER_BYTES or expanded > MAX_EXPANDED_BYTES:
                            raise RuntimeError("Installed release exceeds the size limit")
                        file_digest.update(chunk)
                finished = os.fstat(descriptor)
            finally:
                os.close(descriptor)
            if (
                read != status.st_size
                or finished.st_dev != opened.st_dev
                or finished.st_ino != opened.st_ino
                or finished.st_size != opened.st_size
            ):
                raise RuntimeError("Release file changed while it was being verified")
            contents = file_digest.digest()
            if file_evidence is not None:
                file_evidence[relative_path] = {
                    "sha256": file_digest.hexdigest(),
                    "size": read,
                    "mode": mode,
                }
        else:
            raise RuntimeError("Special file in installed release")
        digest.update(kind + b"\0" + relative + b"\0")
        digest.update(str(mode).encode() + b"\0" + contents)
    return digest.hexdigest()


def copy_authenticated_executable(
    source, destination, evidence, destination_directory_descriptor=None
):
    """Copy exactly the executable bytes authenticated by the tree digest."""
    source_flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    destination_flags = (
        os.O_RDWR
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        source_descriptor = os.open(source, source_flags)
    except OSError as error:
        raise RuntimeError("Authenticated SwiftPods executable changed before it could be copied") from error
    destination_descriptor = -1
    try:
        opened = os.fstat(source_descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_size != evidence["size"]
            or stat.S_IMODE(opened.st_mode) != evidence["mode"]
        ):
            raise RuntimeError("Authenticated SwiftPods executable changed before it could be copied")
        if destination_directory_descriptor is None:
            destination_descriptor = os.open(destination, destination_flags, 0o500)
        else:
            destination_descriptor = os.open(
                destination.name,
                destination_flags,
                0o500,
                dir_fd=destination_directory_descriptor,
            )
        digest = hashlib.sha256()
        size = 0
        with (
            os.fdopen(source_descriptor, "rb", closefd=False) as input_stream,
            os.fdopen(destination_descriptor, "wb", closefd=False) as output_stream,
        ):
            while chunk := input_stream.read(BUFFER_SIZE):
                size += len(chunk)
                if size > MAX_MEMBER_BYTES:
                    raise RuntimeError("Authenticated SwiftPods executable exceeds the size limit")
                digest.update(chunk)
                output_stream.write(chunk)
            output_stream.flush()
            os.fsync(destination_descriptor)
        finished = os.fstat(source_descriptor)
        if (
            finished.st_dev != opened.st_dev
            or finished.st_ino != opened.st_ino
            or finished.st_size != opened.st_size
            or size != evidence["size"]
            or digest.hexdigest() != evidence["sha256"]
        ):
            raise RuntimeError("Authenticated SwiftPods executable changed before it could be copied")
        clear_descriptor_acl(destination_descriptor)
        os.fchmod(destination_descriptor, 0o500)
        if descriptor_has_extended_acl(destination_descriptor):
            raise RuntimeError(
                "Authenticated SwiftPods executable retains unsafe access controls"
            )
        return authenticated_executable_evidence(
            destination_descriptor, expected_sha256=evidence["sha256"]
        )
    except Exception:
        if destination_descriptor >= 0:
            try:
                if destination_directory_descriptor is None:
                    destination.unlink()
                else:
                    os.unlink(
                        destination.name, dir_fd=destination_directory_descriptor
                    )
            except FileNotFoundError:
                pass
        raise
    finally:
        os.close(source_descriptor)
        if destination_descriptor >= 0:
            os.close(destination_descriptor)


def private_runtime_directory(directory, distribution_root):
    directory = Path(os.path.abspath(directory))
    parent, parent_descriptor = trusted_parent_descriptor(directory.parent)
    directory = parent / directory.name
    flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    try:
        descriptor = os.open(directory.name, flags, dir_fd=parent_descriptor)
    except OSError as error:
        os.close(parent_descriptor)
        raise RuntimeError("Cannot safely open the private runtime directory") from error
    try:
        opened = os.fstat(descriptor)
        linked = os.stat(
            directory.name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        if (
            not stat.S_ISDIR(opened.st_mode)
            or opened.st_uid != os.geteuid()
            or stat.S_IMODE(opened.st_mode) & 0o077
            or opened.st_dev != linked.st_dev
            or opened.st_ino != linked.st_ino
        ):
            raise RuntimeError("Runtime directory must be a private owned directory")
        clear_descriptor_acl(descriptor)
        os.fchmod(descriptor, 0o700)
        if descriptor_has_extended_acl(descriptor):
            raise RuntimeError("Runtime directory retains an extended access-control list")
        resolved = directory.resolve(strict=True)
        distribution = distribution_root.resolve()
        if resolved == distribution or resolved.is_relative_to(distribution):
            raise RuntimeError("Runtime directory must be outside the installed distribution")
        if os.listdir(descriptor):
            raise RuntimeError("Runtime directory must be empty")
    except Exception:
        os.close(descriptor)
        os.close(parent_descriptor)
        raise
    return directory, descriptor, parent, parent_descriptor


def require_bound_directory(path, descriptor, parent_descriptor=None):
    """Ensure a pathname still names the directory held by `descriptor`."""
    opened = os.fstat(descriptor)
    if parent_descriptor is None:
        linked = Path(path).lstat()
    else:
        linked = os.stat(
            Path(path).name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
    if (
        not stat.S_ISDIR(linked.st_mode)
        or opened.st_dev != linked.st_dev
        or opened.st_ino != linked.st_ino
    ):
        raise RuntimeError("Private runtime directory changed during verification")


def verify_executable_publisher(
    executable, expected, temporary_parent, cwd, environment
):
    """Verify the exact leaf certificate and Team ID before first execution."""
    verification = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--strict", executable],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=60,
        cwd=cwd,
        env=environment,
        stdin=subprocess.DEVNULL,
    )
    if verification.returncode:
        raise RuntimeError("SwiftPods release has an invalid Apple code signature")
    with tempfile.TemporaryDirectory(
        prefix=".swiftpods-signature-", dir=temporary_parent
    ) as temporary:
        directory_descriptor = secure_private_directory(temporary)
        os.close(directory_descriptor)
        prefix = Path(temporary) / "certificate"
        display = subprocess.run(
            [
                "/usr/bin/codesign",
                "--display",
                "--verbose=4",
                "--extract-certificates",
                prefix,
                executable,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=60,
            cwd=cwd,
            env=environment,
            stdin=subprocess.DEVNULL,
        )
        if display.returncode:
            raise RuntimeError("Cannot inspect the SwiftPods publisher signature")
        authorities = re.findall(r"^Authority=(.+)$", display.stderr, re.M)
        team = re.search(r"^TeamIdentifier=([A-Z0-9]+)$", display.stderr, re.M)
        certificate = Path(str(prefix) + "0")
        try:
            encoded = local_bytes(certificate, 64 * 1024, nofollow=True)
        except RuntimeError as error:
            raise RuntimeError("Cannot inspect the SwiftPods publisher certificate") from error
    actual = {
        "authority": authorities[0] if authorities else "",
        "team_id": team.group(1) if team else "",
        "certificate_sha1": hashlib.sha1(encoded).hexdigest().upper(),
        "certificate_sha256": hashlib.sha256(encoded).hexdigest(),
    }
    if actual != expected:
        raise RuntimeError(
            "SwiftPods release publisher differs from the pinned certificate or Team ID"
        )


def executable_status_snapshot(current):
    return (
        current.st_dev,
        current.st_ino,
        current.st_mode,
        current.st_nlink,
        current.st_uid,
        current.st_gid,
        current.st_size,
        current.st_mtime_ns,
        current.st_ctime_ns,
    )


def executable_snapshot(descriptor):
    """Capture every stable vnode field used to authenticate a mapped image."""
    current = os.fstat(descriptor)
    if (
        descriptor <= 2
        or not stat.S_ISREG(current.st_mode)
        or current.st_uid != os.geteuid()
        or current.st_nlink != 1
        or stat.S_IMODE(current.st_mode) & 0o022
        or not stat.S_IMODE(current.st_mode) & 0o111
    ):
        raise RuntimeError("Authenticated SwiftPods runtime executable is unsafe")
    return executable_status_snapshot(current)


def authenticated_executable_evidence(descriptor, expected_sha256=None):
    """Bind exact executable bytes to one stable, safe destination vnode."""
    initial = executable_snapshot(descriptor)
    size = initial[6]
    if size < 0 or size > MAX_MEMBER_BYTES:
        raise RuntimeError("Authenticated SwiftPods runtime executable is too large")
    digest = hashlib.sha256()
    offset = 0
    while offset < size:
        chunk = os.pread(descriptor, min(BUFFER_SIZE, size - offset), offset)
        if not chunk:
            raise RuntimeError(
                "Authenticated SwiftPods runtime changed while it was being hashed"
            )
        digest.update(chunk)
        offset += len(chunk)
    if os.pread(descriptor, 1, offset):
        raise RuntimeError(
            "Authenticated SwiftPods runtime changed while it was being hashed"
        )
    final = executable_snapshot(descriptor)
    actual_sha256 = digest.hexdigest()
    if initial != final or (
        expected_sha256 is not None and actual_sha256 != expected_sha256
    ):
        raise RuntimeError(
            "Authenticated SwiftPods runtime changed while it was being hashed"
        )
    return {"snapshot": initial, "sha256": actual_sha256}


def require_authenticated_executable(descriptor, evidence):
    """Require the exact vnode snapshot established by the authenticated copy."""
    if (
        not isinstance(evidence, dict)
        or set(evidence) != {"snapshot", "sha256"}
        or not isinstance(evidence["snapshot"], tuple)
        or len(evidence["snapshot"]) != 9
        or not all(isinstance(value, int) for value in evidence["snapshot"])
        or not isinstance(evidence["sha256"], str)
        or re.fullmatch(r"[0-9a-f]{64}", evidence["sha256"]) is None
    ):
        raise RuntimeError("Authenticated SwiftPods runtime changed before execution")
    try:
        current = authenticated_executable_evidence(descriptor)
    except (OSError, RuntimeError) as error:
        raise RuntimeError(
            "Authenticated SwiftPods runtime changed before execution"
        ) from error
    if current != evidence:
        raise RuntimeError("Authenticated SwiftPods runtime changed before execution")
    return evidence["snapshot"]


def mapped_executable_matches(mapped, expected):
    return (
        mapped.device == expected[0] & 0xFFFFFFFF
        and mapped.inode == expected[1]
        and mapped.mode == expected[2] & 0xFFFF
        and mapped.link_count == expected[3]
        and mapped.user == expected[4]
        and mapped.group == expected[5]
        and mapped.size == expected[6]
        and mapped.modification_time == expected[7] // 1_000_000_000
        and mapped.modification_time_nanoseconds == expected[7] % 1_000_000_000
        and mapped.change_time == expected[8] // 1_000_000_000
        and mapped.change_time_nanoseconds == expected[8] % 1_000_000_000
    )


def sanitized_execution_environment(input_environment):
    """Preserve the build context while removing pre-entry injection hooks."""
    prefixes = (
        "GIT_",
        "DYLD_",
        "LD_",
        "CURL_",
        "BASH_FUNC_",
        "PYTHON",
    )
    exact = {
        "BASH_ENV",
        "ENV",
        "CDPATH",
        "SSH_ASKPASS",
        "SHELLOPTS",
        "BASHOPTS",
        "BASH_XTRACEFD",
        "PS4",
        "IFS",
        "TAR_OPTIONS",
        "TAR_READER_OPTIONS",
        "TAR_WRITER_OPTIONS",
        "GZIP",
        "GZIP_OPT",
        "BZIP2",
        "BZIP2OPT",
        "XZ_OPT",
        "XZ_DEFAULTS",
        "LZMA_OPT",
        "ZSTD_CLEVEL",
        "ZSTD_NBTHREADS",
        "ZSTD_WINDOWLOG",
        "SSL_CERT_FILE",
        "SSL_CERT_DIR",
        "SSLKEYLOGFILE",
    }
    environment = {
        str(name): str(value)
        for name, value in input_environment.items()
        if not str(name).startswith(prefixes) and str(name) not in exact
    }
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    environment.setdefault("LANG", "C")
    environment.setdefault("LC_ALL", "C")
    environment["SSH_ASKPASS_REQUIRE"] = "never"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    return environment


def close_descriptors(descriptors):
    for descriptor in descriptors:
        if descriptor < 0:
            continue
        try:
            os.close(descriptor)
        except OSError:
            pass


def session_process_identifiers(session_identifier):
    _LIBC.proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
    _LIBC.proc_listallpids.restype = ctypes.c_int
    capacity = 1024
    while capacity <= 262_144:
        identifiers = (ctypes.c_int * capacity)()
        ctypes.set_errno(0)
        count = _LIBC.proc_listallpids(
            identifiers, ctypes.sizeof(identifiers)
        )
        if count < 0:
            problem = ctypes.get_errno()
            raise SessionEnumerationError(
                "Cannot enumerate authenticated command descendants: "
                + os.strerror(problem)
            )
        if count < capacity:
            result = []
            for process in identifiers[:count]:
                if process <= 0:
                    continue
                try:
                    if os.getsid(process) == session_identifier:
                        result.append(process)
                except ProcessLookupError:
                    pass
                except OSError as error:
                    raise SessionEnumerationError(
                        "Cannot enumerate authenticated command descendants: "
                        + str(error)
                    ) from error
            return result
        capacity *= 2
    raise SessionEnumerationError("The process table exceeded the supported size")


def signal_spawned_session(session_identifier, command, include_leader):
    deadline = time.monotonic() + 1
    while True:
        processes = session_process_identifiers(session_identifier)
        descendants = [
            process for process in processes if process != session_identifier
        ]
        targets = descendants + (
            [session_identifier] if include_leader else []
        )
        for process in targets:
            try:
                os.kill(process, command)
            except ProcessLookupError:
                pass
        if not descendants:
            if include_leader:
                try:
                    os.kill(session_identifier, command)
                except ProcessLookupError:
                    pass
            return
        if time.monotonic() >= deadline:
            raise RuntimeError(
                "Authenticated command descendants survived forced termination"
            )
        time.sleep(0.01)


def kill_spawned_process(process_identifier):
    """Kill the isolated session before reaping its leader."""
    signal_spawned_session(process_identifier, signal.SIGKILL, True)


def reap_process(process_identifier):
    while True:
        try:
            _, status = os.waitpid(process_identifier, 0)
            return os.waitstatus_to_exitcode(status)
        except InterruptedError:
            continue


def wait_for_exit_without_reaping(process_identifier):
    """Wait for the final child status while retaining its PID identity."""
    _LIBC.waitid.argtypes = [
        ctypes.c_int,
        ctypes.c_uint32,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    _LIBC.waitid.restype = ctypes.c_int
    information = ctypes.create_string_buffer(128)
    while True:
        ctypes.set_errno(0)
        if _LIBC.waitid(1, process_identifier, information, 0x04 | 0x20) == 0:
            return
        problem = ctypes.get_errno()
        if problem == errno.EINTR:
            continue
        raise RuntimeError(
            "Cannot observe authenticated command exit: " + os.strerror(problem)
        )


def kill_spawned_descendants(process_identifier):
    """Kill anything left in the authenticated leader's isolated session."""
    signal_spawned_session(process_identifier, signal.SIGKILL, False)


@contextlib.contextmanager
def blocked_process_interrupts():
    """Defer terminal interrupts across the short PID-sensitive reap window."""
    previous_mask = None
    if hasattr(signal, "pthread_sigmask"):
        previous_mask = signal.pthread_sigmask(
            signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM}
        )
    try:
        yield
    finally:
        if previous_mask is not None:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)


def reap_spawned_process(process_identifier, lifecycle):
    """Reap and record ownership release before deferred signals can run."""
    with blocked_process_interrupts():
        returncode = reap_process(process_identifier)
        lifecycle["reaped"] = True
    return returncode


def terminate_and_reap_spawned_process(process_identifier, lifecycle):
    """Unconditionally terminate the owned session and reap its leader."""
    with blocked_process_interrupts():
        termination_error = None
        fallback_errors = []
        fallback_can_reap = False
        try:
            kill_spawned_process(process_identifier)
        except BaseException as error:
            termination_error = error
            # The leader was created with POSIX_SPAWN_SETSID. These direct
            # fallbacks keep it killable even if process-table enumeration
            # itself failed or was interrupted.
            try:
                os.killpg(process_identifier, signal.SIGKILL)
            except ProcessLookupError:
                fallback_can_reap = True
            except BaseException as fallback_error:
                fallback_errors.append(fallback_error)
            else:
                fallback_can_reap = True
            try:
                os.kill(process_identifier, signal.SIGKILL)
            except ProcessLookupError:
                fallback_can_reap = True
            except BaseException as fallback_error:
                fallback_errors.append(fallback_error)
            else:
                fallback_can_reap = True
            if not fallback_can_reap:
                raise fallback_errors[0] from termination_error
        try:
            reap_process(process_identifier)
        except ChildProcessError:
            # A deferred interrupt cannot reach the wait/reaped-state gap, but
            # tolerate an already-reaped child for defensive callers.
            pass
        lifecycle["reaped"] = True
        if fallback_errors:
            raise fallback_errors[0] from termination_error
        if termination_error is not None and not isinstance(
            termination_error, SessionEnumerationError
        ):
            raise termination_error


def authenticate_and_supervise_spawned_process(
    process,
    executable,
    descriptor,
    expected,
    stdout_read,
    stderr_read,
    owned_descriptors,
    timeout,
    maximum_output_bytes,
    lifecycle,
):
    """Authenticate a suspended child, resume it and supervise its session."""
    if os.getsid(process) != process or os.getpgid(process) != process:
        raise RuntimeError("Authenticated command has no isolated session")
    if executable_snapshot(descriptor) != expected:
        raise RuntimeError(
            "Authenticated SwiftPods runtime changed before execution"
        )
    region = DarwinProcRegionWithPathInfo()
    read = _LIBC.proc_pidinfo(
        process,
        8,
        0,
        ctypes.byref(region),
        ctypes.sizeof(region),
    )
    mapped = region.vnode.information.status
    if (
        read != ctypes.sizeof(region)
        or region.region.address == 0
        or region.region.size == 0
        or not region.region.protection & 0x04
        or stat.S_IFMT(mapped.mode) != stat.S_IFREG
        or not mapped_executable_matches(mapped, expected)
    ):
        raise RuntimeError("Spawned command mapped an unauthenticated executable")

    process_events = select.kqueue()
    try:
        process_events.control(
            [
                select.kevent(
                    process,
                    filter=select.KQ_FILTER_PROC,
                    flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE,
                    fflags=select.KQ_NOTE_EXIT,
                )
            ],
            0,
            0,
        )
        os.set_blocking(stdout_read, False)
        os.set_blocking(stderr_read, False)
        os.kill(process, signal.SIGCONT)
        deadline = time.monotonic() + timeout
        buffers = {
            stdout_read: bytearray(),
            stderr_read: bytearray(),
        }
        streams = set(buffers)
        output_size = 0
        failure = None
        exit_observed = False
        while not exit_observed and failure is None:
            if process_events.control(None, 1, 0):
                exit_observed = True
                break
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                failure = "Authenticated SwiftPods command timed out"
                break
            readable, _, _ = select.select(
                list(streams), [], [], min(remaining, 0.1)
            )
            for stream in readable:
                try:
                    chunk = os.read(stream, 64 * 1024)
                except BlockingIOError:
                    continue
                if not chunk:
                    os.close(stream)
                    owned_descriptors.discard(stream)
                    streams.remove(stream)
                    continue
                available = maximum_output_bytes - output_size
                if len(chunk) > available:
                    if available > 0:
                        buffers[stream].extend(chunk[:available])
                        output_size += available
                    failure = (
                        "Authenticated SwiftPods command output exceeded the limit"
                    )
                    break
                buffers[stream].extend(chunk)
                output_size += len(chunk)

        # Once the leader exits, no command descendants are allowed to outlive
        # the supervised invocation. Keeping the leader waitable prevents PID
        # and process-group reuse until this cleanup is complete.
        if exit_observed and failure is None:
            wait_for_exit_without_reaping(process)
            kill_spawned_descendants(process)
        else:
            kill_spawned_process(process)
        drain_deadline = time.monotonic() + 1
        while streams and time.monotonic() < drain_deadline:
            readable, _, _ = select.select(list(streams), [], [], 0.05)
            if not readable:
                continue
            for stream in readable:
                try:
                    chunk = os.read(stream, 64 * 1024)
                except BlockingIOError:
                    continue
                if not chunk:
                    os.close(stream)
                    owned_descriptors.discard(stream)
                    streams.remove(stream)
                    continue
                available = maximum_output_bytes - output_size
                if available > 0:
                    buffers[stream].extend(chunk[:available])
                    output_size += min(len(chunk), available)
                if len(chunk) > available and failure is None:
                    failure = (
                        "Authenticated SwiftPods command output exceeded the limit"
                    )

        returncode = reap_spawned_process(process, lifecycle)
        stdout = bytes(buffers[stdout_read])
        stderr = bytes(buffers[stderr_read])
        if executable_snapshot(descriptor) != expected:
            raise RuntimeError(
                "Authenticated SwiftPods runtime changed during execution"
            )
        if failure is not None:
            raise RuntimeError(failure)
        return AuthenticatedCommandResult(returncode, stdout, stderr)
    finally:
        process_events.close()


def authenticated_run(
    executable,
    descriptor,
    arguments,
    cwd,
    environment,
    timeout,
    evidence,
    maximum_output_bytes=MAX_COMMAND_OUTPUT_BYTES,
):
    """Spawn a Mach-O suspended and authenticate its mapped vnode before entry."""
    if platform.system() != "Darwin":
        raise RuntimeError("Authenticated SwiftPods execution requires macOS")
    if not timeout > 0 or not maximum_output_bytes >= 0:
        raise RuntimeError("Authenticated command limits are invalid")
    executable = str(Path(executable).absolute())
    cwd = str(Path(cwd).absolute())
    if "\0" in executable or "\0" in cwd or not executable.startswith("/"):
        raise RuntimeError("Authenticated command paths are invalid")
    arguments = [str(argument) for argument in arguments]
    if any("\0" in argument for argument in arguments):
        raise RuntimeError("Authenticated command arguments contain a NUL byte")
    if any(
        "\0" in str(name) or "\0" in str(value)
        for name, value in environment.items()
    ):
        raise RuntimeError("Authenticated command environment contains a NUL byte")

    expected = require_authenticated_executable(descriptor, evidence)
    if ctypes.sizeof(DarwinProcRegionWithPathInfo) != 1272:
        raise RuntimeError("Unsupported macOS process information layout")

    pointer = ctypes.POINTER(ctypes.c_void_p)
    _LIBC.posix_spawn_file_actions_init.argtypes = [pointer]
    _LIBC.posix_spawn_file_actions_init.restype = ctypes.c_int
    _LIBC.posix_spawn_file_actions_destroy.argtypes = [pointer]
    _LIBC.posix_spawn_file_actions_destroy.restype = ctypes.c_int
    _LIBC.posix_spawn_file_actions_adddup2.argtypes = [
        pointer,
        ctypes.c_int,
        ctypes.c_int,
    ]
    _LIBC.posix_spawn_file_actions_adddup2.restype = ctypes.c_int
    _LIBC.posix_spawn_file_actions_addclose.argtypes = [pointer, ctypes.c_int]
    _LIBC.posix_spawn_file_actions_addclose.restype = ctypes.c_int
    _LIBC.posix_spawn_file_actions_addchdir_np.argtypes = [pointer, ctypes.c_char_p]
    _LIBC.posix_spawn_file_actions_addchdir_np.restype = ctypes.c_int
    _LIBC.posix_spawnattr_init.argtypes = [pointer]
    _LIBC.posix_spawnattr_init.restype = ctypes.c_int
    _LIBC.posix_spawnattr_destroy.argtypes = [pointer]
    _LIBC.posix_spawnattr_destroy.restype = ctypes.c_int
    _LIBC.posix_spawnattr_setpgroup.argtypes = [pointer, ctypes.c_int]
    _LIBC.posix_spawnattr_setpgroup.restype = ctypes.c_int
    _LIBC.posix_spawnattr_setflags.argtypes = [pointer, ctypes.c_short]
    _LIBC.posix_spawnattr_setflags.restype = ctypes.c_int
    _LIBC.posix_spawn.argtypes = [
        ctypes.POINTER(ctypes.c_int),
        ctypes.c_char_p,
        pointer,
        pointer,
        ctypes.POINTER(ctypes.c_char_p),
        ctypes.POINTER(ctypes.c_char_p),
    ]
    _LIBC.posix_spawn.restype = ctypes.c_int
    _LIBC.proc_pidinfo.argtypes = [
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_uint64,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    _LIBC.proc_pidinfo.restype = ctypes.c_int

    stdout_read, stdout_write = os.pipe()
    stderr_read, stderr_write = os.pipe()
    null_descriptor = os.open(
        "/dev/null", os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    )
    owned_descriptors = {
        stdout_read,
        stdout_write,
        stderr_read,
        stderr_write,
        null_descriptor,
    }
    for stream in owned_descriptors:
        os.set_inheritable(stream, False)

    actions = ctypes.c_void_p()
    attributes = ctypes.c_void_p()
    actions_initialized = False
    attributes_initialized = False
    process_identifier = ctypes.c_int()
    lifecycle = {"reaped": False}
    previous_sigterm_handler = None
    if (
        threading.current_thread() is threading.main_thread()
        and signal.getsignal(signal.SIGTERM) == signal.SIG_DFL
    ):
        previous_sigterm_handler = signal.SIG_DFL

        def terminate_authenticated_command(received_signal, _frame):
            raise SystemExit(128 + received_signal)

        signal.signal(signal.SIGTERM, terminate_authenticated_command)
    try:
        result = _LIBC.posix_spawn_file_actions_init(ctypes.byref(actions))
        if result:
            raise RuntimeError(
                "Cannot initialize authenticated command file actions: "
                + os.strerror(result)
            )
        actions_initialized = True
        result = _LIBC.posix_spawnattr_init(ctypes.byref(attributes))
        if result:
            raise RuntimeError(
                "Cannot initialize authenticated command attributes: "
                + os.strerror(result)
            )
        attributes_initialized = True

        action_results = [
            _LIBC.posix_spawn_file_actions_adddup2(
                ctypes.byref(actions), null_descriptor, 0
            ),
            _LIBC.posix_spawn_file_actions_adddup2(
                ctypes.byref(actions), stdout_write, 1
            ),
            _LIBC.posix_spawn_file_actions_adddup2(
                ctypes.byref(actions), stderr_write, 2
            ),
        ]
        for stream in owned_descriptors:
            action_results.append(
                _LIBC.posix_spawn_file_actions_addclose(
                    ctypes.byref(actions), stream
                )
            )
        action_results.append(
            _LIBC.posix_spawn_file_actions_addchdir_np(
                ctypes.byref(actions), os.fsencode(cwd)
            )
        )
        failed_action = next((code for code in action_results if code), 0)
        if failed_action:
            raise RuntimeError(
                "Cannot configure authenticated command file actions: "
                + os.strerror(failed_action)
            )

        spawn_flags = 0x0080 | 0x0400 | 0x4000
        result = _LIBC.posix_spawnattr_setflags(
            ctypes.byref(attributes), spawn_flags
        )
        if result:
            raise RuntimeError(
                "Cannot suspend authenticated command before execution: "
                + os.strerror(result)
            )

        argument_bytes = [os.fsencode(executable)] + [
            os.fsencode(argument) for argument in arguments
        ]
        environment_bytes = [
            os.fsencode(str(name) + "=" + str(value))
            for name, value in sorted(environment.items())
        ]
        argument_vector = (ctypes.c_char_p * (len(argument_bytes) + 1))(
            *argument_bytes, None
        )
        environment_vector = (ctypes.c_char_p * (len(environment_bytes) + 1))(
            *environment_bytes, None
        )
        require_authenticated_executable(descriptor, evidence)
        result = _LIBC.posix_spawn(
            ctypes.byref(process_identifier),
            os.fsencode(executable),
            ctypes.byref(actions),
            ctypes.byref(attributes),
            argument_vector,
            environment_vector,
        )
        if result:
            raise RuntimeError(
                "Cannot start authenticated SwiftPods executable: "
                + os.strerror(result)
            )
        for stream in (stdout_write, stderr_write, null_descriptor):
            if stream in owned_descriptors:
                os.close(stream)
                owned_descriptors.remove(stream)
        return authenticate_and_supervise_spawned_process(
            process_identifier.value,
            executable,
            descriptor,
            expected,
            stdout_read,
            stderr_read,
            owned_descriptors,
            timeout,
            maximum_output_bytes,
            lifecycle,
        )
    except BaseException:
        if process_identifier.value != 0 and not lifecycle["reaped"]:
            terminate_and_reap_spawned_process(
                process_identifier.value, lifecycle
            )
        raise
    finally:
        with blocked_process_interrupts():
            if actions_initialized:
                _LIBC.posix_spawn_file_actions_destroy(ctypes.byref(actions))
            if attributes_initialized:
                _LIBC.posix_spawnattr_destroy(ctypes.byref(attributes))
            close_descriptors(owned_descriptors)
            owned_descriptors.clear()
            if previous_sigterm_handler is not None:
                signal.signal(signal.SIGTERM, previous_sigterm_handler)


def verify_distribution(
    root,
    version,
    expected_digest,
    runtime_directory=None,
    publisher=None,
    execute_arguments=None,
    execute_directory=None,
):
    for name in METADATA_FILES:
        metadata = root / name
        if metadata.is_symlink() or (metadata.exists() and not metadata.is_file()):
            raise RuntimeError("Unsafe installer metadata path: " + str(metadata))
    # Authenticate the complete payload before running any of it, retaining the
    # exact executable evidence so a later path replacement cannot be executed.
    evidence = {}
    if distribution_digest(root, evidence) != expected_digest:
        raise RuntimeError("Installed SwiftPods payload failed content verification")
    executable = root / "bin/swiftpods"
    executable_evidence = evidence.get("bin/swiftpods")
    if executable_evidence is None or not executable_evidence["mode"] & 0o111:
        raise RuntimeError("Release has no SwiftPods executable: " + str(executable))
    execution = None

    def probe(runtime):
        nonlocal execution
        (
            runtime,
            runtime_descriptor,
            runtime_parent,
            runtime_parent_descriptor,
        ) = private_runtime_directory(runtime, root)
        try:
            runtime_parent_identity = directory_identity(runtime_parent)
            runtime_executable = runtime / "swiftpods"
            installed = copy_authenticated_executable(
                executable,
                runtime_executable,
                executable_evidence,
                destination_directory_descriptor=runtime_descriptor,
            )
            verification = os.open(
                runtime_executable.name,
                os.O_RDONLY
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0)
                | getattr(os, "O_NONBLOCK", 0),
                dir_fd=runtime_descriptor,
            )
            try:
                verified = os.fstat(verification)
                if executable_status_snapshot(verified) != installed["snapshot"]:
                    raise RuntimeError(
                        "Authenticated SwiftPods runtime changed before execution"
                    )
                # Execute only the authenticated private copy, without inherited dynamic-loader
                # or toolchain injection variables influencing that process.
                environment = {
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "LANG": "C",
                    "LC_ALL": "C",
                }
                require_directory_identity(runtime_parent, runtime_parent_identity)
                require_bound_directory(
                    runtime, runtime_descriptor, runtime_parent_descriptor
                )
                if publisher is not None:
                    verify_executable_publisher(
                        runtime_executable,
                        publisher,
                        runtime_parent,
                        root,
                        environment,
                    )
                    require_directory_identity(runtime_parent, runtime_parent_identity)
                    require_bound_directory(
                        runtime, runtime_descriptor, runtime_parent_descriptor
                    )
                require_authenticated_executable(verification, installed)
                version_result = authenticated_run(
                    runtime_executable,
                    verification,
                    ["version", "--json"],
                    root,
                    environment,
                    60,
                    installed,
                )
                if version_result.returncode != 0:
                    raise RuntimeError(
                        "Authenticated SwiftPods version probe failed with status "
                        + str(version_result.returncode)
                    )
                try:
                    actual = json.loads(version_result.stdout)
                except (UnicodeDecodeError, json.JSONDecodeError) as error:
                    raise RuntimeError(
                        "Authenticated SwiftPods version probe returned invalid JSON"
                    ) from error
                if execute_arguments is not None:
                    require_authenticated_executable(verification, installed)
                    execution = authenticated_run(
                        runtime_executable,
                        verification,
                        execute_arguments,
                        execute_directory or root,
                        sanitized_execution_environment(os.environ),
                        COMMAND_TIMEOUT_SECONDS,
                        installed,
                    )
                final = os.stat(
                    runtime_executable.name,
                    dir_fd=runtime_descriptor,
                    follow_symlinks=False,
                )
                if (
                    executable_status_snapshot(final) != installed["snapshot"]
                    or require_authenticated_executable(verification, installed)
                    != installed["snapshot"]
                ):
                    raise RuntimeError(
                        "Authenticated SwiftPods runtime changed during execution"
                    )
                require_directory_identity(runtime_parent, runtime_parent_identity)
                require_bound_directory(
                    runtime, runtime_descriptor, runtime_parent_descriptor
                )
            finally:
                os.close(verification)
            if actual.get("version") != version:
                raise RuntimeError("Compiled SwiftPods version differs from requested release")
            return runtime_executable
        finally:
            os.close(runtime_descriptor)
            os.close(runtime_parent_descriptor)

    if runtime_directory is not None:
        return DistributionVerification(probe(runtime_directory), execution)
    # Keep the executable below a separately bound private parent. A temporary
    # directory can otherwise be created directly below a shared system temp
    # directory, which is intentionally rejected by private_runtime_directory.
    with tempfile.TemporaryDirectory(
        prefix=".swiftpods-runtime-parent-", dir=root.parent
    ) as temporary:
        runtime_parent = Path(temporary)
        runtime_parent_descriptor = secure_private_directory(runtime_parent)
        runtime_parent_identity = directory_identity(runtime_parent)
        try:
            os.mkdir("runtime", 0o700, dir_fd=runtime_parent_descriptor)
            require_directory_identity(runtime_parent, runtime_parent_identity)
            probe(runtime_parent / "runtime")
            require_directory_identity(runtime_parent, runtime_parent_identity)
        finally:
            os.close(runtime_parent_descriptor)
    return DistributionVerification(None, execution)


def digest_from_archive(data, parent):
    with tempfile.TemporaryDirectory(prefix=".swiftpods-verify-", dir=parent) as temporary:
        descriptor = secure_private_directory(temporary)
        os.close(descriptor)
        return distribution_digest(extract_archive(data, Path(temporary)))


def store_metadata(root, name, data):
    destination = root / name
    if destination.is_symlink() or (destination.exists() and not destination.is_file()):
        raise RuntimeError("Unsafe installer metadata path: " + str(destination))
    descriptor, temporary = tempfile.mkstemp(prefix="." + name + ".", dir=root)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def directory_identity(path):
    information = path.lstat()
    if not stat.S_ISDIR(information.st_mode) or path.is_symlink():
        raise RuntimeError("Installer parent must be a real directory: " + str(path))
    return information.st_dev, information.st_ino


def trusted_parent_descriptor(path):
    """Open a stable installer parent that other local principals cannot mutate."""
    resolved = Path(path).resolve(strict=True)
    flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    try:
        descriptor = os.open(resolved, flags)
    except OSError as error:
        raise RuntimeError("Cannot safely open the installer parent") from error
    try:
        opened = os.fstat(descriptor)
        linked = resolved.lstat()
        if (
            not stat.S_ISDIR(opened.st_mode)
            or opened.st_uid != os.geteuid()
            or stat.S_IMODE(opened.st_mode) & 0o022
            or opened.st_dev != linked.st_dev
            or opened.st_ino != linked.st_ino
            or descriptor_has_extended_acl(descriptor)
        ):
            raise RuntimeError(
                "Installer parent must be an owned stable directory without shared writes or extended ACLs"
            )
        return resolved, descriptor
    except Exception:
        os.close(descriptor)
        raise


def prepare_trusted_parent(path):
    """Create a private missing parent, then bind and validate its final inode."""
    path = Path(path)
    existing = path
    missing = []
    while True:
        try:
            existing.lstat()
            break
        except FileNotFoundError:
            if existing == existing.parent:
                raise RuntimeError("Cannot find a trusted installer parent") from None
            missing.append(existing.name)
            existing = existing.parent
    current, descriptor = trusted_parent_descriptor(existing)
    try:
        for component in reversed(missing):
            try:
                os.mkdir(component, 0o700, dir_fd=descriptor)
            except FileExistsError:
                pass
            child = os.open(
                component,
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0)
                | getattr(os, "O_NONBLOCK", 0),
                dir_fd=descriptor,
            )
            opened = os.fstat(child)
            if (
                not stat.S_ISDIR(opened.st_mode)
                or opened.st_uid != os.geteuid()
                or stat.S_IMODE(opened.st_mode) & 0o022
                or descriptor_has_extended_acl(child)
            ):
                os.close(child)
                raise RuntimeError(
                    "Installer parent must be owned without shared writes or extended ACLs"
                )
            os.close(descriptor)
            descriptor = child
            current /= component
        return current, descriptor
    except Exception:
        os.close(descriptor)
        raise


def descriptor_entry_status(directory_descriptor, name):
    try:
        return os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
    except FileNotFoundError:
        return None


def require_directory_identity(path, expected):
    try:
        actual = directory_identity(path)
    except (OSError, RuntimeError) as error:
        raise RuntimeError("Installer parent changed during installation: " + str(path)) from error
    if actual != expected:
        raise RuntimeError("Installer parent changed during installation: " + str(path))


def remove_staging(staging, parent, parent_identity, staging_identity=None):
    require_directory_identity(parent, parent_identity)
    if staging.parent != parent or not staging.name.startswith(".swiftpods-install-"):
        raise RuntimeError("Refusing unsafe installer cleanup: " + str(staging))
    information = staging.lstat()
    if (
        not stat.S_ISDIR(information.st_mode)
        or staging.is_symlink()
        or (
            staging_identity is not None
            and (information.st_dev, information.st_ino) != staging_identity
        )
    ):
        raise RuntimeError("Refusing unsafe installer cleanup: " + str(staging))
    shutil.rmtree(staging)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--manifest-sha256", required=True)
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument(
        "--runtime-directory", type=Path,
        help="Private empty directory that receives the authenticated executable used by the caller",
    )
    parser.add_argument(
        "--manifest", type=Path, help="Local release manifest for offline installation"
    )
    parser.add_argument(
        "--archive", type=Path, help="Local release archive for offline installation"
    )
    parser.add_argument(
        "--offline",
        action="store_true",
        help="Verify an existing installation from its pinned cached manifest without network access",
    )
    parser.add_argument(
        "--execute",
        nargs=argparse.REMAINDER,
        help="Run the authenticated private snapshot with the remaining arguments",
    )
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?", args.version):
        parser.error("Version must be an explicit release version without a leading v")
    if bool(args.manifest) != bool(args.archive):
        parser.error("Local installation requires both --manifest and --archive")
    if args.execute == []:
        parser.error("--execute requires a SwiftPods command")

    def finish(verification, fallback):
        if args.execute is None:
            print(verification.executable or fallback)
            return
        result = verification.execution
        if result is None:
            raise RuntimeError("Authenticated SwiftPods command was not executed")
        for stream, contents in (
            (sys.stdout, result.stdout),
            (sys.stderr, result.stderr),
        ):
            target = getattr(stream, "buffer", None)
            if target is not None:
                target.write(contents)
                target.flush()
            else:
                stream.write(contents.decode("utf-8", errors="replace"))
                stream.flush()
        if result.returncode:
            raise SystemExit(
                result.returncode if result.returncode > 0 else 128 - result.returncode
            )
    url = (
        "https://github.com/swiftpods-org/swiftpods/releases/download/v"
        + args.version
        + "/release.json"
    )
    prefix = Path(os.path.abspath(args.prefix))
    if prefix.parent.exists() or prefix.parent.is_symlink():
        parent, parent_descriptor = trusted_parent_descriptor(prefix.parent)
        os.close(parent_descriptor)
        prefix = parent / prefix.name
    if args.offline and not args.manifest:
        if not prefix.is_dir() or prefix.is_symlink():
            raise RuntimeError(
                "SwiftPods is not cached. Run once without --offline to install the pinned CLI."
            )
        cached_manifest = prefix / CACHED_MANIFEST
        if cached_manifest.is_symlink() or not cached_manifest.is_file():
            raise RuntimeError(
                "This legacy SwiftPods cache has no authenticated manifest; run once online to upgrade it."
            )
        manifest_data = checked_bytes(
            str(cached_manifest), args.manifest_sha256, local=True, max_bytes=MAX_MANIFEST_BYTES,
            nofollow=True,
        )
    else:
        manifest_data = checked_bytes(
            str(args.manifest or url), args.manifest_sha256, local=bool(args.manifest), max_bytes=MAX_MANIFEST_BYTES
        )
    manifest = json.loads(manifest_data)
    if not args.manifest and (
        manifest.get("development") is not False
        or manifest.get("publishable") is not True
    ):
        raise RuntimeError("Downloaded manifest is not a publishable SwiftPods release")
    publisher = expected_publisher(manifest)
    asset = select_asset(manifest, args.version)
    receipt = {
        "version": args.version,
        "manifest_sha256": args.manifest_sha256,
        "archive_sha256": asset["sha256"],
    }
    if prefix.exists() or prefix.is_symlink():
        path = prefix / ".installation.json"
        existing_receipt = None
        if not prefix.is_symlink():
            try:
                existing_receipt = json.loads(
                    local_bytes(path, MAX_MANIFEST_BYTES, nofollow=True)
                )
            except (RuntimeError, json.JSONDecodeError):
                pass
        if (
            prefix.is_symlink()
            or path.is_symlink()
            or not path.is_file()
            or existing_receipt != receipt
        ):
            raise RuntimeError(
                "Destination exists and is not this exact release: " + str(prefix)
            )
        expected_content = asset.get("content_sha256")
        archive_data = None
        if expected_content is None:
            cached_archive = prefix / CACHED_ARCHIVE
            if cached_archive.is_file() and not cached_archive.is_symlink():
                try:
                    archive_data = checked_bytes(
                        str(cached_archive), asset["sha256"], local=True, nofollow=True
                    )
                except RuntimeError:
                    if args.offline:
                        raise RuntimeError(
                            "Cached release evidence is invalid; run once online to repair it."
                        )
            if archive_data is None:
                if args.offline:
                    raise RuntimeError(
                        "This legacy SwiftPods cache needs one online verification before offline reuse."
                    )
                archive_data = checked_bytes(
                    str(args.archive or asset["url"]),
                    asset["sha256"],
                    local=bool(args.archive),
                )
            expected_content = digest_from_archive(archive_data, prefix.parent)
        verification = verify_distribution(
            prefix, args.version, expected_content, args.runtime_directory,
            publisher=publisher,
            execute_arguments=args.execute,
            execute_directory=Path.cwd(),
        )
        store_metadata(prefix, CACHED_MANIFEST, manifest_data)
        if archive_data is not None:
            store_metadata(prefix, CACHED_ARCHIVE, archive_data)
        finish(verification, prefix / "bin/swiftpods")
        return
    if args.offline and not args.manifest:
        raise RuntimeError(
            "SwiftPods is not cached. Run once without --offline to install the pinned CLI."
        )
    data = checked_bytes(
        str(args.archive or asset["url"]), asset["sha256"], local=bool(args.archive)
    )
    parent, parent_descriptor = prepare_trusted_parent(prefix.parent)
    prefix = parent / prefix.name
    parent_identity = directory_identity(parent)
    if descriptor_entry_status(parent_descriptor, prefix.name) is not None:
        os.close(parent_descriptor)
        raise RuntimeError("Destination appeared during installation: " + str(prefix))
    staging = Path(tempfile.mkdtemp(prefix=".swiftpods-install-", dir=parent))
    staging_descriptor = secure_private_directory(staging)
    staging_identity = directory_identity(staging)
    try:
        root = extract_archive(data, staging)
        expected_content = asset.get("content_sha256") or distribution_digest(root)
        verification = verify_distribution(
            root,
            args.version,
            expected_content,
            None if args.execute is not None else args.runtime_directory,
            publisher=publisher,
        )
        store_metadata(
            root,
            INSTALLATION_RECEIPT,
            (json.dumps(receipt, indent=2) + "\n").encode(),
        )
        store_metadata(root, CACHED_MANIFEST, manifest_data)
        store_metadata(root, CACHED_ARCHIVE, data)
        require_directory_identity(parent, parent_identity)
        bound_parent = os.fstat(parent_descriptor)
        if (bound_parent.st_dev, bound_parent.st_ino) != parent_identity:
            raise RuntimeError("Installer parent changed during installation: " + str(parent))
        if descriptor_entry_status(parent_descriptor, prefix.name) is not None:
            raise RuntimeError("Destination appeared during installation: " + str(prefix))
        root_information = root.lstat()
        rename_directory_no_replace(
            root.name,
            prefix.name,
            staging_descriptor,
            parent_descriptor,
        )
        installed = descriptor_entry_status(parent_descriptor, prefix.name)
        if installed is None or (
            installed.st_dev,
            installed.st_ino,
        ) != (root_information.st_dev, root_information.st_ino):
            raise RuntimeError("Installed release changed during final placement")
        os.fsync(parent_descriptor)
    finally:
        os.close(staging_descriptor)
        try:
            remove_staging(staging, parent, parent_identity, staging_identity)
        finally:
            os.close(parent_descriptor)
    if args.execute is not None:
        verification = verify_distribution(
            prefix,
            args.version,
            expected_content,
            args.runtime_directory,
            publisher=publisher,
            execute_arguments=args.execute,
            execute_directory=Path.cwd(),
        )
    finish(verification, prefix / "bin/swiftpods")


if __name__ == "__main__":
    main()
