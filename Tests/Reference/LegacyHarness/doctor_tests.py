#!/usr/bin/env python3
"""Use real arm64 device/simulator objects to verify static binary diagnostics."""
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
from integration import ROOT, CLI, environment, run


def main():
    directory = Path(tempfile.mkdtemp(prefix='doctor-', dir=ROOT / '.build'))
    env = environment(directory / 'home')
    Path(env['HOME']).mkdir()
    project = directory / 'project'
    project.mkdir()
    (project / 'Podfile').write_text("File.write('ruby-executed', 'bad')\nraise 'never evaluate this'\n")
    source = directory / 'value.c'
    source.write_text('int fixture_binary(void) { return 7; }\n')
    xcframework = project / 'Fixture.xcframework'
    libraries = []
    for name, triple, sdk, variant in [('ios-arm64', 'arm64-apple-ios15.0', 'iphoneos', None),
                                      ('ios-arm64-simulator', 'arm64-apple-ios15.0-simulator', 'iphonesimulator', 'simulator')]:
        path = xcframework / name
        path.mkdir(parents=True)
        sysroot = subprocess.check_output(['/usr/bin/xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip()
        run(['/usr/bin/xcrun', 'clang', '-target', triple, '-isysroot', sysroot, '-Werror', '-Wall', '-Wextra', '-c', source, '-o', path / 'value.o'],
            directory, env, directory / (name + '-compile.log'), reject_warnings=True)
        run(['/usr/bin/ar', 'rcs', path / 'libFixture.a', path / 'value.o'], directory, env, directory / (name + '-archive.log'), reject_warnings=True)
        (path / 'value.o').unlink()
        entry = {'LibraryIdentifier': name, 'LibraryPath': 'libFixture.a', 'SupportedArchitectures': ['arm64'], 'SupportedPlatform': 'ios'}
        if variant:
            entry['SupportedPlatformVariant'] = variant
        libraries.append(entry)
    info = {'AvailableLibraries': libraries, 'XCFrameworkFormatVersion': '1.0'}
    (xcframework / 'Info.plist').write_bytes(plistlib.dumps(info))

    def invoke(arguments, status=0, name='command'):
        result = subprocess.run([str(CLI), 'doctor', '--static', *arguments, '--json'], cwd=project, env=env, capture_output=True, timeout=30)
        (directory / (name + '.json')).write_bytes(result.stdout)
        assert result.returncode == status, (name, result.stderr.decode(errors='replace'), result.stdout.decode(errors='replace')[-3000:])
        assert not (project / 'ruby-executed').exists()
        return json.loads(result.stdout)

    report = invoke(['--platform=ios', '--variant=simulator', '--arch=arm64', '--deployment-target=15.0'], name='valid')
    variants = {slice['variant'] for binary in report['binaries'] for slice in binary['slices']}
    assert variants == {'device', 'simulator'}, variants
    assert sum(check['name'] == 'xcframework_metadata' and check['status'] == 'passed' for check in report['checks']) == 2
    invoke(['--platform=ios', '--variant=simulator', '--arch=x86_64'], 1, 'missing-arch')
    report = invoke(['--platform=ios', '--variant=simulator', '--arch=arm64', '--deployment-target=14.0'], 1, 'minimum-os')
    assert any(check['name'] == 'deployment_target' and check['status'] == 'failed' for check in report['checks'])
    info['AvailableLibraries'][0]['SupportedPlatformVariant'] = 'simulator'
    (xcframework / 'Info.plist').write_bytes(plistlib.dumps(info))
    report = invoke(['--platform=ios', '--variant=simulator', '--arch=arm64'], 1, 'wrong-variant')
    assert any(check['name'] == 'xcframework_metadata' and check['status'] == 'failed' for check in report['checks'])
    info['AvailableLibraries'][0].pop('SupportedPlatformVariant')
    (xcframework / 'Info.plist').write_bytes(plistlib.dumps(info))
    (xcframework / 'ios-arm64/libFixture.a').unlink()
    report = invoke([], 1, 'missing-product')
    assert any(check['name'] == 'xcframework_layout' and check['status'] == 'failed' for check in report['checks'])
    xcode = project / 'Targets.xcodeproj'
    xcode.mkdir()
    objects = {'root': {'isa': 'PBXProject'}, 'target': {'isa': 'PBXNativeTarget', 'name': 'PackageApp', 'packageProductDependencies': ['product']},
               'product': {'isa': 'XCSwiftPackageProductDependency', 'productName': 'Fixture', 'package': 'package'},
               'package': {'isa': 'XCRemoteSwiftPackageReference', 'repositoryURL': 'https://example.invalid/Fixture.git'}}
    (xcode / 'project.pbxproj').write_bytes(plistlib.dumps({'rootObject': 'root', 'objectVersion': '60', 'objects': objects}))
    (project / '.swiftpods').mkdir()
    state = {'specs': [{'name': 'Fixture', 'module_name': 'Fixture'}],
             'targets': [{'pods': ['Fixture'], 'user_project': str(xcode), 'user_targets': ['PodApp']}]}
    (project / '.swiftpods/installation.json').write_text(json.dumps(state))
    report = invoke([], 1, 'disjoint-module-owners')
    assert not any(check['name'] == 'duplicate_sdk' for check in report['checks']), report['checks']
    state['targets'][0]['user_targets'] = ['PackageApp']
    (project / '.swiftpods/installation.json').write_text(json.dumps(state))
    report = invoke([], 1, 'overlapping-module-owners')
    assert any(check['name'] == 'duplicate_sdk' for check in report['checks']), report['checks']
    result = {'schema_version': 1, 'status': 'passed', 'fixture': str(directory),
              'verified': ['real_device_and_simulator_arm64_distinguished', 'static_archive_metadata', 'xcframework_metadata_matches',
                           'wrong_variant_rejected', 'missing_arch_rejected', 'minimum_os_reported', 'missing_product_reported', 'no_project_ruby_execution',
                           'duplicate_sdk_scoped_to_user_target']}
    (ROOT / 'test-results/doctor.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    from reporting import execute
    execute(main, 'doctor.json')
