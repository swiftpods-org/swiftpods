#!/usr/bin/env python3
"""Compile and run a Swift binary SDK after removing serialized Swift modules."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile
from bootstrap import ROOT, environment
from native_integration import project, serialize
from reporting import execute
from vendor_fixture import run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--producer-framework', type=Path)
    parser.add_argument('--producer-toolchain')
    args = parser.parse_args()
    parent = Path(tempfile.mkdtemp(prefix='native-swift-binary-', dir=ROOT / '.build'))
    print('Swift binary fixtures:', parent, flush=True)
    architecture = platform.machine()
    consumer_toolchain = subprocess.check_output(['swift', '--version'], text=True).strip()
    name = 'SwiftBinaryKit'
    framework = parent / (name + '.framework')
    if args.producer_framework:
        if not args.producer_toolchain: parser.error('--producer-framework requires --producer-toolchain')
        shutil.copytree(args.producer_framework, framework, symlinks=True)
        producer_toolchain = args.producer_toolchain
    else:
        version = framework / 'Versions/A'
        modules = version / 'Modules' / (name + '.swiftmodule'); modules.mkdir(parents=True)
        (version / 'Resources').mkdir()
        (framework / 'Versions/Current').symlink_to('A')
        for entry in ['Modules', 'Resources', name]: (framework / entry).symlink_to('Versions/Current/' + entry)
        source = parent / 'SDK.swift'; source.write_text('public func swiftBinaryValue() -> Int32 { return 29 }\n')
        sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
        interface = modules / (architecture + '-apple-macos.swiftinterface')
        command = ['xcrun', 'swiftc', '-emit-library', '-emit-module', '-enable-library-evolution', '-warnings-as-errors', '-swift-version', '5', '-module-name', name, '-target', architecture + '-apple-macosx13.0', '-sdk', sdk, '-emit-module-path', modules / (architecture + '-apple-macos.swiftmodule'), '-emit-module-interface-path', interface, '-Xlinker', '-install_name', '-Xlinker', '@rpath/' + name + '.framework/Versions/A/' + name, source, '-o', version / name]
        run(command, parent, parent / 'producer.log')
        (version / 'Resources/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': name, 'CFBundleIdentifier': 'org.swiftpods.binary-fixture', 'CFBundleName': name, 'CFBundlePackageType': 'FMWK', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0', 'CFBundleSupportedPlatforms': ['MacOSX'], 'LSMinimumSystemVersion': '13.0'}))
        producer_toolchain = consumer_toolchain
    for file in list(framework.rglob('*')):
        if file.is_file() and (file.suffix == '.swiftmodule' or file.name.endswith('.private.swiftinterface')): file.unlink()
    interfaces = list(framework.rglob('*.swiftinterface'))
    assert interfaces and not any(file.is_file() for file in framework.rglob('*.swiftmodule'))
    env = environment(); env['SWIFTPODS_CACHE_ROOT'] = str(parent / 'cache')
    builds, executions = [], []
    for linkage in ['library', 'static', 'dynamic']:
        work = parent / linkage; work.mkdir(); (work / 'Sources').mkdir()
        (work / 'Sources/main.swift').write_text('import SwiftBinaryKit\nimport AppIntents\nstruct BinaryValueIntent: AppIntent {\n static var title: LocalizedStringResource = "Binary value"\n func perform() async throws -> some IntentResult & ReturnsValue<Int> { .result(value: Int(swiftBinaryValue())) }\n}\nprint(swiftBinaryValue())\n')
        project(work / 'Demo.xcodeproj')
        path = work / 'Demo.xcodeproj/project.pbxproj'
        graph = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))
        for value in graph['objects'].values():
            if value.get('path') == 'Sources/main.mm': value.update(path='Sources/main.swift', lastKnownFileType='sourcecode.swift')
        path.write_text('// !$*UTF8*$!\n' + serialize(graph))
        module = work / 'SwiftBinaryWrapper'; module.mkdir(); shutil.copytree(framework, module / framework.name, symlinks=True)
        (module / 'SwiftBinaryWrapper.podspec.json').write_text(json.dumps({'name': 'SwiftBinaryWrapper', 'version': '1.0', 'vendored_frameworks': framework.name, 'platforms': {'osx': '13.0'}}))
        text = "platform :osx, '13.0'\n"
        if linkage != 'library': text += 'use_frameworks! :linkage => :' + linkage + '\n'
        (work / 'Podfile').write_text(text + "target 'Demo' do\n pod 'SwiftBinaryWrapper', :path => './SwiftBinaryWrapper'\nend\n")
        install = subprocess.run([str(ROOT / '.build/debug/swiftpods'), 'install', '--json'], cwd=work, env=env, capture_output=True, text=True, timeout=90)
        assert install.returncode == 0, (install.stdout, install.stderr)
        for configuration in ['Debug', 'Release']:
            run(['xcodebuild', '-workspace', 'Demo.xcworkspace', '-scheme', 'Demo', '-configuration', configuration, '-destination', 'platform=macOS,arch=' + architecture, '-sdk', 'macosx', 'build', 'CODE_SIGNING_ALLOWED=NO', 'GCC_TREAT_WARNINGS_AS_ERRORS=YES', 'SWIFT_TREAT_WARNINGS_AS_ERRORS=YES', 'TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault', 'SYMROOT=' + str(work / 'products')], work, parent / (linkage + '-' + configuration + '.log'), env)
            app = work / 'products' / configuration / 'Demo.app'
            embedded = app / 'Contents/Frameworks' / framework.name / name
            assert embedded.is_file()
            def identity(path):
                uuid = subprocess.check_output(['xcrun', 'dwarfdump', '--uuid', str(path)], text=True).split()[:3]
                symbols = subprocess.check_output(['xcrun', 'nm', '-gU', str(path)], text=True).splitlines()
                return uuid, sorted(line.split()[-1] for line in symbols if line.strip())
            assert identity(embedded) == identity(framework / name)
            output = subprocess.check_output([str(app / 'Contents/MacOS/Demo')], text=True).strip()
            assert output == '29', output
            builds.append({'linkage': linkage, 'configuration': configuration, 'architecture': architecture})
            executions.append({'linkage': linkage, 'configuration': configuration, 'output': output})
    cross = producer_toolchain != consumer_toolchain
    report = {'status': 'passed', 'engine': 'swift', 'fixture': str(parent), 'producer_toolchain': producer_toolchain, 'consumer_toolchain': consumer_toolchain, 'cross_toolchain': cross, 'builds': builds, 'executions': executions, 'verified': ['real dynamic Swift framework with library evolution enabled', 'serialized swiftmodule and private interfaces removed before consumption', 'public swiftinterface consumed by an actual Swift application', 'binary SDK linked and embedded across three pod linkage modes', 'Debug/Release applications execute and return the SDK value'], 'unverified': [] if cross else ['cross-compiler module stability; producer and consumer use the same toolchain']}
    (ROOT / 'test-results/native-swift-binary.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__': execute(main, 'native-swift-binary.json')
