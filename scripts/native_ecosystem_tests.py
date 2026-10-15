#!/usr/bin/env python3
"""Build regenerated CMake projects and preserve existing Swift package wiring."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import shlex
import subprocess
import tempfile
from batch_fixture import user_project
from bootstrap import ROOT, environment
from native_integration import serialize
from reference_compare import reference_environment
from reporting import execute


def read(path): return json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))


def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--gem-home', type=Path); args = parser.parse_args()
    parent = Path(tempfile.mkdtemp(prefix='native-ecosystem-', dir=ROOT / '.build')); print('Ecosystem fixtures:', parent, flush=True)
    env = environment(); env['SWIFTPODS_CACHE_ROOT'] = str(parent / 'cache')
    binary = ROOT / '.build/debug/swiftpods'
    def cli(work, *arguments, success=True):
        result = subprocess.run([str(binary), *arguments, '--json'], cwd=work, env=env, capture_output=True, text=True, timeout=90)
        assert (result.returncode == 0) == success, (arguments, result.stdout, result.stderr)
        return json.loads(result.stdout)
    def run(command, work, log):
        if command[0] == 'xcodebuild' and '-scheme' in command and '-destination' not in command:
            command += ['-destination', 'platform=macOS,arch=arm64']
        result = subprocess.run(list(map(str, command)), cwd=work, env=env, capture_output=True, text=True, timeout=180)
        log.write_text(result.stdout + result.stderr)
        assert result.returncode == 0 and ' warning:' not in result.stdout + result.stderr, log
    def module(work, name='SimpleKit'):
        root = work / 'Modules' / name; root.mkdir(parents=True)
        sources = root / 'Sources'; sources.mkdir()
        sources.joinpath(name + '.h').write_text('#ifdef __cplusplus\nextern "C" {\n#endif\nint simple_value(void);\n#ifdef __cplusplus\n}\n#endif\n')
        sources.joinpath(name + '.c').write_text('int simple_value(void) { return 17; }\n')
        root.joinpath(name + '.podspec.json').write_text(json.dumps({'name': name, 'version': '1.0', 'summary': 'Ecosystem fixture.', 'homepage': 'https://swiftpods.org', 'authors': 'SwiftPods', 'license': 'MIT', 'source': {'git': 'https://example.invalid/simple.git', 'tag': '1.0'}, 'platforms': {'osx': '13.0'}, 'source_files': 'Sources'}))
        return root
    def manifest(work, target='Demo', project=None):
        text = "platform :osx, '13.0'\n"
        if project: text += "project '" + str(project) + "'\n"
        text += "target '" + target + "' do\n pod 'SimpleKit', :path => './Modules/SimpleKit'\nend\n"
        work.joinpath('Podfile').write_text(text)
    def build_pods(work, index):
        run(['xcodebuild', '-project', 'Pods/Pods.xcodeproj', '-target', 'SimpleKit', '-configuration', 'Debug', '-sdk', 'macosx', 'build', 'CODE_SIGNING_ALLOWED=NO', 'SYMROOT=' + str(work / 'products')], work, parent / ('pods-' + index + '.log'))
    initialized = parent / 'initialized'; initialized.mkdir(); user_project(initialized, 'Demo')
    cli(initialized, 'init')
    assert "platform :osx, '13.0'" in initialized.joinpath('Podfile').read_text()
    result = subprocess.run([str(binary), 'install', '--silent'], cwd=initialized, env=env, capture_output=True, text=True, timeout=90)
    assert result.returncode == 0 and result.stdout == '', (result.stdout, result.stderr)
    result = subprocess.run([str(binary), 'install', '--verbose'], cwd=initialized, env=env, capture_output=True, text=True, timeout=90)
    assert result.returncode == 0 and 'installation' in result.stdout and 'engine' in result.stdout, (result.stdout, result.stderr)
    result = subprocess.run([str(binary), 'outdated'], cwd=initialized, env=env, capture_output=True, text=True, timeout=90)
    assert result.returncode == 0 and 'up to date' in result.stdout, (result.stdout, result.stderr)
    skipped = parent / 'skipped'; skipped.mkdir(); user_project(skipped, 'Demo')
    original = skipped.joinpath('Demo.xcodeproj/project.pbxproj').read_bytes()
    declarations = "platform :osx, '13.0'\ninstall! 'swiftpods', :skip_pods_project_generation => true\ntarget 'Demo'\n"
    declarations += "pre_install { |installer| File.write('trace', 'pre,'); raise 'No user project' unless installer.aggregate_targets.first.user_project }\n"
    declarations += "pre_integrate { File.open('trace', 'a') { |f| f.write('integrate,') } }\n"
    declarations += "post_install { |installer| File.open('trace', 'a') { |f| f.write('post') }; raise 'Unexpected generated project' if installer.pods_project }\n"
    declarations += "post_integrate { File.open('trace', 'a') { |f| f.write('unexpected') } }\n"
    skipped.joinpath('Podfile').write_text(declarations)
    cli(skipped, 'install')
    assert skipped.joinpath('trace').read_text() == 'pre,post'
    assert not skipped.joinpath('Pods/Pods.xcodeproj').exists() and skipped.joinpath('Demo.xcodeproj/project.pbxproj').read_bytes() == original
    skipped.joinpath('Podfile').write_text("platform :osx, '13.0'\ninstall! 'swiftpods', :integrate_targets => false\ntarget 'Demo'\npre_integrate { File.write('integrate-marker', 'called') }\n")
    cli(skipped, 'install')
    assert skipped.joinpath('integrate-marker').read_text() == 'called' and skipped.joinpath('Pods/Pods.xcodeproj').exists()
    bridge = parent / 'bridge'; bridge.mkdir(); user_project(bridge, 'Demo'); module(bridge)
    # Both engines invoke the same Apple tool with the same external Ruby
    # environment. Reference-only Bundler state must not leak into that tool.
    tools = parent / 'tools'; tools.mkdir()
    bridge_tool = tools / 'gen_bridge_metadata'
    bridge_tool.write_text("#!/bin/sh\nprintf '%s\\n' \"$@\" >> " + shlex.quote(str(parent / 'metadata-tool.log')) + "\nexec /usr/bin/env -u RUBYOPT -u GEM_HOME -u GEM_PATH -u BUNDLE_GEMFILE -u BUNDLE_BIN_PATH -u BUNDLER_VERSION /usr/bin/gen_bridge_metadata \"$@\"\n")
    bridge_tool.chmod(0o755)
    env['PATH'] = str(tools) + ':' + env.get('PATH', '')
    bridge_manifest = "platform :osx, '13.0'\nuse_frameworks!\ngenerate_bridge_support!\ntarget 'Demo' do\n pod 'SimpleKit', :path => './Modules/SimpleKit'\nend\n"
    bridge.joinpath('Podfile').write_text(bridge_manifest); cli(bridge, 'install')
    bridge_metadata = bridge.joinpath('Pods/Target Support Files/Pods-Demo/Pods-Demo.bridgesupport').read_bytes()
    assert b'<signatures' in bridge_metadata
    # CMake is the owner of its project; a regeneration removes integration.
    work = parent / 'cmake'; work.mkdir(); module(work)
    work.joinpath('main.c').write_text('#include <SimpleKit/SimpleKit.h>\n#include <stdio.h>\nint main(void) { printf("cmake=%d\\n", simple_value()); return 0; }\n')
    work.joinpath('CMakeLists.txt').write_text('cmake_minimum_required(VERSION 3.25)\nproject(CMakeDemo C)\nset(CMAKE_OSX_DEPLOYMENT_TARGET 13.0)\nadd_executable(Demo MACOSX_BUNDLE main.c)\nset_target_properties(Demo PROPERTIES XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO XCODE_GENERATE_SCHEME YES)\n')
    cmake = shutil.which('cmake'); assert cmake, 'CMake is required for this acceptance fixture'
    generated = work / 'Generated'; manifest(work, project='Generated/CMakeDemo.xcodeproj')
    for iteration in range(2):
        run([cmake, '-S', work, '-B', generated, '-G', 'Xcode'], work, parent / ('cmake-generate-' + str(iteration) + '.log'))
        cli(work, 'install')
        objects = read(generated / 'CMakeDemo.xcodeproj/project.pbxproj')['objects']
        checks = [obj for obj in objects.values() if obj.get('name') == '[CP] Check Pods Manifest.lock']
        assert len(checks) == 1
        build_pods(work, 'cmake-' + str(iteration))
        run(['xcodebuild', '-project', generated / 'CMakeDemo.xcodeproj', '-scheme', 'Demo', '-configuration', 'Debug', '-sdk', 'macosx', 'build', 'CODE_SIGNING_ALLOWED=NO', 'SYMROOT=' + str(work / 'products')], work, parent / ('cmake-build-' + str(iteration) + '.log'))
        executable = generated / 'Debug/Demo.app/Contents/MacOS/Demo'; assert executable.exists()
        assert subprocess.check_output([str(executable)], text=True).strip() == 'cmake=17'
    # A real existing local package is built alongside a pod. Neither its PBX
    # product dependency nor its lockfile is owned by SwiftPods.
    work = parent / 'packages'; work.mkdir(); module(work); user_project(work, 'Demo')
    package = work / 'ExistingPackage'; include = package / 'Sources/ExistingPackage/include'; include.mkdir(parents=True)
    package.joinpath('Package.swift').write_text('// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: "ExistingPackage", products: [.library(name: "ExistingPackage", targets: ["ExistingPackage"])], targets: [.target(name: "ExistingPackage")])\n')
    include.joinpath('ExistingPackage.h').write_text('#ifdef __cplusplus\nextern "C" {\n#endif\nint package_value(void);\n#ifdef __cplusplus\n}\n#endif\n')
    package.joinpath('Sources/ExistingPackage/value.c').write_text('int package_value(void) { return 23; }\n')
    sources = work / 'Sources'; sources.mkdir()
    sources.joinpath('main.mm').write_text('#include <SimpleKit/SimpleKit.h>\n#include <ExistingPackage.h>\n#include <stdio.h>\nint main(void) { printf("packages=%d\\n", simple_value() + package_value()); return 0; }\n')
    project = work / 'Demo.xcodeproj/project.pbxproj'; graph = read(project); objects = graph['objects']
    def identifier(name): return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
    reference, product, build = map(identifier, ('existing-package', 'existing-product', 'existing-build'))
    objects[reference] = {'isa': 'XCLocalSwiftPackageReference', 'relativePath': 'ExistingPackage'}
    objects[product] = {'isa': 'XCSwiftPackageProductDependency', 'package': reference, 'productName': 'ExistingPackage'}
    objects[build] = {'isa': 'PBXBuildFile', 'productRef': product}
    objects[graph['rootObject']]['packageReferences'] = [reference]
    target = next(obj for obj in objects.values() if obj['isa'] == 'PBXNativeTarget'); target['packageProductDependencies'] = [product]
    phase = next(objects[value] for value in target['buildPhases'] if objects[value]['isa'] == 'PBXFrameworksBuildPhase'); phase['files'].append(build)
    project.write_text('// !$*UTF8*$!\n' + serialize(graph))
    resolved = work / 'Demo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'; resolved.parent.mkdir(parents=True)
    resolved.write_text('{"pins":[],"version":3}\n'); lock = resolved.read_bytes()
    manifest(work)
    for operation in ('install', 'deintegrate', 'install'):
        cli(work, operation)
        current = read(project)['objects']
        assert all(current[key] == objects[key] for key in (reference, product, build))
        assert resolved.read_bytes() == lock
    build_pods(work, 'packages')
    run(['xcodebuild', '-project', 'Demo.xcodeproj', '-scheme', 'Demo', '-configuration', 'Debug', '-sdk', 'macosx', 'build', 'CODE_SIGNING_ALLOWED=NO', 'SYMROOT=' + str(work / 'products')], work, parent / 'packages-build.log')
    assert subprocess.check_output([str(work / 'products/Debug/Demo.app/Contents/MacOS/Demo')], text=True).strip() == 'packages=40'
    module(work, 'ExistingPackage')
    work.joinpath('Podfile').write_text(work.joinpath('Podfile').read_text().replace("end\n", " pod 'ExistingPackage', :path => './Modules/ExistingPackage'\nend\n"))
    failed = cli(work, 'install', success=False)
    assert any(event.get('code') == 'SP-DUPLICATE-SDK' for event in failed['events'])
    verified = ['CMake Xcode generation, integration, regeneration and two real application runs', 'directory source pattern expansion in a real build', 'existing local Swift package compiled and linked alongside a pod', 'existing package PBX objects and Package.resolved byte preservation across install/deintegrate/reinstall', 'known existing package/pod duplicate rejected without deleting the package']
    verified += ['init infers the real consumer platform; silent and verbose output are exercised', 'skipped project generation preserves user project bytes and runs the correct hooks', 'pre_integrate executes when install options disable consumer integration', 'BridgeSupport generated by the Apple metadata tool from aggregate declarations']
    differences = []
    limitations = ['arbitrary CMake generators and projects', 'unknown SDK identities inside packages']
    if args.gem_home:
        work = parent / 'backward'; work.mkdir(); module(work); user_project(work, 'Demo'); work.joinpath('Sources').mkdir()
        work.joinpath('Sources/main.mm').write_text('#include <SimpleKit/SimpleKit.h>\nint main(void) { return simple_value() == 17 ? 0 : 1; }\n'); manifest(work)
        podfile = work.joinpath('Podfile').read_bytes()
        cli(work, 'install'); cli(work, 'deintegrate')
        ruby, reference_env = reference_environment(args.gem_home, parent)
        code = "require 'bundler/setup'; require 'cocoapods'; abort('Wrong reference') unless Pod::VERSION == '1.17.0'; Pod::Command.run(ARGV)"
        result = subprocess.run([ruby, '-e', code, '--', 'install', '--no-ansi'], cwd=work, env=reference_env, capture_output=True, text=True, timeout=120)
        parent.joinpath('backward-install.log').write_text(result.stdout + result.stderr); assert result.returncode == 0, parent / 'backward-install.log'
        assert work.joinpath('Podfile').read_bytes() == podfile
        build_pods(work, 'backward')
        run(['xcodebuild', '-workspace', 'Demo.xcworkspace', '-scheme', 'Demo', '-configuration', 'Debug', '-sdk', 'macosx', 'build', 'CODE_SIGNING_ALLOWED=NO', 'SYMROOT=' + str(work / 'products')], work, parent / 'backward-build.log')
        subprocess.run([str(work / 'products/Debug/Demo.app/Contents/MacOS/Demo')], check=True)
        verified.append('unchanged pure Podfile returned to the upstream installer after explicit native deintegration, then built and ran')
        reference_lock = work.joinpath('Podfile.lock').read_bytes()
        for version in ('1.17.0', '1.16.2'):
            locked = reference_lock.replace(b'COCOAPODS: 1.17.0', b'COCOAPODS: ' + version.encode())
            work.joinpath('Podfile.lock').write_bytes(locked)
            if work.joinpath('Pods').exists(): shutil.rmtree(work / 'Pods')
            cli(work, 'install', '--deployment')
            assert work.joinpath('Podfile.lock').read_bytes() == locked
        work.joinpath('Podfile.lock').write_bytes(reference_lock)
        verified.append('1.16.2 and 1.17.0 upstream lockfiles install in deployment without Pods and remain byte-for-byte unchanged')
        cli(work, 'install')
        run(['xcodebuild', '-workspace', 'Demo.xcworkspace', '-scheme', 'Demo', '-configuration', 'Debug', '-sdk', 'macosx', 'build', 'CODE_SIGNING_ALLOWED=NO', 'SYMROOT=' + str(work / 'products')], work, parent / 'forward-build.log')
        subprocess.run([str(work / 'products/Debug/Demo.app/Contents/MacOS/Demo')], check=True)
        assert work.joinpath('Podfile').read_bytes() == podfile
        verified.append('existing upstream installation replaced directly by the native installer, then built and ran')
        reference_env['PATH'] = str(tools) + ':' + reference_env.get('PATH', '')
        comparison = parent / 'bridge-reference'; comparison.mkdir(); user_project(comparison, 'Demo'); module(comparison); comparison.joinpath('Podfile').write_text(bridge_manifest)
        result = subprocess.run([ruby, '-e', code, '--', 'install', '--no-ansi'], cwd=comparison, env=reference_env, capture_output=True, text=True, timeout=120)
        parent.joinpath('bridge-reference.log').write_text(result.stdout + result.stderr)
        assert result.returncode == 0, parent / 'bridge-reference.log'
        reference_metadata = comparison / 'Pods/Target Support Files/Pods-Demo/Pods-Demo.bridgesupport'
        if reference_metadata.is_file():
            assert reference_metadata.read_bytes() == bridge_metadata
        else:
            assert str(comparison / 'Pods/Pods-Demo-umbrella.h') in (parent / 'metadata-tool.log').read_text()
            differences.append({'feature': 'BridgeSupport', 'reference': 'installer invokes the Apple tool with a nonexistent Pods/Pods-Demo-umbrella.h path; no metadata produced', 'native': 'invokes the same tool with the generated aggregate header and produces metadata', 'parity': False})
            limitations.append('BridgeSupport output differs from the reference installer; its aggregate header path is invalid')
        verified.append('BridgeSupport installer outputs observed in the same Apple-tool environment; differences recorded explicitly')
        bridge_tool.write_text("#!/bin/sh\nprintf 'fixture metadata failure\\n' >&2\nexit 47\n")
        bridge_tool.chmod(0o755)
        for engine in ['native', 'reference']:
            failure = parent / ('bridge-failure-' + engine); failure.mkdir(); user_project(failure, 'Demo'); module(failure); failure.joinpath('Podfile').write_text(bridge_manifest)
            if engine == 'native': cli(failure, 'install')
            else:
                result = subprocess.run([ruby, '-e', code, '--', 'install', '--no-ansi'], cwd=failure, env=reference_env, capture_output=True, text=True, timeout=120)
                assert result.returncode == 0, (result.stdout, result.stderr)
            missing = failure / 'Pods/Target Support Files/Pods-Demo/Pods-Demo.bridgesupport'
            assert not missing.exists(), engine
            assert '.bridgesupport' in failure.joinpath('Pods/Pods.xcodeproj/project.pbxproj').read_text(), engine
        verified.append('BridgeSupport command failure preserves the same missing resource reference without fabricating a file')
    name = 'native-ecosystem-reference.json' if args.gem_home else 'native-ecosystem.json'
    report = {'status': 'passed', 'engine': 'swift', 'fixture': str(parent), 'verified': verified, 'differences': differences, 'unverified': limitations}
    ROOT.joinpath('test-results', name).write_text(json.dumps(report, indent=2) + '\n'); print(json.dumps(report, indent=2))


if __name__ == '__main__':
    import sys
    execute(main, 'native-ecosystem-reference.json' if '--gem-home' in sys.argv else 'native-ecosystem.json')
