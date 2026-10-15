#!/usr/bin/env python3
"""Offline-fixture differential installation and real macOS build/run checks."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / '.runtime'
from bootstrap import PROFILE
from ruby_runtime import select_ruby
RUBY, _RUBY_METADATA = select_ruby(PROFILE)
CLI = ROOT / '.build/debug/swiftpods'


def environment(home, bundle=BUNDLE):
    env = {k: v for k, v in os.environ.items() if not k.startswith(('BUNDLE_', 'GEM_')) and k not in ('RUBYOPT', 'RUBYLIB')}
    env.update(HOME=str(home), GEM_HOME=str(bundle / 'gems'), GEM_PATH=str(bundle / 'gems'),
               BUNDLE_GEMFILE=str(bundle / 'Gemfile'), BUNDLE_FROZEN='true',
               PATH=str(RUBY.parent) + ':' + str(bundle / 'gems/bin') + ':/usr/bin:/bin:/usr/sbin:/sbin',
               SWIFTPODS_RUBY=str(RUBY), BUNDLER_VERSION=PROFILE['runtime']['bundler'],
               COCOAPODS_DISABLE_STATS='true', COCOAPODS_SKIP_UPDATE_MESSAGE='true',
               SWIFTPODS_BUNDLE=str(bundle), LANG='en_US.UTF-8')
    return env


def run(args, cwd, env, log, expected=0, reject_warnings=False):
    started = time.monotonic()
    result = subprocess.run(list(map(str, args)), cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=600)
    log.write_bytes(result.stdout)
    if result.returncode != expected:
        raise AssertionError(f'{args}: expected {expected}, got {result.returncode}; see {log}\n' + result.stdout.decode(errors='replace')[-5000:])
    if reject_warnings and re.search(rb'\bwarning:', result.stdout, re.IGNORECASE):
        raise AssertionError('Build emitted warnings; see ' + str(log))
    return time.monotonic() - started, result.stdout.decode(errors='replace')


def canonical_project(path):
    """Alpha-rename object IDs, retaining all fields, references and array order.

    CocoaPods generates random IDs for newly integrated user-project objects.
    Parsing with plutil keeps unknown fields rather than a typed model dropping
    them. Every object must be reachable; this comparator refuses otherwise.
    """
    document = json.loads(subprocess.check_output(['/usr/bin/plutil', '-convert', 'json', '-o', '-', str(path)]))
    objects = document['objects']
    identities = {document['rootObject']: 'OBJECT_000000'}
    pending = [document['rootObject']]

    def identity(value):
        if value not in identities:
            identities[value] = f'OBJECT_{len(identities):06}'
            pending.append(value)
        return identities[value]

    def visit(value):
        if isinstance(value, str) and value in objects:
            return identity(value)
        if isinstance(value, list):
            return [visit(item) for item in value]
        if isinstance(value, dict):
            # Reference-keyed dictionaries (e.g. TargetAttributes) use IDs
            # already reached through the ordered target list. Refuse to pick
            # a traversal order from random identifiers.
            for key in value:
                if key in objects and key not in identities:
                    raise AssertionError('Unresolved UUID dictionary key: ' + key)
            return {(identities[key] if key in objects else key): visit(value[key])
                    for key in sorted(value, key=lambda key: identities.get(key, key))}
        return value

    normalized = {}
    cursor = 0
    while cursor < len(pending):
        key = pending[cursor]
        cursor += 1
        # Resolve ordered targets before nested TargetAttributes, independent
        # of serialization key order.
        if objects[key].get('isa') == 'PBXProject':
            for target in objects[key].get('targets', []):
                identity(target)
        normalized[identities[key]] = visit(objects[key])
    assert set(identities) == set(objects), 'Comparator refuses unreachable project objects'
    return json.dumps({key: normalized if key == 'objects' else visit(value)
                       for key, value in document.items()}, sort_keys=True).encode()


def snapshot(directory, normalize_uuids=False):
    result = {}
    for path in sorted(directory.rglob('*')):
        relative = path.relative_to(directory).as_posix()
        if relative.startswith('.swiftpods/') or '/.git/' in relative:
            continue
        if path.is_symlink():
            result[relative] = 'link:' + os.readlink(path).replace(str(directory), '<FIXTURE_ROOT>')
        elif path.is_file():
            data = canonical_project(path) if normalize_uuids and path.name == 'project.pbxproj' else path.read_bytes()
            data = data.replace(str(directory).encode(), b'<FIXTURE_ROOT>')
            result[relative] = hashlib.sha256(data).hexdigest()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skip-build', action='store_true')
    args = parser.parse_args()
    results = ROOT / 'test-results'
    results.mkdir(exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix='integration-', dir=ROOT / '.build'))
    template = directory / 'template'
    shutil.copytree(ROOT / 'Tests/Fixtures/MixedLanguages', template)
    env = environment(directory / 'home')
    Path(env['HOME']).mkdir()
    run([RUBY, '-rbundler/setup', ROOT / 'Tests/Fixtures/create_project.rb'], template, env, results / 'create-project.log')
    upstream, candidate = directory / 'upstream', directory / 'swiftpods'
    shutil.copytree(template, upstream)
    shutil.copytree(template, candidate)
    # Independently load pinned original sources, never Runtime/host.rb or its
    # integration modules. Both sides share the fixed runtime/dependency set.
    reference = directory / 'reference.rb'
    reference.write_text("require 'bundler/setup'\n" +
                         f"$LOAD_PATH.unshift({json.dumps(str(ROOT / '.build/upstream/cocoapods-core/lib'))})\n" +
                         f"$LOAD_PATH.unshift({json.dumps(str(ROOT / '.build/upstream/cocoapods/lib'))})\n" +
                         "require 'cocoapods'\nPod::Command.run(ARGV)\n")
    timings = {}
    timings['reference_install'], _ = run([RUBY, reference, 'install', '--no-ansi'], upstream, env, results / 'reference-install.log')
    timings['swiftpods_install'], _ = run([CLI, 'install', '--no-ansi', '--json'], candidate, env, results / 'swiftpods-install.log')
    original, actual = snapshot(upstream, normalize_uuids=True), snapshot(candidate, normalize_uuids=True)
    differences = sorted(key for key in original.keys() | actual.keys() if original.get(key) != actual.get(key))
    assert not differences, f'Differential output differs: {differences}'
    expected_hooks = 'pre_install\npre_integrate\npost_install\npost_integrate\n'
    assert (candidate / 'hook-trace.txt').read_text() == expected_hooks
    assert (candidate / 'Modules/GameCore/prepare-ran').exists()
    assert b'SWIFTPODS_HOOK_MARKER = preserved' in (candidate / 'Pods/Pods.xcodeproj/project.pbxproj').read_bytes()
    assert (candidate / 'Podfile.lock').read_bytes() == (candidate / 'Pods/Manifest.lock').read_bytes()
    before = snapshot(candidate)
    timings['noop_install'], _ = run([CLI, 'install', '--no-ansi'], candidate, env, results / 'noop-install.log')
    assert snapshot(candidate) == before, 'No-op install changed fixture output'
    timings['deployment_install'], _ = run([CLI, 'install', '--deployment', '--no-ansi'], candidate, env, results / 'deployment-install.log')
    assert snapshot(candidate) == before, 'Deployment install changed fixture output'
    run([CLI, 'graph', '--json'], candidate, env, results / 'graph.json')
    graph = json.loads((results / 'graph.json').read_text())
    assert graph['specs'][0]['version'] == '1.2.3.4'
    run([CLI, 'why', 'GameCore', '--json'], candidate, env, results / 'why.json')
    run([RUBY, reference, 'install', '--deployment', '--no-ansi'], candidate, env, results / 'return-to-upstream.log')
    assert snapshot(candidate) == before, 'Return to upstream changed generated output'
    if not args.skip_build:
        for configuration in ['Debug', 'Release']:
            derived = directory / ('derived-' + configuration)
            run(['xcodebuild', '-workspace', 'Demo.xcworkspace', '-scheme', 'Demo', '-configuration', configuration,
                 '-toolchain', 'com.apple.dt.toolchain.XcodeDefault',
                 '-destination', 'platform=macOS,arch=' + platform.machine(), '-derivedDataPath', derived, 'build'],
                candidate, env, results / (configuration.lower() + '-build.log'), reject_warnings=True)
            application = derived / 'Build/Products' / configuration / 'Demo.app'
            _, output = run([application / 'Contents/MacOS/Demo'], candidate, env, results / (configuration.lower() + '-run.log'))
            assert output == 'mixed=15 resources=ok privacy=ok\n'
    report = {'schema_version': 1, 'status': 'passed', 'fixture': str(directory),
              'verified': ['independent_upstream_diff', 'ruby_helpers_and_env', 'four_live_hooks', 'four_component_version',
                           'local_prepare_semantics', 'lock_consistency', 'noop_install', 'deployment_install',
                           'graph_and_why', 'return_to_upstream'] + ([] if args.skip_build else ['macos_debug_build_run', 'macos_release_build_run', 'five_languages', 'localized_resources', 'privacy_manifest']),
              'normalizations': ['fixture root path', 'project UUID alpha-renaming; all fields/references and array order retained',
                                 'SwiftPods own .swiftpods metadata excluded; no-op installs compared byte-for-byte'],
              'timings_seconds': timings}
    (results / ('integration-fast.json' if args.skip_build else 'integration.json')).write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    from reporting import execute
    execute(main, 'integration-fast.json' if '--skip-build' in __import__('sys').argv else 'integration.json')
