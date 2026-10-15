"""Invalidate previous evidence before a run and record failure as well as success."""
import datetime
import hashlib
import json
from pathlib import Path
import platform
import sys
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def source_revision():
    return {'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
            'dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT))}


def source_digest():
    files = {}
    for name in ['Sources', 'Runtime', 'Tests', 'scripts', 'Profiles', '.github', 'action.yml', 'Package.swift', 'Gemfile', 'Gemfile.lock', 'README.md', 'docs']:
        root = ROOT / name
        paths = [root] if root.is_file() else sorted(root.rglob('*'))
        for path in paths:
            if path.is_file() and '__pycache__' not in path.parts:
                files[path.relative_to(ROOT).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    return hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()


def contract_digest():
    files = [ROOT / 'Profiles/contract.json', ROOT / 'Runtime/attributes.json', ROOT / 'docs/SwiftPods-Specification-v0.1.md']
    return hashlib.sha256(json.dumps({str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in files if path.is_file()}, sort_keys=True).encode()).hexdigest()


def binary_identity():
    path = ROOT / '.build/debug/swiftpods'
    if '--bundle' in sys.argv:
        path = Path(sys.argv[sys.argv.index('--bundle') + 1]).resolve() / 'bin/swiftpods'
    elif Path(sys.argv[0]).name == 'native_distribution_tests.py' and len(sys.argv) > 1:
        path = Path(sys.argv[1]).resolve() / 'bin/swiftpods'
    return {'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()} if path.is_file() else None


def execute(main, name):
    path = ROOT / 'test-results' / name
    path.parent.mkdir(exist_ok=True)
    started = time.monotonic()
    metadata = {'schema_version': 1, 'status': 'running', 'command': sys.argv,
                'source_digest': source_digest(), 'contract_digest': contract_digest(),
                'source_revision': source_revision(),
                'started_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'host': {'os': platform.mac_ver()[0], 'architecture': platform.machine()},
                'toolchain': {name: subprocess.check_output(command, cwd=ROOT, text=True, stderr=subprocess.STDOUT).strip()
                              for name, command in [('xcode', ['xcodebuild', '-version']), ('swift', ['swift', '--version'])]}}
    def write(value):
        temporary = path.with_suffix('.pending')
        temporary.write_text(json.dumps(value, indent=2) + '\n')
        temporary.replace(path)
    write(metadata)
    try:
        main()
        if source_digest() != metadata['source_digest']:
            raise RuntimeError('Sources changed during verification; rerun against a fixed source snapshot')
        result = json.loads(path.read_text())
        if result.get('status') in (None, 'running'):
            result['status'] = 'passed'
        result.update({key: value for key, value in metadata.items() if key != 'status'})
        result['duration_seconds'] = time.monotonic() - started
        result['executable'] = binary_identity()
        write(result)
    except SystemExit as error:
        metadata.update(status='skipped' if error.code in (None, 0) else 'failed',
                        error='Exited before test evidence was completed: ' + str(error.code), duration_seconds=time.monotonic() - started)
        write(metadata)
        raise
    except BaseException as error:
        current = json.loads(path.read_text())
        current.update(metadata)
        current.update(status='failed', error=str(error), duration_seconds=time.monotonic() - started)
        write(current)
        raise
