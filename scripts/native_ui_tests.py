#!/usr/bin/env python3
"""Execute Swift test/app specs and actual UI interaction on an owned simulator."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from bootstrap import ROOT, environment
from native_supplementary_tests import install
from reporting import execute
from ui_test_fixture import build, create, declarative, podfile, simulator


def graph_contract(work):
    graph = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(work / 'Pods/Pods.xcodeproj/project.pbxproj')]))
    objects = graph['objects']
    targets = {item['name']: (id, item) for id, item in objects.items() if item['isa'] == 'PBXNativeTarget'}
    associations = objects[graph['rootObject']]['attributes']['TargetAttributes']
    for label, host, ui in [('UIWidget-UI-Interface', 'UIWidget-Example', True), ('UIWidget-UI-Generated', 'AppHost-UIWidget-UI-Tests', True), ('UIWidget-Unit-Hosted', 'UIWidget-Example', False)]:
        id, target = targets[label]
        host_id = targets[host][0]
        assert target['productType'] == 'com.apple.product-type.bundle.' + ('ui-testing' if ui else 'unit-test')
        assert associations[id]['TestTargetID'] == host_id
        assert any(objects[dependency]['target'] == host_id for dependency in target['dependencies'])
        for config in objects[target['buildConfigurationList']]['buildConfigurations']:
            settings = objects[config]['buildSettings']
            if ui:
                assert settings['TEST_TARGET_NAME'] == host
                assert 'TEST_HOST' not in settings and 'BUNDLE_LOADER' not in settings
            else:
                assert settings['TEST_HOST'].endswith(host + '.app/' + host)
                assert settings['BUNDLE_LOADER'] == '$(TEST_HOST)'
    standalone_id, standalone = targets['UIWidget-Unit-Units']
    assert associations.get(standalone_id, {}).get('TestTargetID') is None
    for config in objects[standalone['buildConfigurationList']]['buildConfigurations']:
        assert 'TEST_HOST' not in objects[config]['buildSettings']
    consumer = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(work / 'Demo.xcodeproj/project.pbxproj')]))
    references = [item.get('path', '') for item in consumer['objects'].values() if item['isa'] == 'PBXFileReference']
    assert not any('.xctest' in value or 'UIWidget-Example' in value or 'AppHost-' in value for value in references), references


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, help='Exercise the packaged release binary')
    args = parser.parse_args()
    bundle = args.bundle.resolve() if args.bundle else None
    binary = bundle / 'bin/swiftpods' if bundle else None
    parent = Path(tempfile.mkdtemp(prefix='native-ui-', dir=ROOT / '.build'))
    print('UI fixtures:', parent, flush=True)
    env = environment(bundle)
    env.update(GEM_HOME=str(parent / 'empty-gems'), GEM_PATH=str(parent / 'empty-gems'), SWIFTPODS_CACHE_ROOT=str(parent / 'cache'))
    scenarios = []
    with simulator(parent) as device:
        for linkage in (['static'] if bundle else ['static', 'dynamic', None]):
            group = parent / (linkage or 'library'); group.mkdir()
            work = group / 'project'; data = create(work, linkage)
            if linkage == 'static':
                podfile(work, linkage, selections=False)
                install(work, env, binary=binary)
                graph = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(work / 'Pods/Pods.xcodeproj/project.pbxproj')]))
                assert {item['name'] for item in graph['objects'].values() if item['isa'] == 'PBXNativeTarget'} == {'UIWidget'}
                podfile(work, linkage)
            install(work, env, binary=binary)
            lock = work.joinpath('Podfile.lock').read_bytes()
            install(work, env, '--deployment', '--offline', binary=binary)
            assert work.joinpath('Podfile.lock').read_bytes() == lock
            graph_contract(work)
            text = build(work, group, 'UIWidget-UI-Interface', device, 'test')
            assert 'testButtonChangesLibraryValue' in text
            if linkage == 'static':
                for scheme, test in [('UIWidget-UI-Generated', 'testGeneratedHostLaunches'), ('UIWidget-Unit-Units', 'testLibraryAndOwnResources'), ('UIWidget-Unit-Hosted', 'testLibraryAndOwnResources')]:
                    assert test in build(work, group, scheme, device, 'test')
                podfile(work, linkage, selections=False)
                install(work, env, binary=binary)
                schemes = work / 'Pods/Pods.xcodeproj/xcshareddata/xcschemes'
                assert not any(schemes.glob('UIWidget-UI-*.xcscheme'))
                assert not any(schemes.glob('UIWidget-Unit-*.xcscheme'))
                assert not (schemes / 'UIWidget-Example.xcscheme').exists()
                declarative(work, data)
                hardened_env = dict(env, SWIFTPODS_RUBY='/swiftpods-fixture-no-ruby')
                install(work, hardened_env, '--hardened', '--offline', binary=binary)
                graph_contract(work)
                assert 'testButtonChangesLibraryValue' in build(work, group, 'UIWidget-UI-Interface', device, 'test')
            scenarios.append({'linkage': linkage or 'static-library', 'status': 'passed', 'fixture': str(group)})
    report = {'status': 'passed', 'engine': 'swift', 'fixture': str(parent), 'scenarios': scenarios,
              'verified': ['iOS simulator UI runner launches a named app spec and taps its button', 'generated iOS UI host launches', 'Swift standalone and hosted unit test execution', 'Swift app spec execution', 'own UI/unit resources and Info.plist', 'test scheme environment', 'runner and bundle-loader host associations', 'consumer isolation', 'offline deployment reinstall', 'managed scheme removal', 'hardened UI selection without Ruby', 'ad-hoc simulator signing'],
              'unverified': ['macOS/tvOS UI execution', 'physical devices', 'distribution signing', 'complete DSL/API parity']}
    if bundle:
        manifest = json.loads(bundle.joinpath('compatibility.json').read_text())
        report.update(bundle=str(bundle), bundle_digest=manifest['bundle_digest'])
    else: report['verified'].append('three library linkage modes')
    name = 'native-packaged-ui.json' if bundle else 'native-ui.json'
    ROOT.joinpath('test-results', name).write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__': execute(main, 'native-packaged-ui.json' if '--bundle' in sys.argv else 'native-ui.json')
