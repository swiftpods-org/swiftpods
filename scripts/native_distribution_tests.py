#!/usr/bin/env python3
"""Check the native archive inventory, relocation and pinned local installer."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from bootstrap import ROOT, environment
from reporting import execute


def main():
    bundle = Path(sys.argv[1]).resolve()
    manifest = json.loads((bundle / 'compatibility.json').read_text())
    assert manifest['engine'] == 'swift'
    assert manifest['gems'] == [] and manifest['native_ruby_libraries'] == []
    assert not any(name.startswith(('vendor/', 'gems/', 'runtime/')) for name in manifest['files'])
    assert 'host/dsl.rb' in manifest['files'] and 'host/host.rb' not in manifest['files']
    parent = Path(tempfile.mkdtemp(prefix='native-distribution-', dir=ROOT / '.build'))
    relocated = parent / 'relocated' / 'SwiftPods'
    relocated.parent.mkdir()
    shutil.copytree(bundle, relocated, symlinks=True)
    env = environment(relocated)
    subprocess.run([str(relocated / 'bin/swiftpods'), 'runtime', 'verify', '--json'], env=env, check=True, stdout=subprocess.DEVNULL)
    release = parent / 'release'
    subprocess.run([sys.executable, 'scripts/release.py', '--development', '--version', manifest['swiftpods_version'], '--bundle', str(relocated), '--destination', str(release)], cwd=ROOT, check=True)
    released = json.loads((release / 'release.json').read_text())
    assert released['development'] and not released['publishable']
    assert all(asset['url'].startswith('https://github.com/swiftpods-org/swiftpods-release/releases/') for asset in released['assets'])
    sha = hashlib.sha256((release / 'release.json').read_bytes()).hexdigest()
    prefix = parent / 'installed'
    arguments = [sys.executable, str(release / 'install.py'), '--version', manifest['swiftpods_version'], '--manifest-sha256', sha, '--manifest', str(release / 'release.json'), '--archive', str(release / released['assets'][0]['filename']), '--prefix', str(prefix)]
    subprocess.run(arguments, env=env, check=True)
    subprocess.run(arguments, env=env, check=True)
    result = subprocess.run(arguments[:arguments.index('--manifest-sha256')+1] + ['0'*64] + arguments[arguments.index('--manifest-sha256')+2:], env=env, capture_output=True)
    assert result.returncode != 0
    (relocated / 'host/dsl.rb').write_text('# tampered\n')
    result = subprocess.run([str(relocated / 'bin/swiftpods'), 'runtime', 'verify', '--json'], env=env, capture_output=True)
    assert result.returncode != 0
    (ROOT / 'test-results/native-distribution.json').write_text(json.dumps({'status': 'passed', 'engine': 'swift', 'verified': ['runtime inventory excludes reference engine/gems', 'relocation', 'release URLs', 'checksummed installer', 'idempotent install', 'bad checksum rejected', 'tampered adapter rejected'], 'unverified': ['remote publication', 'Homebrew installation', 'signing', 'Intel']}, indent=2) + '\n')


if __name__ == '__main__':
    execute(main, 'native-distribution.json')
