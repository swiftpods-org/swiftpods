#!/usr/bin/env python3
"""Publish reproducible local Git install measurements without a speed claim."""
import json
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile
import time
from bootstrap import ROOT, environment
from reporting import execute


def main():
    parent = Path(tempfile.mkdtemp(prefix='native-benchmark-', dir=ROOT / '.build'))
    repo, catalog = parent / 'source', parent / 'catalog'; repo.mkdir(); catalog.mkdir()
    for name in ['Kit', 'Unrelated']: (repo / (name + '.c')).write_text('int ' + name.lower() + '(void) { return 1; }\n')
    for args in [('init',), ('add', '.'), ('-c', 'user.name=SwiftPods Tests', '-c', 'user.email=tests@example.invalid', 'commit', '-m', 'fixture')]:
        subprocess.run(['git', '-C', str(repo), *args], check=True, capture_output=True)
    revision = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
    def spec(name, version):
        path = catalog / name / version / (name + '.podspec.json'); path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({'name': name, 'version': version, 'source': {'git': str(repo), 'commit': revision}, 'source_files': name + '.c'}))
    spec('Kit', '1.0'); spec('Unrelated', '1.0')
    env = environment()
    def project(name):
        path = parent / name; path.mkdir()
        (path / 'Podfile').write_text("platform :osx, '13.0'\nsource " + repr(str(catalog)) + "\ntarget 'App' do\n pod 'Kit'\n pod 'Unrelated'\nend\n")
        return path
    def run(path, cache, *args):
        selected = dict(env, SWIFTPODS_CACHE_ROOT=str(cache))
        started = time.monotonic()
        result = subprocess.run([str(ROOT / '.build/debug/swiftpods'), *args, '--no-integrate', '--json'], cwd=path, env=selected, capture_output=True, text=True, timeout=90)
        elapsed = time.monotonic() - started
        assert result.returncode == 0, (args, result.stdout[-1500:], result.stderr[-1500:])
        return elapsed
    samples = {'cold_install': [], 'warm_install': [], 'noop_install': [], 'targeted_update': []}
    suffixes = {'.c', '.m', '.mm', '.swift', '.h', '.hpp', '.modulemap', '.pbxproj', '.xcconfig', '.plist', '.lock', '.sh', '.xcfilelist'}
    def inputs(path):
        return {str(file.relative_to(path)): (file.stat().st_mtime_ns, file.read_bytes()) for file in path.rglob('*') if file.is_file() and file.suffix in suffixes and '.swiftpods' not in file.parts}
    changed = []
    for index in range(3):
        cold = project('cold-' + str(index)); cache = parent / ('cache-' + str(index))
        samples['cold_install'].append(run(cold, cache, 'install'))
        warm = project('warm-' + str(index))
        samples['warm_install'].append(run(warm, cache, 'install'))
        before = inputs(warm)
        samples['noop_install'].append(run(warm, cache, 'install'))
        after = inputs(warm)
        changes = sorted(name for name in set(before).union(after) if before.get(name) != after.get(name))
        changed.append(changes)
        spec('Kit', '1.1')
        samples['targeted_update'].append(run(warm, cache, 'update', 'Kit'))
        lock = (warm / 'Podfile.lock').read_text()
        assert 'Kit (1.1)' in lock and 'Unrelated (1.0)' in lock
        shutil.rmtree(catalog / 'Kit/1.1')
    report = {'status': 'passed', 'engine': 'swift', 'fixture': str(parent), 'samples_seconds': samples, 'median_seconds': {name: statistics.median(values) for name, values in samples.items()}, 'noop_changed_build_inputs': changed, 'conditions': {'samples': 3, 'network': 'none; local pinned Git repository', 'cold': 'fresh project and cache', 'warm': 'fresh project with a populated cache', 'noop': 'same installed project and unchanged declarations', 'update': 'new Kit version with Unrelated kept locked'}, 'verified': ['cold/warm/no-op/targeted-update timings on a fixed local fixture', 'targeted update preserves unrelated lock', 'build input bytes and modification times are measured'], 'unverified': ['public network performance', 'real application install performance', 'comparison with another manager']}
    if any(changed): raise RuntimeError('No-op install rewrote build inputs: ' + str(changed))
    report['verified'].append('no-op preserves all measured build input bytes and timestamps')
    (ROOT / 'test-results/native-benchmarks.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__': execute(main, 'native-benchmarks.json')
