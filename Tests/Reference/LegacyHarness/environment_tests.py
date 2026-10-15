#!/usr/bin/env python3
"""Import a real local plugin, run live hooks and reject conflicting pins."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
from integration import ROOT, CLI, RUBY, environment, run


def main():
    directory = Path(tempfile.mkdtemp(prefix='environments-', dir=ROOT / '.build'))
    env = environment(directory / 'home')
    Path(env['HOME']).mkdir()
    project = directory / 'project'
    shutil.copytree(ROOT / 'Tests/Fixtures/MixedLanguages', project)
    run([RUBY, '-rbundler/setup', ROOT / 'Tests/Fixtures/create_project.rb'], project, env, directory / 'create.log')
    plugin = project / 'plugin'
    (plugin / 'lib').mkdir(parents=True)
    (plugin / 'cocoapods-swiftpods-fixture.gemspec').write_text('''
Gem::Specification.new do |s|
  s.name = 'cocoapods-swiftpods-fixture'
  s.version = '0.0.1'
  s.summary = 'A real SwiftPods test plugin'
  s.authors = ['SwiftPods tests']
  s.files = ['lib/cocoapods_plugin.rb']
  s.require_paths = ['lib']
  s.add_runtime_dependency 'cocoapods', '= 1.17.0'
end
''')
    (plugin / 'lib/cocoapods_plugin.rb').write_text('''
require 'cocoapods'
Pod::HooksManager.register('cocoapods-swiftpods-fixture', :pre_install) do |context|
  raise 'not a live sandbox' unless context.sandbox.is_a?(Pod::Sandbox)
  File.write(context.sandbox.root.parent + 'plugin-phase', 'pre_install')
end
Pod::HooksManager.register('cocoapods-swiftpods-fixture', :post_install) do |context|
  File.open(context.sandbox.root.parent + 'plugin-phase', 'a') { |file| file.write(',post_install') }
end
''')
    gemfile = project / 'Gemfile'
    gemfile.write_text("source 'https://rubygems.org'\ngem 'cocoapods', '= 1.17.0'\ngem 'cocoapods-swiftpods-fixture', '= 0.0.1', :path => './plugin'\n")
    original = gemfile.read_bytes()
    with (project / 'Podfile').open('a') as file:
        file.write("\nplugin 'cocoapods-swiftpods-fixture'\nensure_bundler! '= 2.6.9'\n")

    def invoke(arguments, status=0, name='command'):
        result = subprocess.run([str(CLI), *arguments, '--json'], cwd=project, env=env, capture_output=True, timeout=120)
        (directory / (name + '.stdout')).write_bytes(result.stdout)
        (directory / (name + '.stderr')).write_bytes(result.stderr)
        assert result.returncode == status, (name, result.stderr.decode(errors='replace')[-6000:])
        return json.loads(result.stdout)

    report = invoke(['env', 'import', '--gemfile', 'Gemfile', '--name', 'fixture', '--local'], name='import')
    assert report['status'] == 'imported'
    assert gemfile.read_bytes() == original and not (project / 'Gemfile.lock').exists()
    assert any(gem['name'] == 'cocoapods-swiftpods-fixture' and gem['version'] == '0.0.1' for gem in report['gems'])
    invoke(['install', '--environment', 'fixture', '--no-ansi'], name='plugin-install')
    assert (project / 'plugin-phase').read_text() == 'pre_install,post_install'
    pinned_lock = (project / '.swiftpods/environments/fixture/Gemfile.lock').read_bytes()
    (project / 'Gemfile.lock').write_bytes(pinned_lock)
    invoke(['env', 'import', '--gemfile', 'Gemfile', '--name', 'locked', '--local'], name='locked-import')
    assert (project / 'Gemfile.lock').read_bytes() == pinned_lock
    invoke(['install', '--environment=locked', '--no-ansi'], name='locked-plugin-install')
    profiles = invoke(['env', 'list'], name='list')
    assert [profile['name'] for profile in profiles['profiles']] == ['fixture', 'locked']
    shim = directory / 'bin'
    invoke(['env', 'shim', '--directory', str(shim)], name='shim')
    assert (shim / 'pod').is_symlink()
    result = subprocess.run([str(shim / 'pod'), '--version'], cwd=project, env=env, capture_output=True, timeout=20)
    assert result.returncode == 0 and b'SwiftPods' in result.stdout
    original_shim = (shim / 'pod').readlink()
    invoke(['env', 'shim', '--directory', str(shim)], 1, 'shim-exists')
    assert (shim / 'pod').readlink() == original_shim
    gemfile.write_text("source 'https://rubygems.org'\ngem 'cocoapods', '= 1.16.2'\n")
    conflict = invoke(['env', 'import', '--gemfile', 'Gemfile', '--name', 'conflict', '--local'], 1, 'conflict')
    assert conflict['diagnostic']['code'] == 'SP-ENV-IMPORT'
    assert not (project / '.swiftpods/environments/conflict').exists()
    stale = invoke(['install', '--environment=fixture'], 1, 'stale')
    assert stale['diagnostic']['code'] == 'SP-ENV-STALE'
    assert (project / 'Gemfile.lock').read_bytes() == pinned_lock
    report = {'schema_version': 1, 'status': 'passed', 'fixture': str(directory),
              'verified': ['isolated_import', 'project_gemfile_unchanged', 'locked_versions_and_lockfile_preserved', 'real_plugin_live_hooks', 'ensure_bundler_check',
                           'explicit_environment_selection', 'opt_in_pod_shim', 'shim_does_not_overwrite',
                           'conflicting_core_rejected', 'failed_import_unpublished', 'stale_environment_rejected']}
    (ROOT / 'test-results/environments.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    from reporting import execute
    execute(main, 'environments.json')
