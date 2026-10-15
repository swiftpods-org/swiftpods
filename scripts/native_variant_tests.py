#!/usr/bin/env python3
"""Build isolated variants of one pod for simultaneous consumers."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from bootstrap import ROOT, environment
from native_supplementary_tests import install
from reporting import execute
from variant_fixture import CONSUMERS, build_consumers, contract, create, podfile, supplementary
from vendor_fixture import sdk


def snapshot(work):
    paths = sorted(work.glob('*.xcodeproj/project.pbxproj')) + sorted(work.glob('Pods/*.xcodeproj/project.pbxproj')) + [work / 'Podfile.lock']
    return {str(path.relative_to(work)): path.read_bytes() for path in paths}


def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--bundle', type=Path); args = parser.parse_args()
    bundle = args.bundle.resolve() if args.bundle else None
    binary = bundle / 'bin/swiftpods' if bundle else ROOT / '.build/debug/swiftpods'
    parent = Path(tempfile.mkdtemp(prefix='native-variants-', dir=ROOT / '.build')); print('Variant fixtures:', parent, flush=True)
    sdk_path = sdk(parent, 'VariantBinary', platforms=('macosx',))
    work = parent / 'project'; create(work, sdk_path)
    env = environment(bundle); env.update(GEM_HOME=str(parent / 'empty'), GEM_PATH=str(parent / 'empty'), SWIFTPODS_CACHE_ROOT=str(parent / 'cache'))
    install(work, env, binary=binary); contract(work)
    before = snapshot(work)
    install(work, env, '--deployment', '--offline', binary=binary)
    assert snapshot(work) == before, 'Deployment changed variants or user projects'
    for configuration in ['Debug', 'Staging', 'Release']: build_consumers(work, parent, configuration)
    supplementary(work, parent)
    # Reuse both source projects and build outputs across layout changes.
    podfile(work, multiple=False); install(work, env, '--offline', binary=binary); contract(work)
    assert not work.joinpath('Pods/VariantKit.xcodeproj').exists()
    assert not work.joinpath('Pods/VariantPeer.xcodeproj').exists()
    build_consumers(work, parent); supplementary(work, parent)
    # Same deployment, different linkage must choose the exact transitive variant.
    consumers = [(name, mode, leaf, '13.0' if name == 'StaticB' else deployment, selected) for name, mode, leaf, deployment, selected in CONSUMERS]
    podfile(work, multiple=False, consumers=consumers); install(work, env, '--offline', binary=binary); contract(work)
    for text in snapshot(work).values():
        assert b'VariantPeer-framework-static-osx13.1' not in text
        assert b'VariantKit-B-Common-framework-static-osx13.1' not in text
    build_consumers(work, parent)
    subprocess.run([str(binary), 'deintegrate', '--json'], cwd=work, env=env, check=True, capture_output=True)
    for path in work.glob('*.xcodeproj/project.pbxproj'):
        graph = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))
        for item in graph['objects'].values():
            if item.get('isa') == 'PBXNativeTarget': assert not item.get('dependencies'), (path, item)
    install(work, env, '--offline', binary=binary); build_consumers(work, parent)
    report = {'status': 'passed', 'engine': 'swift', 'fixture': str(parent),
              'scenarios': ['split projects in Debug/Staging/Release', 'same-output transition to a single project', 'same deployment with different framework linkage'],
              'verified': ['six simultaneously built and executed macOS consumers', 'five library variants and four transitive variants', 'equivalent consumers share a library target', 'selected subspec source and header isolation', 'archive and static/dynamic framework outputs do not collide', 'transitive XCFramework compilation and framework embedding', 'direct resources and resource bundles belong to the selected variant', 'two independent XCTest and app spec variants', 'pre-install pod target counts and preserved post-install settings', 'byte-stable offline deployment', 'old explicit dependencies removed after variant changes', 'deintegration and reintegration of variant dependencies'],
              'unverified': ['identical reference project bytes', 'all plugin APIs', 'all Apple platform/linkage combinations', 'physical devices and signing']}
    if bundle:
        manifest = json.loads(bundle.joinpath('compatibility.json').read_text()); report.update(bundle=str(bundle), bundle_digest=manifest['bundle_digest'])
    name = 'native-packaged-variants.json' if bundle else 'native-variants.json'
    ROOT.joinpath('test-results', name).write_text(json.dumps(report, indent=2) + '\n'); print(json.dumps(report, indent=2))


if __name__ == '__main__': execute(main, 'native-packaged-variants.json' if '--bundle' in sys.argv else 'native-variants.json')
