#!/usr/bin/env python3
"""Compare selected test/app products and execute both independent engines."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
from bootstrap import ROOT, environment
from native_supplementary_tests import build, install
from reference_compare import reference_environment
from reporting import execute
from supplementary_fixture import create, RESULT_HOOK


def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--gem-home', type=Path, required=True); args = parser.parse_args()
    base = Path(tempfile.mkdtemp(prefix='supplementary-reference-', dir=ROOT / '.build'))
    for name in ['native', 'reference']:
        parent = base / name; parent.mkdir(); create(parent / 'project')
        podfile = parent / 'project/Podfile'; podfile.write_text(podfile.read_text() + RESULT_HOOK)
    env = environment(); env['GEM_HOME'] = str(base / 'empty-gems'); env['GEM_PATH'] = env['GEM_HOME']; env['SWIFTPODS_CACHE_ROOT'] = str(base / 'cache')
    installed = install(base / 'native/project', env)
    ruby, ref_env = reference_environment(args.gem_home, base / 'reference')
    code = "require 'bundler/setup';require 'cocoapods';abort('Unexpected reference version') unless Pod::VERSION == '1.17.0';Pod::Command.run(ARGV)"
    with base.joinpath('reference-install.log').open('wb') as output:
        result = subprocess.run([ruby, '-e', code, '--', 'install', '--no-ansi'], cwd=base / 'reference/project', env=ref_env, stdout=output, stderr=subprocess.STDOUT, timeout=120)
    assert result.returncode == 0, str(base / 'reference-install.log')
    assert json.loads((base / 'native/project/installation-results.json').read_text()) == json.loads((base / 'reference/project/installation-results.json').read_text())
    expected_names = {'SpecKit', 'SpecKit/Tests', 'SpecKit/Example', 'TestHelper', 'AppHelper'}
    actual = {spec['name'] for event in installed['events'] if event['kind'] == 'installation' for spec in event['specs']}
    assert actual == expected_names, actual
    for name in ['native', 'reference']:
        parent = base / name; work = parent / 'project'
        lock = work.joinpath('Podfile.lock').read_text()
        assert all(pod + ' (' in lock for pod in expected_names)
        graph = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(work / 'Pods/Pods.xcodeproj/project.pbxproj')]))
        targets = {item['name']: item for item in graph['objects'].values() if item['isa'] == 'PBXNativeTarget'}
        assert targets['SpecKit-Unit-Tests']['productType'] == 'com.apple.product-type.bundle.unit-test'
        assert targets['SpecKit-Example']['productType'] == 'com.apple.product-type.application'
        assert 'SWIFTPODS_INSTALLATION_RESULT_MARKER' in (work / 'Pods/Pods.xcodeproj/project.pbxproj').read_text()
        assert build(work, parent, 'SpecKit-Unit-Tests', 'test').find('** TEST SUCCEEDED **') >= 0
        build(work, parent, 'SpecKit-Example')
        candidates = list((parent / 'DerivedData/Build/Products').rglob('SpecKit-Example.app/Contents/MacOS/SpecKit-Example'))
        assert len(candidates) == 1, candidates
        assert subprocess.check_output([str(candidates[0])], text=True).strip() == 'app-value=16 resources=ok'
    report = {'status': 'passed', 'engine': 'swift', 'reference': '1.17.0', 'fixture': str(base),
              'verified': ['independent native/reference test/app selection', 'matching resolved names and product types', 'matching test dependency/resource isolation', 'real XCTest passes in both engines', 'app spec builds/runs in both engines', 'test scheme environment and Info.plist markers'],
              'unverified': ['exact project/lock bytes', 'hosted tests', 'other platforms', 'complete DSL/API parity']}
    report['verified_cases'] = ['Installer.target_installation_results', 'PodTarget.specs'] + ['TargetInstallationResult.' + name for name in ['native_target', 'resource_bundle_targets', 'test_specs_by_native_target', 'app_specs_by_native_target', 'non_library_specs_by_native_target', 'test_resource_bundle_targets', 'app_resource_bundle_targets', 'native_target_for_spec']]
    ROOT.joinpath('test-results/native-supplementary-reference.json').write_text(json.dumps(report, indent=2) + '\n'); print(json.dumps(report, indent=2))


if __name__ == '__main__': execute(main, 'native-supplementary-reference.json')
