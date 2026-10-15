#!/usr/bin/env python3
"""Install a pinned SwiftPods release into a private prefix. Requires external Ruby.

The release manifest SHA-256 is required and must come from the caller's pinned
configuration. Never installs Ruby, modifies shell profiles or replaces a prefix
owned by another installation.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import stat
import subprocess
import tempfile
import urllib.request
import zipfile


def checked_bytes(location, expected, local=False):
    if local:
        data = Path(location).read_bytes()
    else:
        if not location.startswith('https://'):
            raise RuntimeError('Release downloads require HTTPS')
        with urllib.request.urlopen(location, timeout=120) as response:
            if not response.url.startswith('https://'):
                raise RuntimeError('Release download redirected away from HTTPS')
            data = response.read()
    if not re.fullmatch('[a-f0-9]{64}', expected) or hashlib.sha256(data).hexdigest() != expected:
        raise RuntimeError('Release SHA-256 mismatch')
    return data


def select_asset(manifest, version, architecture=None, macos=None):
    if manifest.get('schema_version') != 1 or manifest.get('version') != version:
        raise RuntimeError('Release manifest schema/version mismatch')
    architecture = architecture or platform.machine()
    macos = macos or platform.mac_ver()[0]
    if not macos:
        raise RuntimeError('SwiftPods requires macOS')
    numbers = lambda value: tuple(map(int, value.split('.')))
    candidates = [asset for asset in manifest['assets'] if asset['os'] == 'macos'
                  and asset['architecture'] == architecture
                  and numbers(asset['minimum_macos']) <= numbers(macos)]
    if not candidates:
        raise RuntimeError('No compatible SwiftPods asset for macOS ' + macos + ' ' + architecture)
    return max(candidates, key=lambda asset: numbers(asset['minimum_macos']))


def extract_archive(data, staging):
    import io
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        seen = set()
        for member in archive.infolist():
            name = PurePosixPath(member.filename)
            if name.is_absolute() or '..' in name.parts or '\\' in member.filename or not name.parts:
                raise RuntimeError('Unsafe release archive path: ' + member.filename)
            if name in seen:
                raise RuntimeError('Duplicate release archive path: ' + member.filename)
            seen.add(name)
            destination = staging.joinpath(*name.parts)
            if not destination.resolve().is_relative_to(staging.resolve()):
                raise RuntimeError('Release archive path escapes extraction root')
            mode = member.external_attr >> 16
            if stat.S_ISLNK(mode):
                # Parent links must be evaluated before creating any member.
                link = archive.read(member).decode('utf-8')
                target = (destination.parent / link).resolve()
                if Path(link).is_absolute() or not target.is_relative_to(staging.resolve()):
                    raise RuntimeError('Unsafe release symlink')
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.symlink_to(link)
            elif member.is_dir():
                destination.mkdir(parents=True, exist_ok=True)
            elif stat.S_IFMT(mode) in (0, stat.S_IFREG):
                destination.parent.mkdir(parents=True, exist_ok=True)
                with destination.open('xb') as stream:
                    stream.write(archive.read(member))
                destination.chmod((mode & 0o777) or 0o644)
            else:
                raise RuntimeError('Special file in release archive')
    # Catch a dangling link that became escaping only after another link was
    # created later in the archive, before running any extracted executable.
    for path in staging.rglob('*'):
        if not path.resolve().is_relative_to(staging.resolve()):
            raise RuntimeError('Composed release symlink escapes extraction root')
    roots = list(staging.iterdir())
    if len(roots) != 1 or not roots[0].is_dir() or roots[0].is_symlink():
        raise RuntimeError('Release archive must contain one distribution directory')
    return roots[0]


def verify_distribution(root, version):
    # A caller may have a development bundle selected in its environment.
    # Always verify the exact payload being installed, including on retries.
    env = {**os.environ, 'SWIFTPODS_BUNDLE': str(root)}
    subprocess.run([str(root / 'bin/swiftpods'), 'runtime', 'verify', '--json'], env=env, check=True, timeout=60)
    actual = json.loads(subprocess.check_output([str(root / 'bin/swiftpods'), 'version', '--json'], env=env, timeout=60))
    if actual['swiftpods_version'] != version:
        raise RuntimeError('Compiled SwiftPods version differs from requested release')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--manifest-sha256', required=True)
    parser.add_argument('--prefix', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, help='Local release manifest for offline installation')
    parser.add_argument('--archive', type=Path, help='Local release archive for offline installation')
    args = parser.parse_args()
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?', args.version):
        parser.error('Version must be an explicit release version without a leading v')
    if bool(args.manifest) != bool(args.archive):
        parser.error('Local installation requires both --manifest and --archive')
    url = 'https://github.com/swiftpods-org/swiftpods-release/releases/download/v' + args.version + '/release.json'
    manifest = json.loads(checked_bytes(str(args.manifest or url), args.manifest_sha256, local=bool(args.manifest)))
    asset = select_asset(manifest, args.version)
    prefix = args.prefix.absolute()
    receipt = {'version': args.version, 'manifest_sha256': args.manifest_sha256, 'archive_sha256': asset['sha256']}
    if prefix.exists() or prefix.is_symlink():
        path = prefix / '.installation.json'
        if prefix.is_symlink() or not path.is_file() or json.loads(path.read_text()) != receipt:
            raise RuntimeError('Destination exists and is not this exact release: ' + str(prefix))
        verify_distribution(prefix / 'libexec', args.version)
        print(prefix / 'bin/swiftpods')
        return
    data = checked_bytes(str(args.archive or asset['url']), asset['sha256'], local=bool(args.archive))
    prefix.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='.swiftpods-install-', dir=prefix.parent))
    try:
        root = extract_archive(data, staging)
        metadata = json.loads((root / 'compatibility.json').read_text())
        if (metadata['swiftpods_version'] != args.version or metadata['runtime']['mode'] != 'external'
                or (root / 'runtime').exists() or metadata['build_host']['architecture'] != asset['architecture']
                or metadata['minimum_macos'] != asset['minimum_macos']):
            raise RuntimeError('Release bundle metadata does not match its manifest')
        # Swift's signature and complete inventory verification runs before
        # the external Ruby compatibility probe, with no project evaluation.
        verify_distribution(root, args.version)
        (root / '.installation.json').write_text(json.dumps(receipt, indent=2) + '\n')
        # Keep the installation receipt outside the verified distribution.
        payload = staging / 'prefix'
        payload.mkdir()
        (root / '.installation.json').rename(payload / '.installation.json')
        root.rename(payload / 'libexec')
        (payload / 'bin').mkdir()
        (payload / 'bin/swiftpods').symlink_to('../libexec/bin/swiftpods')
        payload.rename(prefix)
    finally:
        shutil.rmtree(staging)
    print(prefix / 'bin/swiftpods')


if __name__ == '__main__':
    main()
