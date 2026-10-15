#!/usr/bin/env python3
"""Apple build/run matrix. Device builds/archives are unsigned, not device runs."""
import argparse
import json
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile
import time
from integration import ROOT, CLI, RUBY, environment, run
from binary_fixture import add_vendor


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skip-simulator-run', action='store_true')
    parser.add_argument('--binary-only', action='store_true')
    args = parser.parse_args()
    directory = Path(tempfile.mkdtemp(prefix='apple-', dir=ROOT / '.build'))
    env = environment(directory / 'home')
    Path(env['HOME']).mkdir()
    env['TOOLCHAINS'] = 'com.apple.dt.toolchain.XcodeDefault'
    simulator = None
    results = []
    try:
        if not args.skip_simulator_run:
            available = json.loads(subprocess.check_output(['/usr/bin/xcrun', 'simctl', 'list', 'runtimes', '-j']))['runtimes']
            runtimes = [entry for entry in available if entry.get('isAvailable') and '.iOS-' in entry['identifier']]
            assert runtimes, 'An installed iOS simulator runtime is required'
            runtime = sorted(runtimes, key=lambda entry: tuple(map(int, entry['version'].split('.'))))[-1]
            devices = json.loads(subprocess.check_output(['/usr/bin/xcrun', 'simctl', 'list', 'devicetypes', '-j']))['devicetypes']
            parts = list(map(int, runtime['version'].split('.'))) + [0, 0]
            encoded = (parts[0] << 16) | (parts[1] << 8) | parts[2]
            compatible = [entry for entry in devices if entry.get('name', '').startswith('iPhone') and entry.get('minRuntimeVersion', 0) <= encoded <= entry.get('maxRuntimeVersion', 0xffffffff)]
            device = max(compatible, key=lambda entry: (entry.get('minRuntimeVersion', 0), entry['name']))
            simulator = subprocess.check_output(['/usr/bin/xcrun', 'simctl', 'create', 'SwiftPods Fixture', device['identifier'], runtime['identifier']], text=True).strip()
            run(['/usr/bin/xcrun', 'simctl', 'boot', simulator], directory, env, directory / 'simulator-boot.log')
            run(['/usr/bin/xcrun', 'simctl', 'bootstatus', simulator, '-b'], directory, env, directory / 'simulator-ready.log')
        linkages = ['xcframework-static', 'xcframework-dynamic']
        if not args.binary_only:
            linkages = ['static', 'dynamic', 'libraries'] + linkages
        for linkage in linkages:
            project = directory / linkage
            shutil.copytree(ROOT / 'Tests/Fixtures/MixedLanguages', project)
            shutil.copy2(ROOT / 'Tests/Fixtures/iOS/main.mm', project / 'Sources/main.mm')
            shutil.copy2(ROOT / 'Tests/Fixtures/iOS/FixtureIntent.swift', project / 'Sources/FixtureIntent.swift')
            shutil.copy2(ROOT / 'Tests/Fixtures/iOS/GameCoreIntent.swift', project / 'Modules/GameCore/Sources/GameCoreIntent.swift')
            info = {'CFBundleExecutable': '$(EXECUTABLE_NAME)', 'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)',
                    'CFBundleName': '$(PRODUCT_NAME)', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
                    'CFBundleShortVersionString': '1.0', 'LSRequiresIPhoneOS': True, 'UILaunchScreen': {},
                    'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'],
                    'UISupportedInterfaceOrientations~ipad': ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationPortraitUpsideDown', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'],
                    'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False,
                     'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [{'UISceneConfigurationName': 'Fixture',
                                                                                       'UISceneDelegateClassName': 'SwiftPodsFixtureSceneDelegate'}]}}}
            (project / 'Info.plist').write_bytes(plistlib.dumps(info))
            podfile = (project / 'Podfile').read_text().replace("platform :osx, '13.0'", "platform :ios, '15.0'")
            if linkage == 'dynamic':
                podfile = podfile.replace(':linkage => :static', ':linkage => :dynamic')
            elif linkage == 'libraries':
                podfile = podfile.replace('use_frameworks! :linkage => :static', 'use_modular_headers!')
            (project / 'Podfile').write_text(podfile)
            spec = project / 'Modules/GameCore/GameCore.podspec'
            spec.write_text(spec.read_text().replace("spec.osx.deployment_target = '13.0'", "spec.ios.deployment_target = '15.0'"))
            run([RUBY, '-rbundler/setup', ROOT / 'Tests/Fixtures/iOS/create_project.rb'], project, env, directory / (linkage + '-create.log'))
            if linkage.startswith('xcframework-'):
                add_vendor(project, env, dynamic=linkage == 'xcframework-dynamic')
            run([CLI, 'install', '--no-ansi'], project, env, directory / (linkage + '-install.log'))
            for configuration in ['Debug', 'Release']:
                derived = directory / (linkage + '-' + configuration)
                destination = 'id=' + simulator if simulator else 'generic/platform=iOS Simulator'
                run(['xcodebuild', '-workspace', 'Demo.xcworkspace', '-scheme', 'Demo', '-configuration', configuration,
                     '-toolchain', 'com.apple.dt.toolchain.XcodeDefault', '-sdk', 'iphonesimulator', '-destination', destination,
                     '-derivedDataPath', derived, 'build'], project, env, directory / (linkage + '-' + configuration + '-simulator.log'), reject_warnings=True)
                app = derived / ('Build/Products/' + configuration + '-iphonesimulator/Demo.app')
                assert list(app.rglob('PrivacyInfo.xcprivacy'))
                assert list(app.rglob('GameCoreResources.bundle'))
                if linkage.startswith('xcframework-'):
                    embedded = (app / 'Frameworks/VendorKit.framework/VendorKit').exists()
                    assert embedded == (linkage == 'xcframework-dynamic'), (linkage, embedded)
                run([CLI, 'doctor', '--static', '--app', app, '--platform', 'ios', '--variant', 'simulator', '--arch', platform.machine(), '--json'],
                    project, env, directory / (linkage + '-' + configuration + '-doctor.json'))
                if simulator:
                    run(['/usr/bin/xcrun', 'simctl', 'install', simulator, app], project, env, directory / (linkage + '-' + configuration + '-install-app.log'))
                    container = Path(subprocess.check_output(['/usr/bin/xcrun', 'simctl', 'get_app_container', simulator, 'org.swiftpods.ios-fixture', 'data'], text=True).strip())
                    validation = container / 'Documents/validation.json'
                    validation.unlink(missing_ok=True)
                    run(['/usr/bin/xcrun', 'simctl', 'launch', '--terminate-running-process', simulator, 'org.swiftpods.ios-fixture'], project, env, directory / (linkage + '-' + configuration + '-launch.log'))
                    deadline = time.monotonic() + 30
                    while not validation.exists() and time.monotonic() < deadline:
                        time.sleep(0.1)
                    value = json.loads(validation.read_text())
                    assert value == {'languages': 15, 'resources': True, 'privacy': True, 'vendor': 42 if linkage.startswith('xcframework-') else 0}, value
                    (directory / (linkage + '-' + configuration + '-runtime.json')).write_text(json.dumps(value, indent=2) + '\n')
                    run(['/usr/bin/xcrun', 'simctl', 'terminate', simulator, 'org.swiftpods.ios-fixture'], project, env, directory / (linkage + '-' + configuration + '-terminate.log'))
                results.append({'linkage': linkage, 'configuration': configuration, 'operation': 'simulator_build_run' if simulator else 'simulator_build'})
            archive = directory / (linkage + '.xcarchive')
            run(['xcodebuild', '-workspace', 'Demo.xcworkspace', '-scheme', 'Demo', '-configuration', 'Release',
                 '-toolchain', 'com.apple.dt.toolchain.XcodeDefault', '-sdk', 'iphoneos', '-destination', 'generic/platform=iOS',
                 '-archivePath', archive, 'archive'], project, env, directory / (linkage + '-device-archive.log'), reject_warnings=True)
            app = archive / 'Products/Applications/Demo.app'
            assert list(app.rglob('PrivacyInfo.xcprivacy')) and list(app.rglob('GameCoreResources.bundle'))
            if linkage.startswith('xcframework-'):
                assert (app / 'Frameworks/VendorKit.framework/VendorKit').exists() == (linkage == 'xcframework-dynamic')
            results.append({'linkage': linkage, 'configuration': 'Release', 'operation': 'unsigned_device_build_archive'})
    finally:
        if simulator:
            subprocess.run(['/usr/bin/xcrun', 'simctl', 'shutdown', simulator], capture_output=True)
            subprocess.run(['/usr/bin/xcrun', 'simctl', 'delete', simulator], capture_output=True)
    report = {'schema_version': 1, 'status': 'passed', 'fixture': str(directory), 'matrix': results,
              'verified': ['ios_five_languages', 'debug_release', 'localized_resources', 'privacy_manifest', 'unsigned_device_archive', 'static_dynamic_xcframework_device_simulator', 'dynamic_only_embedding'] + ([] if args.binary_only else ['static_frameworks', 'dynamic_frameworks', 'static_libraries']),
              'unverified': ['physical_device_runtime', 'distribution_signing', 'store_submission']}
    (ROOT / ('test-results/apple-binary.json' if args.binary_only else 'test-results/apple-matrix.json')).write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    from reporting import execute
    execute(main, 'apple-binary.json' if '--binary-only' in __import__('sys').argv else 'apple-matrix.json')
