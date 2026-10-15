#!/usr/bin/env python3
"""Pinned private Git specs, targeted updates, external Git locks and CLI flows."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import platform
from integration import ROOT, CLI, RUBY, environment, run


def main():
    directory = Path(tempfile.mkdtemp(prefix='workflows-', dir=ROOT / '.build'))
    env = environment(directory / 'home')
    Path(env['HOME']).mkdir()
    env.update(GIT_AUTHOR_NAME='Tests', GIT_AUTHOR_EMAIL='tests@example.invalid', GIT_COMMITTER_NAME='Tests', GIT_COMMITTER_EMAIL='tests@example.invalid')
    sdk = directory / 'SDK'
    sdk.mkdir()
    (sdk / 'LICENSE').write_text('MIT fixture license\n')
    for name in ['Adapter', 'Stable', 'SharedCore']:
        (sdk / (name + '.h')).write_text(f'int {name.lower()}_value(void);\n')
        (sdk / (name + '.c')).write_text(f'int {name.lower()}_value(void) {{ return 1; }}\n')
    def git(path, arguments, name):
        run(['git', *arguments], path, env, directory / (name + '.log'))
    git(sdk, ['init', '-b', 'main'], 'sdk-init')
    git(sdk, ['add', '.'], 'sdk-add')
    git(sdk, ['commit', '-m', 'Initial SDK'], 'sdk-commit')
    git(sdk, ['tag', 'v1.0'], 'sdk-tag')
    specs = directory / 'Specs'
    specs.mkdir()
    git(specs, ['init', '-b', 'main'], 'spec-init')
    def spec(name, version, dependencies=None, tag='v1.0'):
        value = {'name': name, 'version': version, 'summary': 'SwiftPods dependency resolution fixture',
                 'homepage': 'https://example.invalid', 'license': {'type': 'MIT', 'file': 'LICENSE'},
                 'authors': {'Tests': 'tests@example.invalid'}, 'platforms': {'osx': '13.0'},
                 'source': {'git': sdk.as_uri(), 'tag': tag}, 'source_files': name + '.{c,h}'}
        if dependencies:
            value['dependencies'] = dependencies
        path = specs / name / version
        path.mkdir(parents=True)
        (path / (name + '.podspec.json')).write_text(json.dumps(value))
        return value
    spec('Adapter', '1.0.0', {'SharedCore': ['~> 1.0']})
    spec('Stable', '1.0.0', {'SharedCore': ['~> 1.0']})
    spec('SharedCore', '1.0.0')
    git(specs, ['add', '.'], 'spec-add')
    git(specs, ['commit', '-m', 'Initial specs'], 'spec-commit')
    project = directory / 'project'
    shutil.copytree(ROOT / 'Tests/Fixtures/MixedLanguages', project)
    run([RUBY, '-rbundler/setup', ROOT / 'Tests/Fixtures/create_project.rb'], project, env, directory / 'create.log')
    (project / 'Podfile').write_text(f"source {json.dumps(specs.as_uri())}\nplatform :osx, '13.0'\nproject 'Demo.xcodeproj'\ntarget 'Demo' do\n  pod 'Adapter', '~> 1.0'\n  pod 'Stable', '~> 1.0'\nend\n")
    def invoke(arguments, status=0, name='command', cwd=project):
        started = time.monotonic()
        result = subprocess.run([str(CLI), *arguments, '--json'], cwd=cwd, env=env, capture_output=True, timeout=120)
        timings[name] = time.monotonic() - started
        (directory / (name + '.stdout')).write_bytes(result.stdout)
        (directory / (name + '.stderr')).write_bytes(result.stderr)
        assert result.returncode == status, (name, result.stderr.decode(errors='replace')[-6000:])
        return json.loads(result.stdout)
    timings = {}
    invoke(['repo', 'add', 'FixtureSpecs', specs.as_uri()], name='repo-add')
    invoke(['repo', 'list'], name='repo-list')
    invoke(['install', '--no-ansi'], name='install')
    before = (project / 'Podfile.lock').read_bytes()
    invoke(['install', '--no-ansi'], name='noop-install')
    assert (project / 'Podfile.lock').read_bytes() == before
    shutil.rmtree(project / 'Pods')
    invoke(['install', '--no-ansi'], name='warm-install')
    assert (project / 'Podfile.lock').read_bytes() == before
    report = invoke(['why', 'SharedCore'], name='why')
    chains = [[node['name'] for node in chain['nodes']] for chain in report['dependency_chains']]
    assert ['Adapter', 'SharedCore'] in chains and ['Stable', 'SharedCore'] in chains, chains
    spec('Adapter', '1.1.0', {'SharedCore': ['>= 1.1.0', '< 2.0']})
    spec('Stable', '1.1.0', {'SharedCore': ['~> 1.0']})
    spec('SharedCore', '1.1.0')
    git(specs, ['add', '.'], 'spec-update-add')
    git(specs, ['commit', '-m', 'New compatible releases'], 'spec-update-commit')
    invoke(['repo', 'update', 'FixtureSpecs'], name='repo-update')
    invoke(['install', '--deployment', '--no-ansi'], name='locked-install')
    assert (project / 'Podfile.lock').read_bytes() == before
    invoke(['outdated', '--no-ansi'], name='outdated')
    invoke(['update', 'Adapter', '--no-ansi'], name='targeted-update')
    graph = invoke(['graph'], name='graph')
    versions = {entry['name']: entry['version'] for entry in graph['specs']}
    assert versions == {'Adapter': '1.1.0', 'SharedCore': '1.1.0', 'Stable': '1.0.0'}, versions
    assert all(entry['spec_repository'].rstrip('/') == specs.as_uri() for entry in graph['specs'])
    # Root discovery must journal the same project CocoaPods discovers.
    child = project / 'subdirectory'
    child.mkdir()
    invoke(['install', '--deployment', '--no-ansi'], name='subdirectory-install', cwd=child)
    assert not (child / '.swiftpods').exists()
    invoke(['install', '--not-a-real-option'], 1, 'invalid-option')
    # A parse failure made no managed changes and does not poison retry.
    assert json.loads((project / '.swiftpods/state.json').read_text())['status'] == 'failed_no_managed_changes'
    invoke(['install', '--deployment', '--no-ansi'], name='retry-after-invalid')
    lint = project / 'SharedCore.podspec.json'
    git(sdk, ['tag', 'v2.0.0'], 'lint-tag')
    lint.write_text(json.dumps(spec('SharedCore', '2.0.0', tag='v2.0.0')))
    invoke(['spec', 'lint', str(lint), '--quick', '--no-ansi'], name='spec-lint-quick')
    # An external Git branch is pinned by the generated lock, even after HEAD advances.
    external = directory / 'external'
    shutil.copytree(ROOT / 'Tests/Fixtures/MixedLanguages', external)
    run([RUBY, '-rbundler/setup', ROOT / 'Tests/Fixtures/create_project.rb'], external, env, directory / 'external-create.log')
    ext_spec = {'name': 'GitKit', 'version': '1.0.0', 'summary': 'Git checkout fixture', 'homepage': 'https://example.invalid',
                'license': {'type': 'MIT', 'file': 'LICENSE'}, 'authors': {'Tests': 'tests@example.invalid'}, 'platforms': {'osx': '13.0'},
                'source': {'git': sdk.as_uri(), 'branch': 'main'}, 'source_files': 'SharedCore.{c,h}'}
    (sdk / 'GitKit.podspec.json').write_text(json.dumps(ext_spec))
    git(sdk, ['add', '.'], 'gitkit-add')
    git(sdk, ['commit', '-m', 'GitKit'], 'gitkit-commit')
    (external / 'Podfile').write_text(f"platform :osx, '13.0'\nproject 'Demo.xcodeproj'\ntarget('Demo') {{ pod 'GitKit', :git => {json.dumps(sdk.as_uri())}, :branch => 'main' }}\n")
    invoke(['install', '--no-ansi'], name='git-install', cwd=external)
    original_lock = (external / 'Podfile.lock').read_bytes()
    original_source = (external / 'Pods/GitKit/SharedCore.c').read_bytes()
    (sdk / 'SharedCore.c').write_text('int sharedcore_value(void) { return 99; }\n')
    git(sdk, ['add', '.'], 'git-advance-add')
    git(sdk, ['commit', '-m', 'Advance branch'], 'git-advance-commit')
    invoke(['install', '--no-ansi'], name='git-locked-install', cwd=external)
    assert (external / 'Podfile.lock').read_bytes() == original_lock
    assert (external / 'Pods/GitKit/SharedCore.c').read_bytes() == original_source
    invoke(['update', 'GitKit', '--no-ansi'], name='git-update', cwd=external)
    assert (external / 'Podfile.lock').read_bytes() != original_lock
    assert b'99' in (external / 'Pods/GitKit/SharedCore.c').read_bytes()
    # Init refuses to overwrite an existing Podfile.
    original_podfile = (project / 'Podfile').read_bytes()
    invoke(['init'], 1, 'init-existing')
    assert (project / 'Podfile').read_bytes() == original_podfile
    result = {'schema_version': 1, 'status': 'passed', 'fixture': str(directory),
              'timings_seconds': {key: timings[key] for key in ['install', 'warm-install', 'noop-install', 'targeted-update']},
              'measurement_environment': {'os': platform.mac_ver()[0], 'architecture': platform.machine(), 'network': 'local file Git origins; no internet SDK download',
                                          'cache': 'isolated HOME, empty for initial install; restored Pods for warm install', 'fixtures': 'three C source pods with transitive constraints'},
              'verified': ['private_git_specs', 'repo_add_list_update', 'install_preserves_locked_versions', 'outdated',
                           'targeted_update_preserves_unrelated_pod', 'provenance_preserved', 'complete_why_chains',
                           'subdirectory_project_discovery', 'invalid_options_do_not_poison_retry', 'spec_lint_metadata',
                           'external_git_branch_locked_to_commit', 'explicit_git_update', 'init_does_not_overwrite']}
    (ROOT / 'test-results/workflows.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    from reporting import execute
    execute(main, 'workflows.json')
