#!/usr/bin/env python3
"""Build a real tagged package through native Xcode SPM references."""
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
from integration import ROOT, CLI, RUBY, environment, run, snapshot


def main():
    directory = Path(tempfile.mkdtemp(prefix='spm-', dir=ROOT / '.build'))
    env = environment(directory / 'home')
    Path(env['HOME']).mkdir()
    env.update(GIT_AUTHOR_NAME='Tests', GIT_AUTHOR_EMAIL='tests@example.invalid', GIT_COMMITTER_NAME='Tests', GIT_COMMITTER_EMAIL='tests@example.invalid')
    package = directory / 'FixtureNetworking'
    (package / 'Sources/FixtureNetworking').mkdir(parents=True)
    (package / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "FixtureNetworking", products: [.library(name: "FixtureNetworking", targets: ["FixtureNetworking"])], targets: [.target(name: "FixtureNetworking")])
''')
    (package / 'Sources/FixtureNetworking/Value.swift').write_text('@_cdecl("spm_fixture_value") public func spmFixtureValue() -> Int32 { 6 }\n')
    for arguments in [['git', 'init'], ['git', 'add', '.'], ['git', 'commit', '-m', 'Fixture'], ['git', 'tag', '1.0.0']]:
        run(arguments, package, env, directory / ('git-' + arguments[1] + '.log'))
    project = directory / 'project'
    shutil.copytree(ROOT / 'Tests/Fixtures/MixedLanguages', project)
    run([RUBY, '-rbundler/setup', ROOT / 'Tests/Fixtures/create_project.rb'], project, env, directory / 'create.log')
    original_podfile = (project / 'Podfile').read_text()
    declaration = f"  spm 'FixtureNetworking', :git => {json.dumps(package.as_uri())}, :exact => '1.0.0', :products => ['FixtureNetworking']\n"
    extended = original_podfile.replace("target 'Demo' do\n", "target 'Demo' do\n" + declaration)
    (project / 'Podfile').write_text(extended)
    main = project / 'Sources/main.mm'
    main.write_text(main.read_text().replace('int main(void)', 'extern "C" int spm_fixture_value(void);\nint main(void)').replace('int result = ', 'int result = spm_fixture_value() + ').replace('result != 15', 'result != 21').replace('mixed=15', 'mixed=21'))

    def invoke(arguments, status=0, name='command'):
        result = subprocess.run([str(CLI), *arguments, '--json'], cwd=project, env=env, capture_output=True, timeout=90)
        (directory / (name + '.stdout')).write_bytes(result.stdout)
        (directory / (name + '.stderr')).write_bytes(result.stderr)
        assert result.returncode == status, (name, result.stderr.decode(errors='replace')[-5000:])
        return json.loads(result.stdout)

    invoke(['install', '--no-ansi'], name='install')
    ownership = json.loads((project / '.swiftpods/spm.json').read_text())
    assert len(ownership['owned']) == 3, ownership
    before = snapshot(project)
    invoke(['install', '--deployment', '--no-ansi'], name='noop')
    assert snapshot(project) == before
    derived = directory / 'derived'
    run(['xcodebuild', '-workspace', 'Demo.xcworkspace', '-scheme', 'Demo', '-configuration', 'Debug',
         '-toolchain', 'com.apple.dt.toolchain.XcodeDefault', '-destination', 'platform=macOS,arch=' + platform.machine(),
         '-derivedDataPath', derived, 'build'], project, env, directory / 'build.log', reject_warnings=True)
    _, output = run([derived / 'Build/Products/Debug/Demo.app/Contents/MacOS/Demo'], project, env, directory / 'run.log')
    assert output == 'mixed=21 resources=ok privacy=ok\n'
    resolved_paths = list(project.glob('**/Package.resolved'))
    assert resolved_paths, 'Xcode did not create Package.resolved'
    resolved = {str(path.relative_to(project)): path.read_bytes() for path in resolved_paths}
    invoke(['install', '--no-ansi'], name='preserve-resolved')
    assert all((project / path).read_bytes() == value for path, value in resolved.items())
    # Invalid four-component package versions never become guessed SemVer.
    (project / 'Podfile').write_text(extended.replace("'1.0.0'", "'1.0.0.1'"))
    before_invalid = {key: value for key, value in snapshot(project).items() if key != 'Podfile'}
    failure = invoke(['install', '--no-ansi'], 1, 'invalid-version')
    assert any(event.get('code') == 'SP-SPM-VERSION' for event in failure['events'])
    assert failure['project_state'] == 'failed_no_managed_changes'
    assert {key: value for key, value in snapshot(project).items() if key != 'Podfile'} == before_invalid
    assert invoke(['recover'], 1, 'recover-invalid')['diagnostic']['code'] == 'SP-RECOVER-NOT-NEEDED'
    # Removing the opt-in declaration removes only objects that we created.
    (project / 'Podfile').write_text(original_podfile)
    invoke(['install', '--no-ansi'], name='remove-owned')
    project_data = subprocess.check_output(['/usr/bin/plutil', '-convert', 'json', '-o', '-', str(project / 'Demo.xcodeproj/project.pbxproj')])
    assert not any(value.get('isa') == 'XCRemoteSwiftPackageReference' for value in json.loads(project_data)['objects'].values())
    assert all((project / path).read_bytes() == value for path, value in resolved.items())
    # Existing native SPM products survive pure-pod installation/deintegration.
    script = directory / 'existing.rb'
    script.write_text('''require 'xcodeproj'
p = Xcodeproj::Project.open('Demo.xcodeproj')
package = p.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
package.repositoryURL = 'https://example.invalid/existing.git'
package.requirement = {'kind'=>'exactVersion', 'version'=>'1.0.0'}
p.root_object.package_references << package
product = p.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
product.package = package
product.product_name = ARGV.fetch(0)
p.targets.first.package_product_dependencies << product
p.save
''')
    run([RUBY, '-rbundler/setup', script, 'ExistingProduct'], project, env, directory / 'existing.log')
    invoke(['install', '--no-ansi'], name='existing-install')
    invoke(['deintegrate', '--no-ansi'], name='existing-deintegrate')
    assert b'existing.git' in (project / 'Demo.xcodeproj/project.pbxproj').read_bytes()
    run([RUBY, '-rbundler/setup', script, 'GameCore'], project, env, directory / 'duplicate.log')
    failure = invoke(['install', '--no-ansi'], 1, 'duplicate')
    assert any(event.get('code') == 'SP-DUPLICATE-SDK' for event in failure['events'])
    result = {'schema_version': 1, 'status': 'passed', 'fixture': str(directory),
              'verified': ['explicit_spm_dsl', 'native_xcode_package_reference', 'tagged_package_build_run',
                           'idempotent_spm_install', 'package_resolved_preserved', 'invalid_semver_rejected',
                           'owned_reference_cleanup', 'external_spm_preserved', 'deintegrate_preserves_spm', 'duplicate_module_blocked']}
    (ROOT / 'test-results/spm.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    from reporting import execute
    execute(main, 'spm.json')
