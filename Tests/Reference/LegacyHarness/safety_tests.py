#!/usr/bin/env python3
"""Real installations: external writes, offline/cache, archives and hardened input."""
import hashlib
import http.server
import io
import json
from pathlib import Path
import shutil
import stat
import subprocess
import tarfile
import tempfile
import threading
import zipfile
from integration import ROOT, CLI, RUBY, environment, run


def main():
    directory = Path(tempfile.mkdtemp(prefix='safety-', dir=ROOT / '.build'))
    env = environment(directory / 'home')
    Path(env['HOME']).mkdir()
    template = directory / 'template'
    shutil.copytree(ROOT / 'Tests/Fixtures/MixedLanguages', template)
    run([RUBY, '-rbundler/setup', ROOT / 'Tests/Fixtures/create_project.rb'], template, env, directory / 'create.log')
    checks = []

    def invoke(project, arguments, status=0, name='command'):
        result = subprocess.run([str(CLI), *arguments, '--json'], cwd=project, env=env, capture_output=True, timeout=45)
        (directory / (name + '.stdout')).write_bytes(result.stdout)
        (directory / (name + '.stderr')).write_bytes(result.stderr)
        assert result.returncode == status, (name, result.returncode, result.stderr.decode(errors='replace')[-4000:])
        return json.loads(result.stdout)

    def code(report):
        return report.get('diagnostic', {}).get('code') or next(event['code'] for event in report['events'] if event['kind'] == 'diagnostic')

    # A separate process edits the project after CocoaPods has read its model.
    project = directory / 'external-edit'
    shutil.copytree(template, project)
    with (project / 'Podfile').open('a') as file:
        file.write('''
pre_install do |_|
  system(RbConfig.ruby, '-e', "File.open('Demo.xcodeproj/project.pbxproj', 'a') { |f| f.puts '// external-generator-edit' }")
end
''')
    report = invoke(project, ['install', '--no-ansi'], 1, 'external-edit')
    assert code(report) == 'SP-PROJECT-CONFLICT', code(report)
    changed = (project / 'Demo.xcodeproj/project.pbxproj').read_bytes()
    assert b'external-generator-edit' in changed
    recovered = invoke(project, ['recover'], name='external-recover')
    assert 'Demo.xcodeproj/project.pbxproj' in recovered['preserved_external_paths']
    assert (project / 'Demo.xcodeproj/project.pbxproj').read_bytes() == changed
    checks += ['external_project_edit_blocked', 'recovery_preserves_external_edit']

    # Archive contents are inspected with libarchive, including link targets.
    for name, entry_name, link, entry_type, expected in [
        ('regular', 'nested/file', None, tarfile.REGTYPE, 0),
        ('parent', '../outside', None, tarfile.REGTYPE, 1),
        ('absolute', '/outside', None, tarfile.REGTYPE, 1),
        ('symlink', 'nested/link', '../../outside', tarfile.SYMTYPE, 1),
        ('normalized-link', 'a/../link', '../outside', tarfile.SYMTYPE, 1),
        ('hardlink', 'link', '../outside', tarfile.LNKTYPE, 1),
        ('fifo', 'pipe', None, tarfile.FIFOTYPE, 1),
        ('safe-link', 'nested/link', '../file', tarfile.SYMTYPE, 0),
    ]:
        archive = directory / (name + '.tar.gz')
        with tarfile.open(archive, 'w:gz') as tar:
            entry = tarfile.TarInfo(entry_name)
            entry.type, entry.size = entry_type, 0
            if link:
                entry.linkname = link
            tar.addfile(entry, io.BytesIO())
        result = invoke(directory, ['__archivecheck', str(archive)], expected, 'archive-' + name)
        if expected:
            assert result['diagnostic']['code'] == 'SP-ARCHIVE-UNSAFE'
    archive = directory / 'symlink.zip'
    with zipfile.ZipFile(archive, 'w') as zip:
        entry = zipfile.ZipInfo('link')
        entry.create_system = 3
        entry.external_attr = (stat.S_IFLNK | 0o777) << 16
        zip.writestr(entry, '../outside')
    assert code(invoke(directory, ['__archivecheck', str(archive)], 1, 'archive-zip-link')) == 'SP-ARCHIVE-UNSAFE'
    for name, members in [('link-alias-parent', [('alias', '.', tarfile.SYMTYPE), ('alias/../outside', None, tarfile.REGTYPE)]),
                          ('composed-link-escape', [('alias', '.', tarfile.SYMTYPE), ('escape', 'alias/..', tarfile.SYMTYPE)]),
                          ('link-descendant', [('alias', 'safe', tarfile.SYMTYPE), ('alias/file', None, tarfile.REGTYPE)])]:
        archive = directory / (name + '.tar.gz')
        with tarfile.open(archive, 'w:gz') as tar:
            for member, target, kind in members:
                entry = tarfile.TarInfo(member)
                entry.type, entry.size = kind, 0
                if target:
                    entry.linkname = target
                tar.addfile(entry, io.BytesIO())
        assert code(invoke(directory, ['__archivecheck', str(archive)], 1, name)) == 'SP-ARCHIVE-UNSAFE'
    checks += ['tar_paths_links_special_files_rejected', 'zip_symlink_rejected', 'safe_archive_accepted']

    # Validate mounted disk images before the downloader copies any contents.
    dmg_source = directory / 'dmg-source'
    dmg_source.mkdir()
    (dmg_source / 'unsafe').symlink_to('/tmp/swiftpods-outside')
    image = directory / 'unsafe.dmg'
    run(['/usr/bin/hdiutil', 'create', '-srcfolder', dmg_source, '-volname', 'SwiftPodsUnsafe', '-format', 'UDZO', image], directory, env, directory / 'dmg-create.log')

    web = directory / 'web'
    web.mkdir()
    archive = web / 'cachekit.zip'
    with zipfile.ZipFile(archive, 'w') as zip:
        zip.writestr('CacheKit.h', 'int cache_value(void);\n')
        zip.writestr('CacheKit.c', 'int cache_value(void) { return 42; }\n')
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
    try:
        project = directory / 'cache'
        shutil.copytree(template, project)
        spec = {'name': 'CacheKit', 'version': '1.0.0', 'summary': 'Cache integration fixture',
                'homepage': 'https://example.invalid', 'license': 'MIT', 'authors': {'Tests': 'tests@example.invalid'},
                'platforms': {'osx': '13.0'}, 'source_files': '*.{h,c}',
                'source': {'http': f'http://127.0.0.1:{server.server_port}/cachekit.zip',
                           'sha256': hashlib.sha256(archive.read_bytes()).hexdigest()}}
        (project / 'CacheKit.podspec.json').write_text(json.dumps(spec))
        (project / 'Podfile').write_text("platform :osx, '13.0'\nproject 'Demo.xcodeproj'\ntarget('Demo') { pod 'CacheKit', :podspec => 'CacheKit.podspec.json' }\n")
        invoke(project, ['install', '--integrity', '--no-ansi'], name='cache-online')
        assert requests == ['/cachekit.zip'], requests
        invoke(project, ['integrity', 'verify'], name='integrity-verify')
        installed_source = project / 'Pods/CacheKit/CacheKit.c'
        original_source = installed_source.read_bytes()
        original_mode = installed_source.stat().st_mode
        installed_source.chmod(original_mode | stat.S_IWUSR)
        installed_source.write_text('tampered installed artifact\n')
        failure = invoke(project, ['install', '--integrity'], 1, 'integrity-tampered')
        assert code(failure) == 'SP-INTEGRITY-CONTENT'
        installed_source.write_bytes(original_source)
        installed_source.chmod(original_mode)
        lock = (project / 'Podfile.lock').read_bytes()
        shutil.rmtree(project / 'Pods')
        invoke(project, ['install', '--offline', '--integrity', '--no-ansi'], name='cache-offline')
        assert (project / 'Podfile.lock').read_bytes() == lock
        assert requests == ['/cachekit.zip'], 'Offline mode used the managed HTTP downloader'
        cache = Path(env['HOME']) / 'Library/Caches/SwiftPods'
        source = next(cache.glob('*/Pods/External/CacheKit/*/CacheKit.c'))
        source.write_text('corrupted cache\n')
        shutil.rmtree(project / 'Pods')
        report = invoke(project, ['install', '--offline', '--no-ansi'], 1, 'cache-corrupt')
        assert code(report) == 'SP-CACHE-INTEGRITY', code(report)
        invoke(project, ['recover'], name='cache-recover')
        invoke(project, ['cache', 'clean', 'CacheKit', '--all'], name='cache-clean')
        invoke(project, ['install', '--offline', '--no-ansi'], name='raw-archive-restore')
        assert requests == ['/cachekit.zip']
        invoke(project, ['cache', 'verify'], name='content-cache-verify')
        blob = next(cache.glob('*/content/objects/*'))
        original_blob = blob.read_bytes()
        blob.chmod(0o600)
        blob.write_bytes(b'corrupt raw bytes')
        report = invoke(project, ['cache', 'verify'], 1, 'raw-corrupt')
        assert code(report) == 'SP-CACHE-INTEGRITY'
        blob.write_bytes(original_blob)
        blob.chmod(0o444)
        shutil.rmtree(project / 'Pods')
        invoke(project, ['cache', 'clean', 'CacheKit', '--all'], name='cache-clean-again')
        for object in cache.glob('*/content/objects/*'):
            object.unlink()
        report = invoke(project, ['install', '--offline', '--no-ansi'], 1, 'cache-missing')
        assert code(report) == 'SP-OFFLINE-MISSING', code(report)
        assert requests == ['/cachekit.zip']
        checks += ['complete_cache_install_offline', 'offline_preserves_lock', 'corrupt_cache_rejected', 'missing_cache_reported_without_network',
                   'artifact_integrity_recorded', 'installed_artifact_tamper_rejected_before_ruby', 'integrity_verified_after_cache_restore']
        checks += ['content_addressed_raw_archive_cache', 'offline_restore_after_prepared_cache_clean']

        # URL podspecs have their own origin-bound immutable cache. Force a
        # refetch by removing the sandbox, then prove offline needs no HTTP.
        (web / 'CacheKit.podspec.json').write_text(json.dumps(spec))
        spec_url = f'http://127.0.0.1:{server.server_port}/CacheKit.podspec.json'
        remote = directory / 'remote-spec'
        shutil.copytree(template, remote)
        (remote / 'Podfile').write_text("platform :osx, '13.0'\nproject 'Demo.xcodeproj'\ntarget('Demo') { pod 'CacheKit', :podspec => " + json.dumps(spec_url) + " }\n")
        invoke(remote, ['install', '--no-ansi'], name='remote-spec-online')
        before_requests = len(requests)
        shutil.rmtree(remote / 'Pods')
        invoke(remote, ['install', '--offline', '--no-ansi'], name='remote-spec-offline')
        assert len(requests) == before_requests
        checks += ['url_podspec_offline_cache', 'raw_cache_corruption_rejected']

        unsafe = directory / 'dmg'
        shutil.copytree(template, unsafe)
        shutil.copy2(image, web / image.name)
        dmg_spec = dict(spec)
        dmg_spec['source'] = {'http': f'http://127.0.0.1:{server.server_port}/{image.name}', 'sha256': hashlib.sha256(image.read_bytes()).hexdigest()}
        (unsafe / 'CacheKit.podspec.json').write_text(json.dumps(dmg_spec))
        (unsafe / 'Podfile').write_text("platform :osx, '13.0'\nproject 'Demo.xcodeproj'\ntarget('Demo') { pod 'CacheKit', :podspec => 'CacheKit.podspec.json' }\n")
        failure = invoke(unsafe, ['install', '--no-ansi'], 1, 'unsafe-dmg')
        assert code(failure) == 'SP-ARCHIVE-UNSAFE', code(failure)
        checks += ['mounted_dmg_symlink_rejected_before_copy']
    finally:
        server.shutdown()
        server.server_close()

    project = directory / 'hardened'
    shutil.copytree(template, project)
    (project / 'Podfile').write_text("File.write('ruby-executed', 'bad')\nraise 'must not execute'\n")
    pod = project / 'JsonKit'
    pod.mkdir()
    (pod / 'JsonKit.h').write_text('int json_value(void);\n')
    (pod / 'JsonKit.c').write_text('int json_value(void) { return 1; }\n')
    spec = {'name': 'JsonKit', 'version': '1.0.0', 'summary': 'Hardened fixture', 'homepage': 'https://example.invalid',
            'authors': {'Tests': 'tests@example.invalid'}, 'license': 'MIT', 'source': {'git': 'https://example.invalid/json.git'},
            'platforms': {'osx': '13.0'}, 'source_files': '*.{c,h}', 'prepare_command': 'touch script-executed'}
    (pod / 'JsonKit.podspec.json').write_text(json.dumps(spec))
    manifest = {'schema_version': 1, 'platform': {'name': 'osx', 'deployment_target': '13.0'},
                'project': 'Demo.xcodeproj', 'targets': [{'name': 'Demo', 'pods': [{'name': 'JsonKit', 'path': 'JsonKit'}]}]}
    (project / 'Podfile.json').write_text(json.dumps(manifest))
    report = invoke(project, ['install', '--hardened', '--no-ansi'], 1, 'hardened-script')
    assert code(report) == 'SP-HARDENED-SCRIPT', code(report)
    assert not (pod / 'script-executed').exists() and not (project / 'ruby-executed').exists()
    invoke(project, ['recover'], name='hardened-recover')
    del spec['prepare_command']
    (pod / 'JsonKit.podspec.json').write_text(json.dumps(spec))
    invoke(project, ['install', '--hardened', '--no-ansi'], name='hardened-install')
    assert not (project / 'ruby-executed').exists()
    checks += ['hardened_rejects_required_scripts_before_execution', 'hardened_json_install_without_ruby_podfile']
    failing = directory / 'failed-prepare'
    shutil.copytree(template, failing)
    spec_path = failing / 'Modules/GameCore/GameCore.podspec'
    text = spec_path.read_text()
    text = text.replace("spec.prepare_command =", "spec.prepare_command = 'exit 17' #")
    assert "exit 17" in text
    spec_path.write_text(text)
    report = invoke(failing, ['install', '--no-ansi'], 1, 'process-exit')
    assert any(event.get('code') == 'SP-PROCESS-EXIT' and event.get('exit_status') == 17 and event.get('stage') == 'prepare'
               for event in report['events']), report
    checks += ['prepare_external_exit_status_and_stage_recorded']
    report = {'schema_version': 1, 'status': 'passed', 'fixture': str(directory), 'verified': checks}
    (ROOT / 'test-results/safety.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    from reporting import execute
    execute(main, 'safety.json')
