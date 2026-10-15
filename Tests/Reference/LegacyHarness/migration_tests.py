#!/usr/bin/env python3
"""Generate a real 1.16.2 lock, then compare migration to independent 1.17.0."""
import io
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
from integration import ROOT, CLI, RUBY, environment, run, snapshot

OLD = {'cocoapods': '861039444193ac218160ae5486a12016ac9f485d',
       'cocoapods-core': '38015718a35eb25d4877bc992fcbb9d0681078d5'}


def main():
    directory = Path(tempfile.mkdtemp(prefix='migration-', dir=ROOT / '.build'))
    env = environment(directory / 'home')
    Path(env['HOME']).mkdir()
    old = directory / 'old'
    for name, commit in OLD.items():
        checkout = ROOT / '.build/upstream' / name
        if subprocess.run(['git', '-C', str(checkout), 'cat-file', '-e', commit], capture_output=True).returncode:
            run(['git', '-C', checkout, 'fetch', '--no-recurse-submodules', 'origin', commit], ROOT, env, directory / (name + '-fetch.log'))
        data = subprocess.check_output(['git', '-C', str(checkout), 'archive', commit, 'lib', name + '.gemspec'])
        with tarfile.open(fileobj=io.BytesIO(data)) as archive:
            archive.extractall(old / name, filter='data')
    def reference(name, sources):
        path = directory / (name + '.rb')
        path.write_text("require 'bundler/setup'\n" + ''.join(
            f'$LOAD_PATH.unshift({json.dumps(str(sources / component / "lib"))})\n'
            for component in ['cocoapods-core', 'cocoapods']) + "require 'cocoapods'\nPod::Command.run(ARGV)\n")
        return path
    old_gemfile = old / 'Gemfile'
    old_gemfile.write_text((ROOT / 'Gemfile').read_text().replace('vendor/cocoapods', 'cocoapods'))
    old_lock = (ROOT / 'Gemfile.lock').read_text().replace('vendor/cocoapods', 'cocoapods').replace('1.17.0', '1.16.2')
    old_gemfile.with_suffix('.lock').write_text(old_lock)
    old_gems = old / 'gems'
    old_env = {**env, 'GEM_HOME': str(old_gems), 'GEM_PATH': str(old_gems) + ':' + env['GEM_PATH'],
               'BUNDLE_GEMFILE': str(old_gemfile), 'BUNDLE_FROZEN': 'false'}
    # Two dependencies changed between the historical and baseline cores.
    # Install their pinned archives in the fixture only; managed gems stay frozen.
    for name, version, checksum in [('escape', '0.0.4', 'e49f44ae2b4f47c6a3abd544ae77fe4157802794e32f19b8e773cbc4dcec4169'),
                                    ('ruby-macho', '2.5.1', '9075e52e0f9270b552a90b24fcc6219ad149b0d15eae1bc364ecd0ac8984f5c9')]:
        archive = old / (name + '-' + version + '.gem')
        with urllib.request.urlopen('https://rubygems.org/gems/' + archive.name, timeout=60) as response:
            archive.write_bytes(response.read())
        assert hashlib.sha256(archive.read_bytes()).hexdigest() == checksum
        run([RUBY, '-S', 'gem', 'install', archive, '--local', '--no-document'], old, old_env, directory / (name + '-install.log'))
    # Reconcile historical gemspec dependency constraints using installed exact
    # versions only. This touches this fixture's lock, never the managed profile.
    run([RUBY, '-S', 'bundle', 'lock', '--local'], old,
        old_env, directory / 'old-gem-lock.log')
    previous = reference('old', old)
    baseline = reference('baseline', ROOT / '.build/upstream')
    template = directory / 'template'
    shutil.copytree(ROOT / 'Tests/Fixtures/MixedLanguages', template)
    run([RUBY, '-rbundler/setup', ROOT / 'Tests/Fixtures/create_project.rb'], template, env, directory / 'create.log')
    run([RUBY, previous, 'install', '--no-ansi'], template, {**old_env, 'BUNDLE_FROZEN': 'true'}, directory / 'old-install.log')
    original_lock = (template / 'Podfile.lock').read_bytes()
    assert b'COCOAPODS: 1.16.2' in original_lock, original_lock
    # Hooks are intentionally idempotent and shared by all versions.
    for deployment in [False, True]:
        upstream, candidate = [directory / (name + ('-deployment' if deployment else '')) for name in ['reference', 'candidate']]
        for project in [upstream, candidate]:
            shutil.copytree(template, project)
        options = ['install', '--no-ansi'] + (['--deployment'] if deployment else [])
        expected_status = 1 if deployment else 0
        run([RUBY, baseline, *options], upstream, env, directory / ('reference-' + str(deployment) + '.log'), expected=expected_status)
        run([CLI, *options], candidate, env, directory / ('candidate-' + str(deployment) + '.log'), expected=expected_status)
        expected, actual = snapshot(upstream, normalize_uuids=True), snapshot(candidate, normalize_uuids=True)
        differences = sorted(key for key in expected.keys() | actual.keys() if expected.get(key) != actual.get(key))
        assert not differences, differences
        lock = (candidate / 'Podfile.lock').read_bytes()
        assert b'GameCore (1.2.3.4)' in lock
        if deployment:
            assert lock == original_lock, 'Deployment changed the original 1.16.2 lock'
        else:
            assert lock == original_lock.replace(b'COCOAPODS: 1.16.2', b'COCOAPODS: 1.17.0'), 'Unexpected migration dependency changes'
    report = {'schema_version': 1, 'status': 'passed', 'fixture': str(directory), 'old_commits': OLD,
              'verified': ['authentic_1_16_2_lock', 'independent_migration_diff', 'dependency_versions_preserved',
                           'only_core_metadata_changes', 'deployment_rejects_core_metadata_change_without_rewriting_lock', 'existing_pods_preserved']}
    (ROOT / 'test-results/migration.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    from reporting import execute
    execute(main, 'migration.json')
