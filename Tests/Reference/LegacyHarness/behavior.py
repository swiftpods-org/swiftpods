#!/usr/bin/env python3
"""Exercise process boundaries, cancellation and recovery against real Ruby."""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
from integration import ROOT, CLI, BUNDLE, RUBY, environment, run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', type=Path, default=CLI)
    parser.add_argument('--bundle', type=Path, default=BUNDLE)
    args = parser.parse_args()
    cli, bundle = args.cli.resolve(), args.bundle.resolve()
    directory = Path(tempfile.mkdtemp(prefix='behavior-', dir=ROOT / '.build'))
    home = directory / 'home'
    home.mkdir()
    env = environment(home, bundle)
    template = directory / 'template'
    shutil.copytree(ROOT / 'Tests/Fixtures/MixedLanguages', template)
    run([RUBY, '-rbundler/setup', ROOT / 'Tests/Fixtures/create_project.rb'],
        template, env, directory / 'create.log')
    # Deliberately hostile inherited Ruby settings must be replaced by the
    # launcher, while ordinary application ENV remains visible to hooks.
    env.update(RUBYOPT='-r/swiftpods-test-does-not-exist', RUBYLIB='/swiftpods-invalid',
               GEM_HOME='/swiftpods-invalid', GEM_PATH='/swiftpods-invalid',
               BUNDLE_GEMFILE='/swiftpods-invalid/Gemfile', SDK_TOKEN='fixture-secret-8492')
    verified = []

    def invoke(project, arguments, status=0, name='command'):
        result = subprocess.run([str(cli), *arguments, '--json'], cwd=project, env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        (directory / (name + '.stdout')).write_bytes(result.stdout)
        (directory / (name + '.stderr')).write_bytes(result.stderr)
        assert result.returncode == status, (name, result.returncode, result.stderr.decode(errors='replace'))
        report = json.loads(result.stdout)
        assert b'fixture-secret-8492' not in result.stdout + result.stderr, 'Secret leaked: ' + name
        return report, result

    failed = directory / 'failed'
    shutil.copytree(template, failed)
    original_project = (failed / 'Demo.xcodeproj/project.pbxproj').read_bytes()
    with (failed / 'Podfile').open('a') as podfile:
        podfile.write('''
pre_install do |_installer|
  puts '{"protocol_version":1,"kind":"fake_stdout_event"}'
  warn ENV.fetch('SDK_TOKEN')
  File.write('hook-side-effect', 'preserve')
  File.write('Podfile.lock', 'partial lock')
  raise "intentional failure #{ENV.fetch('SDK_TOKEN')}"
end
''')
    report, output = invoke(failed, ['install', '--no-ansi'], status=1, name='failed-hook')
    assert report['project_state'] == 'recovery_required'
    assert report['events'][-1]['kind'] == 'completed'
    assert not any(event['kind'] == 'fake_stdout_event' for event in report['events'])
    assert b'fake_stdout_event' in output.stderr
    assert any(event['kind'] == 'diagnostic' and '[REDACTED]' in event['message'] for event in report['events'])
    assert any(event['kind'] == 'diagnostic' and event.get('file', '').endswith('/Podfile')
               and isinstance(event.get('line'), int) for event in report['events'])
    verified += ['json_stdout_isolation', 'redacted_hook_errors', 'external_ruby_isolated_gems_environment', 'failed_hook_state']
    blocked, _ = invoke(failed, ['install'], status=1, name='blocked-install')
    assert blocked['diagnostic']['code'] == 'SP-STATE-RECOVERY'
    recovered, _ = invoke(failed, ['recover'], name='recover')
    assert recovered['status'] == 'recovered'
    assert not (failed / 'Podfile.lock').exists() and not (failed / 'Pods').exists()
    assert (failed / 'Demo.xcodeproj/project.pbxproj').read_bytes() == original_project
    assert (failed / 'hook-side-effect').read_text() == 'preserve'
    assert (failed / 'Modules/GameCore/prepare-ran').exists()
    verified += ['recovery_restores_managed_files', 'recovery_preserves_local_prepare_and_hook_effects']

    waiting = directory / 'waiting'
    shutil.copytree(template, waiting)
    with (waiting / 'Podfile').open('a') as podfile:
        podfile.write('''
pre_install do |_installer|
  trap('INT') {}
  code = "trap('INT') {}; trap('TERM') {}; File.write('child-ready', Process.pid.to_s); sleep 60"
  spawn(RbConfig.ruby, '-e', code)
  sleep 60
end
''')
    process = subprocess.Popen([str(cli), 'install', '--no-ansi', '--json'], cwd=waiting, env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    child = None
    try:
        deadline = time.monotonic() + 20
        while not (waiting / 'child-ready').exists():
            assert process.poll() is None, 'Command exited before cancellation probe'
            assert time.monotonic() < deadline, 'Cancellation fixture did not start'
            time.sleep(0.05)
        child = int((waiting / 'child-ready').read_text())
        busy, _ = invoke(waiting, ['install'], status=1, name='concurrent-install')
        assert busy['diagnostic']['code'] == 'SP-STATE-BUSY'
        process.send_signal(signal.SIGINT)
        stdout, stderr = process.communicate(timeout=10)
        (directory / 'cancel.stdout').write_bytes(stdout)
        (directory / 'cancel.stderr').write_bytes(stderr)
        assert process.returncode == 130, process.returncode
        assert json.loads(stdout)['project_state'] == 'recovery_required'
        state = subprocess.run(['/bin/ps', '-o', 'stat=', '-p', str(child)], capture_output=True, text=True).stdout.strip()
        assert not state or state.startswith('Z'), 'Child survived cancellation: ' + state
        invoke(waiting, ['recover'], name='cancel-recover')
        verified += ['concurrent_process_lock', 'sigint_exit_status', 'cancelled_child_cleanup', 'cancellation_recovery']
    finally:
        if child:
            try:
                os.kill(child, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if process.poll() is None:
            process.kill()
            process.communicate(timeout=5)

    report = {'schema_version': 1, 'status': 'passed', 'fixture': str(directory), 'verified': verified}
    (ROOT / 'test-results/behavior.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    from reporting import execute
    execute(main, 'behavior.json')
