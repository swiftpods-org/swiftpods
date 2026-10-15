#!/usr/bin/env python3
"""Relocate a distribution and use explicitly selected external Ruby."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from integration import ROOT, environment, RUBY, _RUBY_METADATA


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    args = parser.parse_args()
    source = args.bundle.resolve()
    directory = Path(tempfile.mkdtemp(prefix='swiftpods-portability-'))
    bundle = directory / 'relocated SwiftPods'
    shutil.copytree(source, bundle, symlinks=True)
    home = directory / 'home'
    home.mkdir()
    project = directory / 'fixture'
    shutil.copytree(ROOT / 'Tests/Fixtures/MixedLanguages', project)
    build_env = environment(home, bundle)
    subprocess.run([str(RUBY), '-rbundler/setup', str(ROOT / 'Tests/Fixtures/create_project.rb')],
                   cwd=project, env=build_env, check=True)
    with (project / 'Podfile').open('a') as podfile:
        podfile.write("\npre_install { |_| File.write('runtime-location', RbConfig.ruby) }\n")
    env = {'HOME': str(home), 'PATH': str(bundle / 'bin') + ':/usr/bin:/bin:/usr/sbin:/sbin',
           'SWIFTPODS_RUBY': str(RUBY), 'LANG': 'en_US.UTF-8', 'RUBYOPT': '-r/swiftpods-invalid', 'GEM_HOME': '/swiftpods-invalid',
           'GEM_PATH': '/swiftpods-invalid', 'BUNDLE_GEMFILE': '/swiftpods-invalid/Gemfile',
           'COCOAPODS_SKIP_UPDATE_MESSAGE': 'true'}

    def invoke(arguments, status=0):
        result = subprocess.run(['swiftpods', *arguments, '--json'], cwd=project, env=env,
                                capture_output=True, timeout=30)
        assert result.returncode == status, result.stderr.decode(errors='replace')
        return json.loads(result.stdout)

    report = invoke(['install', '--no-ansi'])
    assert report['exit_status'] == 0
    started = next(event for event in report['events'] if event['kind'] == 'started')
    assert started['cocoapods'] == '1.17.0' and started['ruby'] == _RUBY_METADATA['version']
    assert Path((project / 'runtime-location').read_text()).resolve() == RUBY.resolve()
    assert not (bundle / 'runtime').exists()
    assert (project / 'Podfile.lock').read_bytes() == (project / 'Pods/Manifest.lock').read_bytes()
    assert (project / 'Modules/GameCore/prepare-ran').exists()
    # Listed-file corruption must fail before executing Ruby or starting a
    # journal, including when the working directory is outside the checkout.
    host = bundle / 'host/host.rb'
    original = host.read_bytes()
    state = (project / '.swiftpods/state.json').read_bytes()
    try:
        host.write_bytes(original + b'\n# tampered\n')
        failure = invoke(['install'], status=1)
        assert failure['diagnostic']['code'] == 'SP-RUNTIME-INTEGRITY'
        assert (project / '.swiftpods/state.json').read_bytes() == state
    finally:
        host.write_bytes(original)
    shadow = bundle / 'host/unlisted.rb'
    try:
        shadow.write_text("raise 'unlisted Ruby must never load'\n")
        failure = invoke(['runtime', 'verify'], status=1)
        assert failure['diagnostic']['code'] == 'SP-RUNTIME-INTEGRITY'
    finally:
        shadow.unlink()
    manifest = bundle / 'compatibility.json'
    original_manifest = manifest.read_bytes()
    signature = bundle / 'compatibility.cms'
    # A forged release flag and invalid CMS must never fall back to unsigned
    # development verification or execute managed Ruby.
    try:
        metadata = json.loads(original_manifest)
        metadata['status'] = 'release'
        manifest.write_text(json.dumps(metadata))
        signature.write_bytes(b'invalid-cms')
        failure = invoke(['runtime', 'verify'], status=1)
        assert failure['diagnostic']['code'] == 'SP-RUNTIME-SIGNATURE'
    finally:
        manifest.write_bytes(original_manifest)
        signature.unlink()

    # Audit every Mach-O file, including native gem extensions, rather than
    # only the Swift executable. Native gems may load the declared external
    # Ruby formula; unrelated absolute build dependencies remain rejected.
    magics = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe',
              b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}
    dependencies = {}
    for path in sorted(bundle.rglob('*')):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as stream:
            magic = stream.read(4)
        if magic not in magics:
            continue
        output = subprocess.check_output(['/usr/bin/otool', '-L', str(path)], text=True)
        libraries = [line.strip().split(' (compatibility version')[0] for line in output.splitlines() if line.startswith('\t')]
        for library in libraries:
            assert library.startswith(('/usr/lib/', '/System/Library/', '@rpath/', '@loader_path/', '@executable_path/', '/opt/homebrew/opt/ruby@3.4/', '/usr/local/opt/ruby@3.4/')), (path, library)
        dependencies[path.relative_to(bundle).as_posix()] = libraries
    assert dependencies, 'No native binaries were audited'
    result = {'schema_version': 1, 'status': 'passed', 'bundle': str(source), 'relocated_bundle': str(bundle),
              'verified': ['path_invocation_outside_checkout', 'path_with_spaces', 'clean_path_without_system_ruby',
                           'external_runtime_used', 'no_embedded_ruby', 'relocated_install', 'tampered_file_rejected_before_ruby',
                           'unlisted_file_rejected', 'release_requires_trusted_manifest_signature',
                           'native_dependencies_are_system_relative_or_declared_ruby'],
              'native_dependencies': dependencies}
    (ROOT / 'test-results/portability.json').write_text(json.dumps(result, indent=2) + '\n')
    print('Passed portability checks; audited', len(dependencies), 'Mach-O files')


if __name__ == '__main__':
    from reporting import execute
    execute(main, 'portability.json')
