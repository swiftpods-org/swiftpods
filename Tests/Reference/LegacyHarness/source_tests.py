#!/usr/bin/env python3
"""Independent differential CDN/Git/multiple-source and nested-target fixture."""
import hashlib
import http.server
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import zipfile
from integration import ROOT, CLI, RUBY, environment, run, snapshot


def main():
    directory = Path(tempfile.mkdtemp(prefix='sources-', dir=ROOT / '.build'))
    web = directory / 'web'
    web.mkdir()
    (web / 'CocoaPods-version.yml').write_text('min: 1.0.0\nlast: 1.17.0\nprefix_lengths: [1, 1, 1]\n')
    (web / 'all_pods.txt').write_text('RegistryKit\n')
    (web / 'deprecated_podspecs.txt').write_text('')
    requests = []
    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=str(web), **kwargs)
        def do_GET(self):
            requests.append(self.path)
            super().do_GET()
        def log_message(self, *args):
            pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f'http://127.0.0.1:{server.server_port}/'
    env = environment(directory / 'home')
    Path(env['HOME']).mkdir()
    env.update(GIT_AUTHOR_NAME='Tests', GIT_AUTHOR_EMAIL='tests@example.invalid', GIT_COMMITTER_NAME='Tests', GIT_COMMITTER_EMAIL='tests@example.invalid')
    archive = web / 'sdk.zip'
    with zipfile.ZipFile(archive, 'w') as zip:
        for name in ['RegistryKit', 'RepoKit']:
            zip.writestr(name + '.h', f'int {name.lower()}_value(void);\n')
            zip.writestr(name + '.c', f'int {name.lower()}_value(void) {{ return 42; }}\n')
    def specification(name, version):
        return {'name': name, 'version': version, 'summary': 'Source selection fixture', 'homepage': 'https://example.invalid',
                'authors': {'Tests': 'tests@example.invalid'}, 'license': 'MIT', 'platforms': {'osx': '13.0'},
                'source': {'http': url + 'sdk.zip', 'sha256': hashlib.sha256(archive.read_bytes()).hexdigest()},
                'source_files': name + '.{c,h}'}
    shard = list(hashlib.md5(b'RegistryKit').hexdigest()[:3])
    (web / ('all_pods_versions_' + '_'.join(shard) + '.txt')).write_text('RegistryKit/1.0.0/1.1.0\n')
    for version in ['1.0.0', '1.1.0']:
        path = web.joinpath('Specs', *shard, 'RegistryKit', version)
        path.mkdir(parents=True)
        (path / 'RegistryKit.podspec.json').write_text(json.dumps(specification('RegistryKit', version)))
    specs = directory / 'Specs'
    for name in ['RegistryKit', 'RepoKit']:
        path = specs / name / '1.0.0'
        path.mkdir(parents=True)
        (path / (name + '.podspec.json')).write_text(json.dumps(specification(name, '1.0.0')))
    for index, command in enumerate([['init', '-b', 'main'], ['add', '.'], ['commit', '-m', 'Pinned private specs']]):
        run(['git', *command], specs, env, directory / ('git-' + str(index) + '.log'))
    reference = directory / 'reference.rb'
    reference.write_text("require 'bundler/setup'\n" + ''.join(
        f'$LOAD_PATH.unshift({json.dumps(str(ROOT / ".build/upstream" / name / "lib"))})\n' for name in ['cocoapods-core', 'cocoapods']) + "require 'cocoapods'\nPod::Command.run(ARGV)\n")
    template = directory / 'template'
    shutil.copytree(ROOT / 'Tests/Fixtures/MixedLanguages', template)
    run([RUBY, '-rbundler/setup', ROOT / 'Tests/Fixtures/create_project.rb'], template, env, directory / 'create.log')
    nested = template / 'nested.rb'
    nested.write_text("require 'xcodeproj'\np = Xcodeproj::Project.open('Demo.xcodeproj')\n%w[SearchTests NoneTests].each { |name| p.new_target(:unit_test_bundle, name, :osx, '13.0') }\np.save\n")
    run([RUBY, '-rbundler/setup', nested], template, env, directory / 'targets.log')
    try:
        for name, executable in [('upstream', [RUBY, reference]), ('candidate', [CLI])]:
            env = environment(directory / (name + '-home'))
            Path(env['HOME']).mkdir()
            project = directory / name
            shutil.copytree(template, project)
            (project / 'Podfile').write_text(f'''source {json.dumps(url)}
source {json.dumps(specs.as_uri())}
platform :osx, '13.0'
project 'Demo.xcodeproj', 'Debug' => :debug, 'Release' => :release
workspace 'Demo'
use_frameworks! :linkage => :static
abstract_target 'Shared' do
  pod 'RegistryKit', '= 1.0.0', :source => {json.dumps(url)}
  target 'Demo' do
    pod 'RepoKit', :source => {json.dumps(specs.as_uri())}
    target 'SearchTests' do
      inherit! :search_paths
    end
    target 'NoneTests' do
      inherit! :none
    end
  end
end
''')
            run([*executable, 'repo', 'add-cdn', 'FixtureCDN', url], project, env, directory / (name + '-cdn.log'))
            run([*executable, 'repo', 'add', 'FixtureGit', specs.as_uri()], project, env, directory / (name + '-repo.log'))
            run([*executable, 'install', '--no-ansi'], project, env, directory / (name + '-install.log'))
        expected, actual = [snapshot(directory / name, normalize_uuids=True) for name in ['upstream', 'candidate']]
        differences = sorted(key for key in expected.keys() | actual.keys() if expected.get(key) != actual.get(key))
        assert not differences, differences
        candidate = directory / 'candidate'
        lock = (candidate / 'Podfile.lock').read_bytes()
        assert b'RegistryKit (1.0.0)' in lock and url.encode() in lock and specs.as_uri().encode() in lock
        before = len(requests)
        shutil.rmtree(candidate / 'Pods')
        run([CLI, 'install', '--offline', '--deployment', '--no-ansi'], candidate, env, directory / 'offline.log')
        assert len(requests) == before, requests[before:]
        assert (candidate / 'Podfile.lock').read_bytes() == lock
        def refresh(arguments, filename):
            result = subprocess.run([str(CLI), *arguments, '--refresh', '--json'], cwd=candidate, env=env, capture_output=True, timeout=120)
            (directory / filename).write_bytes(result.stdout)
            (directory / (filename + '.stderr')).write_bytes(result.stderr)
            assert result.returncode == 0, result.stderr.decode(errors='replace')
            return json.loads(result.stdout)
        report = refresh(['graph'], 'refresh.json')
        assert report['refresh']['executed_project_code'] is True
        why = refresh(['why', 'RepoKit'], 'why-refresh.json')
        assert why['dependency_chains'] and why['refresh']['operation'] == 'install'
    finally:
        server.shutdown()
        server.server_close()
    report = {'schema_version': 1, 'status': 'passed', 'fixture': str(directory),
              'verified': ['independent_cdn_git_source_diff', 'multiple_explicit_sources', 'same_name_source_identity',
                           'abstract_nested_search_paths_none_targets', 'custom_configuration_mapping', 'offline_cdn_zero_requests',
                           'graph_refresh_runs_install', 'why_refresh_emits_one_json']}
    (ROOT / 'test-results/sources.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    from reporting import execute
    execute(main, 'sources.json')
