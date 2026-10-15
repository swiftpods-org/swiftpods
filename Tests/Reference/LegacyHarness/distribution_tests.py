#!/usr/bin/env python3
"""Exercise the actual release installer, checksum failures and archive guards."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile
from integration import ROOT, RUBY, environment
from install import extract_archive, select_asset


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    args = parser.parse_args()
    directory = Path(tempfile.mkdtemp(prefix='distribution-', dir=ROOT / '.build'))
    version = json.loads((args.bundle / 'compatibility.json').read_text())['swiftpods_version']
    release = directory / 'release'
    subprocess.run([sys.executable, str(ROOT / 'scripts/release.py'), '--version', version,
                    '--bundle', str(args.bundle), '--destination', str(release)], check=True)
    manifest_path = release / 'release.json'
    manifest = json.loads(manifest_path.read_text())
    checksum = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    asset = select_asset(manifest, version)
    prefix = directory / 'installed with spaces'
    env = environment(directory)
    env['SWIFTPODS_BUNDLE'] = '/nonexistent/unrelated-bundle'
    base = [sys.executable, str(ROOT / 'scripts/install.py'), '--version', version,
            '--manifest-sha256', checksum, '--manifest', str(manifest_path),
            '--archive', str(release / asset['filename']), '--prefix', str(prefix)]
    subprocess.run(base, env=env, check=True, capture_output=True)
    executable = prefix / 'bin/swiftpods'
    installed_env = {key: value for key, value in env.items() if key != 'SWIFTPODS_BUNDLE'}
    result = json.loads(subprocess.check_output([str(executable), 'runtime', 'verify', '--json'], env=installed_env))
    assert result['runtime_mode'] == 'external' and result['ruby']['path'] == str(RUBY)
    assert not (prefix / 'libexec/runtime').exists()
    assert executable.is_symlink() and executable.resolve().is_file()
    subprocess.run(base, env=env, check=True, capture_output=True)  # idempotent exact release

    def fails(arguments, message):
        result = subprocess.run(arguments, env=env, capture_output=True, timeout=60)
        assert result.returncode != 0 and message.encode() in result.stderr, result.stderr.decode()

    changed = list(base)
    changed[changed.index('--manifest-sha256') + 1] = '0' * 64
    fails(changed, 'SHA-256 mismatch')
    bad = directory / 'bad.zip'
    bad.write_bytes((release / asset['filename']).read_bytes() + b'corruption')
    changed = list(base)
    changed[changed.index('--archive') + 1] = str(bad)
    changed[changed.index('--prefix') + 1] = str(directory / 'bad-install')
    fails(changed, 'SHA-256 mismatch')
    assert not (directory / 'bad-install').exists()
    existing = directory / 'unrelated'
    existing.mkdir()
    (existing / 'keep').write_text('preserved')
    changed = list(base)
    changed[changed.index('--prefix') + 1] = str(existing)
    fails(changed, 'Destination exists')
    assert (existing / 'keep').read_text() == 'preserved'
    # The generated formula is valid Ruby, with short name swiftpods and an
    # explicit interpreter dependency/wrapper, never an embedded interpreter.
    formula = release / 'homebrew-tap/Formula/swiftpods.rb'
    subprocess.run([str(RUBY), '-c', str(formula)], check=True)
    assert 'depends_on "ruby@3.4"' in formula.read_text()
    assert 'write_env_script' in formula.read_text()

    def malicious(members):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, 'w') as archive:
            for name, data, symlink in members:
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = ((stat.S_IFLNK if symlink else stat.S_IFREG) | 0o755) << 16
                archive.writestr(info, data)
        staging = directory / ('malicious-' + str(len(list(directory.glob('malicious-*')))))
        staging.mkdir()
        try:
            extract_archive(stream.getvalue(), staging)
        except RuntimeError:
            return
        raise AssertionError('Unsafe release archive was accepted')

    malicious([('../outside', 'bad', False)])
    malicious([('/outside', 'bad', False)])
    malicious([('Bundle/link', '../../outside', True)])
    malicious([('Bundle/link', 'alias/../outside', True), ('Bundle/alias', '..', True)])
    # An unsupported host cannot silently select another architecture/build.
    try:
        select_asset(manifest, version, architecture='wrong-arch')
    except RuntimeError:
        pass
    else:
        raise AssertionError('Wrong architecture was accepted')
    try:
        select_asset(manifest, version, macos='10.0')
    except RuntimeError:
        pass
    else:
        raise AssertionError('Unsupported macOS was accepted')
    report = {'schema_version': 1, 'status': 'passed', 'verified': [
        'release_assets_and_checksums', 'installer_into_private_prefix', 'path_with_spaces', 'external_ruby_only',
        'idempotent_exact_release', 'inherited_bundle_selection_ignored', 'bad_manifest_and_archive_rejected', 'unrelated_prefix_preserved',
        'homebrew_formula_syntax', 'homebrew_external_dependency', 'traversal_and_composed_symlinks_rejected',
        'unsupported_os_and_architecture_rejected']}
    (ROOT / 'test-results/distribution.json').write_text(json.dumps(report, indent=2) + '\n')
    print('Passed release/installer checks')


if __name__ == '__main__':
    from reporting import execute
    execute(main, 'distribution.json')
