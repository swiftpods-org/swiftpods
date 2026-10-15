#!/usr/bin/env python3
"""Prepare SwiftPods' own DSL adapter; no third-party engine or gems are installed."""
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile
import uuid
from ruby_runtime import clean_environment, select_ruby

ROOT = Path(__file__).resolve().parents[1]
PREFIX = ROOT / '.runtime'
PROFILE = json.loads((ROOT / 'Profiles/baseline.json').read_text())


def environment(destination=None):
    ruby, _ = select_ruby(PROFILE)
    env = clean_environment(os.environ)
    env.update(SWIFTPODS_RUBY=str(ruby), SWIFTPODS_BUNDLE=str(destination or PREFIX))
    return env


def relocate_scripts(destination):
    pass  # Native distributions contain no generated gem executables.


def relocate_extensions(destination):
    pass  # The DSL adapter uses no native gem extensions.


def manifest(destination):
    files = {}
    for path in sorted(destination.rglob('*')):
        if path.parent == destination and path.name in ('compatibility.json', 'compatibility.cms'):
            continue
        relative = path.relative_to(destination).as_posix()
        if path.is_symlink():
            if not path.resolve().is_relative_to(destination.resolve()):
                raise RuntimeError('Bundle symlink escapes: ' + relative)
            files[relative] = {'symlink': os.readlink(path)}
        elif path.is_file():
            files[relative] = {'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
    if any(name.startswith(('vendor/', 'gems/', 'runtime/')) or name == 'host/host.rb' for name in files):
        raise RuntimeError('Native distributions must not contain a third-party engine or bundled Ruby')
    result = dict(PROFILE)
    result['files'] = files
    result['bundle_digest'] = hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()
    result['build_host'] = {'os': platform.mac_ver()[0], 'architecture': platform.machine()}
    result['native_ruby_libraries'] = []
    minimum = (13, 0)
    for path in destination.rglob('*'):
        if path.is_file() and not path.is_symlink() and path.read_bytes()[:4] in (b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe'):
            output = subprocess.check_output(['xcrun', 'vtool', '-show-build', str(path)], text=True)
            for value in re.findall(r'\bminos\s+([0-9.]+)', output):
                minimum = max(minimum, tuple(map(int, value.split('.'))))
    result['minimum_macos'] = '.'.join(map(str, minimum))
    from reporting import source_digest, contract_digest, source_revision, toolchain_identity
    result['toolchain'] = toolchain_identity()
    tested_source, contract = source_digest(), contract_digest()
    result['swiftpods_source'] = {'base_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(), 'worktree_has_changes': bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT)), 'files_digest': tested_source}
    registry = json.loads((ROOT / 'Profiles/contract.json').read_text())
    result['contract_digest'] = contract
    evidence, current = [], {}
    for name in ['native-units.json'] + [suite['report'] for suite in registry['suites']]:
        path = ROOT / 'test-results' / name
        if not path.exists():
            continue
        report = json.loads(path.read_text())
        if report.get('status') == 'passed' and report.get('source_digest') == tested_source and report.get('contract_digest') == contract and report.get('source_revision') == source_revision() and report.get('host') == result['build_host'] and report.get('toolchain') == result['toolchain']:
            current[name] = report
            evidence.append({'report': name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'verified': report.get('verified', []), 'unverified': report.get('unverified', [])})
    result['verification_evidence'] = {'reports': evidence, 'source_digest': tested_source, 'contract_digest': contract, 'scope': registry['coverage_policy'], 'stable_acceptance': 'not_established'}
    result['matrix'] = [dict(row, status='build_passed', evidence='native-platforms.json') for row in current.get('native-platforms.json', {}).get('builds', [])]
    result['matrix'] += [dict(row, status='unsigned_archive_passed', evidence='native-platforms.json') for row in current.get('native-platforms.json', {}).get('archives', [])]
    result['matrix'] += [dict(row, status='application_executed', evidence='native-swift-binary.json') for row in current.get('native-swift-binary.json', {}).get('executions', [])]
    result['gems'] = []
    (destination / 'compatibility.json').write_text(json.dumps(result, indent=2) + '\n')


def main():
    select_ruby(PROFILE)
    staging = Path(tempfile.mkdtemp(prefix='.native-runtime-', dir=ROOT))
    try:
        shutil.copytree(ROOT / 'Runtime', staging / 'host')
        (staging / 'licenses').mkdir()
        manifest(staging)
        if PREFIX.exists():
            backup = ROOT / '.build' / 'previous-runtime'
            backup.mkdir(parents=True, exist_ok=True)
            PREFIX.rename(backup / uuid.uuid4().hex)
        staging.rename(PREFIX)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    print('Prepared native Swift engine adapter:', PREFIX)


if __name__ == '__main__':
    main()
