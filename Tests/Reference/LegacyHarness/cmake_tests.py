#!/usr/bin/env python3
"""Generate with CMake, install pods, regenerate, reinstall and build/run."""
import json
from pathlib import Path
import platform
import shutil
import tempfile
from integration import ROOT, CLI, environment, run, snapshot


def main():
    cmake = shutil.which('cmake')
    if not cmake:
        raise RuntimeError('CMake is required for the CMake-generated-project acceptance fixture')
    directory = Path(tempfile.mkdtemp(prefix='cmake-', dir=ROOT / '.build'))
    project = directory / 'project'
    shutil.copytree(ROOT / 'Tests/Fixtures/MixedLanguages', project)
    shutil.copytree(ROOT / 'Tests/Fixtures/CMake', project / 'CMake')
    env = environment(directory / 'home')
    Path(env['HOME']).mkdir()
    podfile = (project / 'Podfile').read_text().replace("project 'Demo.xcodeproj'", "project 'generated/SwiftPodsCMake.xcodeproj'")
    podfile = podfile.replace("Demo.xcodeproj/project.pbxproj", "generated/SwiftPodsCMake.xcodeproj/project.pbxproj")
    (project / 'Podfile').write_text(podfile)
    arguments = [cmake, '-S', 'CMake', '-B', 'generated', '-G', 'Xcode', '-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0', '-DCMAKE_COMPILE_WARNING_AS_ERROR=ON']
    run(arguments, project, env, directory / 'generate.log', reject_warnings=True)
    original = (project / 'generated/SwiftPodsCMake.xcodeproj/project.pbxproj').read_bytes()
    run([CLI, 'install', '--no-ansi'], project, env, directory / 'install.log')
    installed = (project / 'generated/SwiftPodsCMake.xcodeproj/project.pbxproj').read_bytes()
    assert installed != original and b'[CP] Check Pods Manifest.lock' in installed
    assert b'CMAKE_FIXTURE=1' in installed
    # Force the generator to replace its project, as real CMake changes do.
    with (project / 'CMake/CMakeLists.txt').open('a') as file:
        file.write('\ntarget_compile_definitions(Demo PRIVATE CMAKE_REGENERATED=1)\n')
    run(arguments, project, env, directory / 'regenerate.log', reject_warnings=True)
    regenerated = (project / 'generated/SwiftPodsCMake.xcodeproj/project.pbxproj').read_bytes()
    assert b'CMAKE_REGENERATED=1' in regenerated
    assert b'[CP] Check Pods Manifest.lock' not in regenerated
    run([CLI, 'install', '--no-ansi'], project, env, directory / 'reinstall.log')
    reintegrated = (project / 'generated/SwiftPodsCMake.xcodeproj/project.pbxproj').read_bytes()
    assert b'CMAKE_REGENERATED=1' in reintegrated and b'[CP] Check Pods Manifest.lock' in reintegrated
    before = snapshot(project)
    run([CLI, 'install', '--deployment', '--no-ansi'], project, env, directory / 'noop.log')
    assert snapshot(project) == before
    derived = directory / 'derived'
    run(['xcodebuild', '-workspace', 'Demo.xcworkspace', '-scheme', 'Demo', '-configuration', 'Debug',
         '-toolchain', 'com.apple.dt.toolchain.XcodeDefault', '-destination', 'platform=macOS,arch=' + platform.machine(),
         '-derivedDataPath', derived, 'build'], project, env, directory / 'build.log', reject_warnings=True)
    _, output = run([derived / 'Build/Products/Debug/Demo.app/Contents/MacOS/Demo'], project, env, directory / 'run.log')
    assert output == 'mixed=15 resources=ok privacy=ok\n'
    result = {'schema_version': 1, 'status': 'passed', 'fixture': str(directory),
              'verified': ['cmake_xcode_generation', 'cxx17_objcpp_and_modules', 'cmake_flags_preserved',
                           'regeneration_reintegration', 'idempotent_reinstall', 'mixed_language_build_run']}
    (ROOT / 'test-results/cmake.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    from reporting import execute
    execute(main, 'cmake.json')
