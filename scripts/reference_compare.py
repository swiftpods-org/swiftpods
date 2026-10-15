#!/usr/bin/env python3
"""Compare independent native/reference installs using an explicitly isolated test gem home."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from bootstrap import ROOT, environment
from native_integration import project
from reporting import execute


def reference_environment(gem_home, parent):
    selected = environment()
    reference_env = {key: value for key, value in selected.items() if not key.startswith(('SWIFTPODS_', 'BUNDLE_', 'GEM_'))}
    reference_env.update(GEM_HOME=str(gem_home.resolve()), GEM_PATH=str(gem_home.resolve()), BUNDLE_GEMFILE=str(ROOT / 'Tests/Reference/Gemfile'), BUNDLE_FROZEN='true', BUNDLE_IGNORE_CONFIG='true', BUNDLE_WITHOUT='test', BUNDLER_VERSION='2.6.9', CP_HOME_DIR=str(parent / 'reference-home'), CP_CACHE_DIR=str(parent / 'reference-cache'), COCOAPODS_DISABLE_STATS='true', COCOAPODS_SKIP_UPDATE_MESSAGE='true')
    return selected['SWIFTPODS_RUBY'], reference_env


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--gem-home', type=Path, required=True, help='Separately prepared reference-only gems; never used by production')
    args = parser.parse_args()
    parent = Path(tempfile.mkdtemp(prefix='reference-compare-', dir=ROOT / '.build'))
    reference = parent / 'reference'; native = parent / 'native'
    for directory in (reference, native):
        shutil.copytree(ROOT / 'Tests/Fixtures/MixedLanguages', directory)
        project(directory / 'Demo.xcodeproj')
    native_env = environment()
    native_env['SWIFTPODS_CACHE_ROOT'] = str(parent / 'native-cache')
    native_log = parent / 'native.log'
    with native_log.open('wb') as log:
        result = subprocess.run([str(ROOT / '.build/debug/swiftpods'), 'install', '--json'], cwd=native, env=native_env, stdout=log, stderr=subprocess.PIPE)
    if result.returncode: raise RuntimeError(result.stderr.decode())
    ruby, reference_env = reference_environment(args.gem_home, parent)
    code = "require 'bundler/setup'; require 'cocoapods'; abort('Unexpected reference version') unless Pod::VERSION == '1.17.0'; Pod::Command.run(ARGV)"
    reference_log = parent / 'reference.log'
    with reference_log.open('wb') as log:
        result = subprocess.run([ruby, '-e', code, '--', 'install', '--no-ansi'], cwd=reference, env=reference_env, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode: raise RuntimeError('Reference execution failed: ' + str(reference_log))
    assert (native / 'hook-trace.txt').read_text() == (reference / 'hook-trace.txt').read_text()
    native_report = json.loads((native / '.swiftpods/installation.json').read_text())
    pins = {spec['name']: spec['version'] for spec in native_report['specs']}
    assert pins == {'GameCore': '1.2.3.4'}
    assert 'GameCore (1.2.3.4)' in (reference / 'Podfile.lock').read_text()
    for directory in (reference, native):
        text = (directory / 'Pods/Pods.xcodeproj/project.pbxproj').read_text()
        assert 'SWIFTPODS_HOOK_MARKER' in text and 'preserved' in text
        assert 'GameCoreResources' in text and 'GameCore.framework' in text
    report = {'status': 'passed', 'engine': 'swift', 'reference': '1.17.0', 'fixture': str(parent), 'verified': ['independently executed engines', 'matching pod version', 'matching prepare/hook order', 'matching hook build settings', 'framework and resource-bundle generation'], 'unverified': ['byte-for-byte project/lock equivalence', 'complete DSL/API compatibility', 'reference matrix beyond this fixture']}
    (ROOT / 'test-results/native-reference.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    execute(main, 'native-reference.json')
