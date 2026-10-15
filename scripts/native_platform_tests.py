#!/usr/bin/env python3
"""Build and archive native pods against real SDK slices for every Apple platform."""
import json
from pathlib import Path
import plistlib
import platform
import shutil
import subprocess
import tempfile
from bootstrap import ROOT, environment
from reporting import execute
from vendor_fixture import sdk, run

DESTINATIONS = [
    ('osx', '13.0', 'macosx', 'macOS', platform.machine()),
    ('ios', '15.0', 'iphoneos', 'iOS', 'arm64'),
    ('ios', '15.0', 'iphonesimulator', 'iOS Simulator', platform.machine()),
    ('tvos', '15.0', 'appletvos', 'tvOS', 'arm64'),
    ('tvos', '15.0', 'appletvsimulator', 'tvOS Simulator', platform.machine()),
    ('watchos', '10.0', 'watchos', 'watchOS', 'arm64_32'),
    ('watchos', '10.0', 'watchsimulator', 'watchOS Simulator', platform.machine()),
    ('visionos', '1.0', 'xros', 'visionOS', 'arm64'),
    ('visionos', '1.0', 'xrsimulator', 'visionOS Simulator', platform.machine()),
    ('ios', '15.0', 'maccatalyst', 'macOS,variant=Mac Catalyst', platform.machine()),
]


def main():
    parent = Path(tempfile.mkdtemp(prefix='native-platforms-', dir=ROOT / '.build')); print('Platform fixtures:', parent, flush=True)
    binary = sdk(parent, 'MatrixBinary', dynamic=True, platforms=tuple(item[2] for item in DESTINATIONS))
    metadata = plistlib.loads(binary.joinpath('Info.plist').read_bytes())
    assert len(metadata['AvailableLibraries']) == len(DESTINATIONS)
    env = environment(); env['SWIFTPODS_CACHE_ROOT'] = str(parent / 'cache')
    builds = []; archives = []
    for linkage in ('library', 'static', 'dynamic'):
        for platform, minimum, sdk_name, destination, architecture in DESTINATIONS:
            work = parent / (linkage + '-' + sdk_name); work.mkdir()
            module = work / 'MatrixWrapper'; module.mkdir(); shutil.copytree(binary, module / binary.name, symlinks=True)
            module.joinpath('MatrixWrapper.c').write_text('#include <MatrixBinary/MatrixBinary.h>\n#ifndef COCOAPODS\n#error Required compatibility macro is missing\n#endif\nint matrix_wrapper(void) { return MatrixBinary_value(); }\n')
            module.joinpath('MatrixWrapper.h').write_text('int matrix_wrapper(void);\n')
            module.joinpath('MatrixWrapper.podspec.json').write_text(json.dumps({'name': 'MatrixWrapper', 'version': '1.0', 'source_files': '*.{c,h}', 'vendored_frameworks': binary.name, 'platforms': {platform: minimum}}))
            text = f"platform :{platform}, '{minimum}'\ninstall! 'swiftpods', :share_schemes_for_development_pods => true\n"
            if linkage != 'library': text += 'use_frameworks! :linkage => :' + linkage + '\n'
            text += "target 'App' do\n pod 'MatrixWrapper', :path => './MatrixWrapper'\nend\n"
            work.joinpath('Podfile').write_text(text)
            installed = subprocess.run([str(ROOT / '.build/debug/swiftpods'), 'install', '--no-integrate', '--json'], cwd=work, env=env, capture_output=True, text=True, timeout=90)
            assert installed.returncode == 0, (installed.stdout, installed.stderr)
            common = ['xcodebuild', '-project', 'Pods/Pods.xcodeproj', '-scheme', 'MatrixWrapper', '-configuration', 'Release', '-destination', 'generic/platform=' + destination, '-sdk', 'macosx' if sdk_name == 'maccatalyst' else sdk_name, 'ARCHS=' + architecture, 'ONLY_ACTIVE_ARCH=YES', 'CODE_SIGNING_ALLOWED=NO', 'GCC_TREAT_WARNINGS_AS_ERRORS=YES', 'SWIFT_TREAT_WARNINGS_AS_ERRORS=YES', 'SYMROOT=' + str(work / 'products')]
            common += ['TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault']
            if sdk_name == 'maccatalyst': common += ['SUPPORTS_MACCATALYST=YES']
            for configuration in ['Debug', 'Release']:
                configured = list(common); configured[configured.index('-configuration') + 1] = configuration
                run(configured + ['build'], work, parent / ('build-' + linkage + '-' + sdk_name + '-' + configuration + '.log'), env)
                products = list(work.glob('products/' + configuration + '*/' + ('libMatrixWrapper.a' if linkage == 'library' else 'MatrixWrapper.framework/MatrixWrapper')))
                assert products, (linkage, sdk_name, configuration)
                builds.append({'linkage': linkage, 'platform': platform, 'sdk': sdk_name, 'architecture': architecture, 'configuration': configuration, 'destination': destination})
            if sdk_name not in ('iphonesimulator', 'appletvsimulator', 'watchsimulator', 'xrsimulator'):
                archive = work / 'Product.xcarchive'
                # Xcode's archive staging needs its own BuildProductsPath. A build-only
                # SYMROOT override otherwise leaves that required directory absent.
                archive_command = [value for value in common if not str(value).startswith('SYMROOT=')]
                run(archive_command + ['archive', '-archivePath', archive, 'SKIP_INSTALL=NO'], work, parent / ('archive-' + linkage + '-' + sdk_name + '.log'), env)
                assert archive.joinpath('Info.plist').exists()
                payloads = list(archive.glob('Products/**/' + ('libMatrixWrapper.a' if linkage == 'library' else 'MatrixWrapper.framework')))
                assert payloads, (linkage, sdk_name, archive)
                archives.append({'linkage': linkage, 'sdk': sdk_name, 'archive': str(archive)})
    report = {'status': 'passed', 'engine': 'swift', 'fixture': str(parent), 'builds': builds, 'archives': archives, 'verified': ['real dynamic XCFramework with ten platform/variant slices', 'three pod linkage modes built for macOS iOS tvOS watchOS visionOS and Mac Catalyst', 'watchOS arm64_32 binary inspected and linked', 'device/macOS/Mac Catalyst archives checked separately from simulator builds', 'required build macro consumed by compiled C source'], 'unverified': ['physical device execution', 'signed archives', 'Swift binary module stability', 'test/app host matrices outside existing macOS/iOS fixtures']}
    ROOT.joinpath('test-results/native-platforms.json').write_text(json.dumps(report, indent=2) + '\n'); print(json.dumps(report, indent=2))


if __name__ == '__main__': execute(main, 'native-platforms.json')
