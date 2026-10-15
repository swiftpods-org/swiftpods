#!/usr/bin/env python3
"""Run pinned upstream Core specs and CocoaPods unit/functional suites.

Results are evidence for this runtime/dependency profile, not the full release
acceptance matrix. Each suite has an isolated HOME and a captured log.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from integration import environment, RUBY
from bootstrap import PROFILE

ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / 'test-results'


def pinned_checkout(name):
    checkout = ROOT / '.build/upstream' / name
    config = PROFILE['upstream'][name]
    if not (checkout / '.git').exists():
        if checkout.exists() and any(checkout.iterdir()):
            raise RuntimeError('Refusing to replace an existing non-Git directory: ' + str(checkout))
        checkout.mkdir(parents=True, exist_ok=True)
        subprocess.run(['git', 'init'], cwd=checkout, check=True)
        subprocess.run(['git', 'remote', 'add', 'origin', config['repository']], cwd=checkout, check=True)
        subprocess.run(['git', 'fetch', '--depth', '1', 'origin', config['commit']], cwd=checkout, check=True)
        subprocess.run(['git', 'checkout', '--detach', config['commit']], cwd=checkout, check=True)
    actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=checkout, text=True).strip()
    assert actual == config['commit'], 'Upstream checkout is not pinned: ' + name
    return checkout


def main():
    RESULTS.mkdir(exist_ok=True)
    ruby = RUBY
    home = Path(tempfile.mkdtemp(prefix='upstream-home-', dir=ROOT / '.build'))
    env = environment(home)
    env.pop('BUNDLE_WITHOUT', None)
    env.pop('COCOAPODS_SKIP_UPDATE_MESSAGE', None)
    env['COCOA_PODS_ENV'] = 'development'
    env.update(GIT_AUTHOR_NAME='SwiftPods Tests', GIT_AUTHOR_EMAIL='tests@example.invalid',
               GIT_COMMITTER_NAME='SwiftPods Tests', GIT_COMMITTER_EMAIL='tests@example.invalid',
               TOOLCHAINS='com.apple.dt.toolchain.XcodeDefault')
    report = {'schema_version': 1, 'suites': []}
    for name, patterns in [('cocoapods-core', ['spec/**/*_spec.rb']),
                           ('cocoapods', ['spec/unit/**/*_spec.rb', 'spec/functional/**/*_spec.rb'])]:
        checkout = pinned_checkout(name)
        expected = PROFILE['upstream'][name]['commit']
        subprocess.run(['git', 'submodule', 'update', '--init', '--recursive', '--depth', '1'], cwd=checkout, check=True)
        if name == 'cocoapods':
            # Validator fixtures clone historical tags (not only the gitlink
            # tip); a depth-one submodule omits e.g. JSONKit's v1.4 tag.
            for fixture in ['JSONKit', 'Reachability']:
                repository = checkout / 'spec/fixtures/integration' / fixture
                shallow = subprocess.check_output(['git', 'rev-parse', '--is-shallow-repository'], cwd=repository, text=True).strip()
                if shallow == 'true':
                    subprocess.run(['git', 'fetch', '--unshallow', '--tags'], cwd=repository, check=True)
        files = sorted(set(path for pattern in patterns for path in checkout.glob(pattern)))
        entry = {'name': name, 'commit': expected, 'spec_files': len(files), 'log': name + '-specs.log'}
        assert files, 'Missing pinned upstream checkout: ' + name
        # Bundler selects pinned gems; upstream test helpers put their own lib
        # and spec directories before the vendored runtime source paths.
        code = "require 'bundler/setup'; $LOAD_PATH.unshift(File.join(Dir.pwd, 'spec')); ARGV.each { |path| require File.expand_path(path) }"
        start = time.monotonic()
        with (RESULTS / entry['log']).open('wb') as log:
            process = subprocess.run([str(ruby), '-e', code, *map(str, files)], cwd=checkout, env=env,
                                     stdout=log, stderr=subprocess.STDOUT, timeout=900)
        entry.update(exit_status=process.returncode, seconds=time.monotonic() - start)
        report['suites'].append(entry)
        (RESULTS / 'upstream-tests.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(entry), flush=True)
    if not all(s['exit_status'] == 0 for s in report['suites']):
        raise RuntimeError('Pinned upstream specifications failed; inspect suite logs')
    report['status'] = 'passed'
    (RESULTS / 'upstream-tests.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    from reporting import execute
    execute(main, 'upstream-tests.json')
