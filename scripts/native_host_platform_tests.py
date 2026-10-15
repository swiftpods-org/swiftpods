#!/usr/bin/env python3
"""Build supplementary app/unit/UI host products for additional Apple SDKs."""
import argparse
import json
from pathlib import Path
import platform
import subprocess
import tempfile
from bootstrap import ROOT, environment
from native_supplementary_tests import install
from reporting import execute
from vendor_fixture import run

DESTINATIONS = {
    'tvos': ('tvos', '17.0', 'appletvsimulator', 'tvOS Simulator'),
    'visionos': ('visionos', '1.0', 'xrsimulator', 'visionOS Simulator'),
    'catalyst': ('ios', '17.0', 'macosx', 'macOS,variant=Mac Catalyst'),
}


def create(work, name, linkage):
    work.mkdir(parents=True)
    platform_name, minimum, _, _ = DESTINATIONS[name]
    module = work / 'HostMatrixKit'
    module.mkdir()
    for folder in ['Sources', 'Tests', 'UI', 'App']:
        (module / folder).mkdir()
    (module / 'Sources/HostMatrixKit.h').write_text('int host_matrix_value(void);\n')
    (module / 'Sources/HostMatrixKit.m').write_text('int host_matrix_value(void) { return 41; }\n')
    (module / 'Tests/own.txt').write_text('unit-resource')
    (module / 'Tests/Tests.m').write_text('''#import <XCTest/XCTest.h>
#import <HostMatrixKit/HostMatrixKit.h>
@interface HostMatrixTests : XCTestCase @end
@implementation HostMatrixTests
- (void)testLibraryAndResource { XCTAssertEqual(host_matrix_value(), 41); XCTAssertNotNil([[NSBundle bundleForClass:self.class] pathForResource:@"own" ofType:@"txt"]); }
@end
''')
    (module / 'UI/Tests.m').write_text('''#import <XCTest/XCTest.h>
@interface HostMatrixUITests : XCTestCase @end
@implementation HostMatrixUITests
- (void)testHostLaunch { XCUIApplication *app = [XCUIApplication new]; [app launch]; XCTAssertNotEqual(app.state, XCUIApplicationStateNotRunning); [app terminate]; }
@end
''')
    (module / 'App/main.m').write_text('#import <UIKit/UIKit.h>\nint main(int argc, char **argv) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, nil); } }\n')
    tests = [{'name': label, 'source_files': 'Tests/*.m', 'resources': 'Tests/own.txt'} for label in ['Standalone', 'Generated', 'Named']]
    tests[1]['requires_app_host'] = True
    tests[2].update(requires_app_host=True, app_host_name='HostMatrixKit/Example', dependencies={'HostMatrixKit/Example': []})
    tests += [{'name': label, 'test_type': 'ui', 'requires_app_host': True, 'source_files': 'UI/*.m', **({'app_host_name': 'HostMatrixKit/Example', 'dependencies': {'HostMatrixKit/Example': []}} if label == 'NamedUI' else {})} for label in ['NamedUI', 'GeneratedUI']]
    spec = {'name': 'HostMatrixKit', 'version': '1.0', 'summary': 'Supplementary SDK fixture', 'homepage': 'https://swiftpods.org', 'authors': 'SwiftPods', 'license': 'MIT', 'source': {'git': 'https://example.invalid/fixture.git', 'tag': '1.0'}, 'source_files': 'Sources/*.{h,m}', 'platforms': {platform_name: minimum}, 'testspecs': tests, 'appspecs': [{'name': 'Example', 'source_files': 'App/main.m', 'frameworks': ['UIKit']}]}
    (module / 'HostMatrixKit.podspec.json').write_text(json.dumps(spec))
    text = f"platform :{platform_name}, '{minimum}'\n"
    if linkage != 'library': text += f'use_frameworks! :linkage => :{linkage}\n'
    text += "target 'App' do\n pod 'HostMatrixKit', :path => './HostMatrixKit', :testspecs => ['Standalone', 'Generated', 'Named', 'NamedUI', 'GeneratedUI']\nend\n"
    if name == 'catalyst':
        text += '''post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |configuration|
      configuration.build_settings['SUPPORTS_MACCATALYST'] = 'YES'
      configuration.build_settings['SUPPORTED_PLATFORMS'] = 'iphoneos iphonesimulator macosx'
    end
  end
end
'''
    (work / 'Podfile').write_text(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=list(DESTINATIONS), action='append')
    parser.add_argument('--linkage', choices=['library', 'static', 'dynamic'], action='append')
    parser.add_argument('--configuration', choices=['Debug', 'Release'], action='append')
    args = parser.parse_args()
    parent = Path(tempfile.mkdtemp(prefix='native-host-platforms-', dir=ROOT / '.build'))
    print('Host platform fixtures:', parent, flush=True)
    env = environment()
    env['SWIFTPODS_CACHE_ROOT'] = str(parent / 'cache')
    swift = Path(subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip())
    builds = []
    for name in args.platform or list(DESTINATIONS):
        platform_name, minimum, sdk, destination = DESTINATIONS[name]
        for linkage in args.linkage or ['library', 'static', 'dynamic']:
            work = parent / (name + '-' + linkage)
            create(work, name, linkage)
            install(work, env, '--no-integrate')
            for configuration in args.configuration or ['Debug', 'Release']:
                for scheme in ['HostMatrixKit-Example', 'HostMatrixKit-Unit-Standalone', 'HostMatrixKit-Unit-Generated', 'HostMatrixKit-Unit-Named', 'HostMatrixKit-UI-NamedUI', 'HostMatrixKit-UI-GeneratedUI']:
                    command = ['xcodebuild', '-project', 'Pods/Pods.xcodeproj', '-scheme', scheme, '-configuration', configuration, '-destination', 'generic/platform=' + destination, '-sdk', sdk, '-derivedDataPath', work / 'DerivedData', 'CODE_SIGNING_ALLOWED=NO', 'GCC_TREAT_WARNINGS_AS_ERRORS=YES', 'SWIFT_TREAT_WARNINGS_AS_ERRORS=YES', 'ARCHS=' + platform.machine(), 'ONLY_ACTIVE_ARCH=YES']
                    command += ['TOOLCHAIN_DIR=' + str(swift.parents[2]), 'TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault']
                    if name == 'catalyst': command += ['SUPPORTS_MACCATALYST=YES']
                    log = work / (scheme + '-' + configuration + '.log')
                    run(command + ['build-for-testing' if '-Unit-' in scheme or '-UI-' in scheme else 'build'], work, log, env)
                    builds.append({'platform': platform_name, 'sdk': 'maccatalyst' if name == 'catalyst' else sdk, 'destination': destination, 'configuration': configuration, 'linkage': linkage, 'scheme': scheme, 'architecture': platform.machine(), 'log': str(log)})
    report = {'status': 'passed', 'engine': 'swift', 'fixture': str(parent), 'builds': builds, 'executions': [],
              'verified': ['real app, standalone/generated/named unit targets and generated/named UI runners build for the explicitly listed SDK configurations'],
              'unverified': ['execution on these destinations', 'device SDK supplementary builds and signing', 'watchOS supplementary targets', 'macOS UI interaction', 'complete supplementary host matrix']}
    (ROOT / 'test-results/native-host-platforms.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__': execute(main, 'native-host-platforms.json')
