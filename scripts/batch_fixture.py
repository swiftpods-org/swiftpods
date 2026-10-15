"""One source fixture combining target inheritance, configurations, ARC and resources."""
import hashlib
import json
import plistlib
import shutil
import subprocess
from bootstrap import ROOT
from native_integration import project, serialize
from vendor_fixture import run


def user_project(work, name, platform='osx'):
    path = work / (name + '.xcodeproj'); project(path, platform)
    data = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path / 'project.pbxproj')]))
    for item in data['objects'].values():
        if item['isa'] == 'PBXNativeTarget': item.update(name=name, productName=name)
        if item['isa'] == 'PBXFileReference' and item.get('path') == 'Demo.app': item['path'] = name + '.app'
        if item['isa'] == 'XCBuildConfiguration':
            settings = item['buildSettings']
            if settings.get('PRODUCT_NAME'):
                settings['ALWAYS_SEARCH_USER_PATHS'] = 'NO'
                settings['PRODUCT_NAME'] = name
                settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'org.swiftpods.batch.' + name
                settings['GCC_PREPROCESSOR_DEFINITIONS'] = ['$(inherited)']
                if name == 'Search': settings['GCC_PREPROCESSOR_DEFINITIONS'].append('BATCH_SEARCH_ONLY=1')
                elif name == 'Isolated': settings['GCC_PREPROCESSOR_DEFINITIONS'].append('BATCH_ISOLATED=1')
                elif platform == 'ios': settings['GCC_PREPROCESSOR_DEFINITIONS'].append('BATCH_MOBILE=1')
                elif item['name'] == 'Debug': settings['GCC_PREPROCESSOR_DEFINITIONS'].append('BATCH_DEBUG=1')
    for item in list(data['objects'].values()):
        if item['isa'] != 'XCConfigurationList': continue
        debug = next(value for value in item['buildConfigurations'] if data['objects'][value]['name'] == 'Debug')
        identifier = hashlib.sha256((debug + 'Staging').encode()).hexdigest()[:24].upper()
        data['objects'][identifier] = json.loads(json.dumps(data['objects'][debug]))
        data['objects'][identifier]['name'] = 'Staging'
        item['buildConfigurations'].append(identifier)
    identifiers = {identifier: hashlib.sha256((name + ':' + identifier).encode()).hexdigest()[:24].upper() for identifier in data['objects']}
    def scoped(value):
        if isinstance(value, str): return identifiers.get(value, value)
        if isinstance(value, list): return [scoped(item) for item in value]
        if isinstance(value, dict): return {identifiers.get(key, key): scoped(item) for key, item in value.items()}
        return value
    data = scoped(data)
    path.joinpath('project.pbxproj').write_text('// !$*UTF8*$!\n' + serialize(data))


def podfile(work, linkage='static', multiple=False, mobile=False):
    text = "platform :osx, '13.0'\nworkspace 'Batch'\n"
    if linkage: text += 'use_frameworks! :linkage => :' + linkage + '\n'
    if multiple: text += "install! 'cocoapods', :generate_multiple_pod_projects => true\n"
    text += '''abstract_target 'Shared' do
  pod 'BatchKit', :path => './Modules/BatchKit'
  target 'Demo' do
    project 'Demo.xcodeproj', 'Staging' => :debug
    pod 'DebugKit', :path => './Modules/DebugKit', :configurations => ['Debug', 'Staging']
    target 'Search' do
      project 'Search.xcodeproj', 'Staging' => :debug
      inherit! :search_paths
    end
  end
  target 'Isolated' do
    project 'Isolated.xcodeproj'
    inherit! :none
    pod 'DebugKit', :path => './Modules/DebugKit', :configurations => ['Debug', 'Staging', 'Release']
  end
end
'''
    if mobile:
        text += "target 'Mobile' do\n  platform :ios, '15.0'\n  project 'Mobile.xcodeproj'\n  pod 'BatchKit', :path => './Modules/BatchKit'\nend\n"
    text += '''pre_install do |installer|
  $batch_installer = installer
  raise 'Missing analyzed pod targets' unless installer.pod_targets.any? { |pod| pod.pod_name == 'BatchKit' }
end
post_install do |installer|
  raise 'Installer identity changed' unless installer.equal?($batch_installer)
  $batch_project = installer.pods_project
  targets = installer.generated_projects.flat_map { |project| project.targets.to_a }.select { |candidate| candidate.name.start_with?('BatchKit') }
  targets.each do |target|
    phase = target.new_shell_script_build_phase('Batch hook')
    phase.shell_script = 'set -eu; printf hook > "${SCRIPT_OUTPUT_FILE_0}"'
    phase.output_paths = ['$(DERIVED_FILE_DIR)/batch-hook.txt']
    phase.input_paths = []
  end
  installer.generated_projects.each(&:save)
  installer.pods_project.save
  raise 'Save did not persist the hook graph' unless Dir['Pods/**/*.xcodeproj/project.pbxproj'].any? { |path| File.read(path).include?('Batch hook') }
end
post_integrate do |installer|
  raise 'Project identity changed' unless installer.pods_project.equal?($batch_project)
  raise 'Lockfile written too early' if File.exist?('Podfile.lock') && !File.exist?('batch-first-install')
  File.write('batch-first-install', 'ok')
end
'''
    work.joinpath('Podfile').write_text(text)


def create(work, linkage='static', multiple=False, mobile=False):
    work.mkdir()
    module = work / 'Modules/BatchKit'
    source = module / 'Sources/Layer'; source.mkdir(parents=True)
    source.joinpath('BatchKit.h').write_text('#import <Foundation/Foundation.h>\n#ifdef __cplusplus\nextern \"C\" {\n#endif\nint batch_value(void);\n#ifdef __cplusplus\n}\n#endif\n@interface BatchProbe : NSObject\n+ (NSBundle *)bundle;\n@end\n')
    source.joinpath('Private.h').write_text('#define BATCH_PRIVATE 1\n')
    source.joinpath('Project.h').write_text('#define BATCH_PROJECT 1\n')
    source.joinpath('Arc.m').write_text('#import "BatchKit.h"\n#import "Private.h"\n#if !__has_feature(objc_arc)\n#error ARC is required for this file\n#endif\nint batch_arc(void) { return 6; }\n@implementation BatchProbe\n+ (NSBundle *)bundle { return [NSBundle bundleForClass:self]; }\n@end\n')
    nested = module / 'Sources/Deep/Layer/Nested'; nested.mkdir(parents=True)
    nested.joinpath('Manual.m').write_text('#import <Foundation/Foundation.h>\n#if __has_feature(objc_arc)\n#error ARC must be off for this file\n#endif\nint batch_manual(void) { NSObject *object = [[NSObject alloc] init]; [object release]; return 1; }\nint batch_arc(void);\nint batch_value(void) { return batch_arc() + batch_manual() + BATCH_PREFIX; }\n')
    resources = module / 'Resources/en.lproj'; resources.mkdir(parents=True)
    resources.joinpath('Localizable.strings').write_text('"batch" = "batch-direct";\n')
    module.joinpath('Resources/direct.txt').write_text('direct-resource\n')
    asset = module / 'Resources/Palette.xcassets/Brand.colorset'; asset.mkdir(parents=True)
    asset.joinpath('Contents.json').write_text(json.dumps({'colors': [{'idiom': 'universal', 'color': {'color-space': 'srgb', 'components': {'red': '0.1', 'green': '0.2', 'blue': '0.3', 'alpha': '1.0'}}}], 'info': {'version': 1, 'author': 'xcode'}}))
    asset.parent.joinpath('Contents.json').write_text('{"info":{"version":1,"author":"xcode"}}\n')
    module.joinpath('BatchKit.podspec').write_text('''Pod::Spec.new do |s|
  s.name = 'BatchKit'
  s.version = '1.0.0'
  s.summary = 'Batch integration fixture'
  s.homepage = 'https://swiftpods.org'
  s.license = 'MIT'
  s.author = 'SwiftPods'
  s.source = { :git => 'https://example.invalid/batch.git', :tag => '1.0.0' }
  s.osx.deployment_target = '13.0'
  s.ios.deployment_target = '15.0'
  s.source_files = 'Sources/**/Layer/**/*.{h,m}'
  s.public_header_files = 'Sources/Layer/BatchKit.h'
  s.private_header_files = 'Sources/Layer/Private.h'
  s.project_header_files = 'Sources/Layer/Project.h'
  s.requires_arc = ['Sources/**/Arc.m']
  s.prefix_header_contents = '#define BATCH_PREFIX 10'
  s.resources = 'Resources/**/*'
end
''')
    helper = work / 'Modules/DebugKit'; helper.mkdir()
    helper.joinpath('DebugKit.h').write_text('#ifdef __cplusplus\nextern \"C\" {\n#endif\nint debug_value(void);\n#ifdef __cplusplus\n}\n#endif\n')
    helper.joinpath('DebugKit.c').write_text('int debug_value(void) { return 3; }\n')
    helper.joinpath('DebugKit.podspec.json').write_text(json.dumps({'name': 'DebugKit', 'version': '1.0.0', 'summary': 'Configuration dependency', 'homepage': 'https://swiftpods.org', 'authors': ['SwiftPods'], 'license': 'MIT', 'source': {'git': 'https://example.invalid/debug.git', 'tag': '1.0.0'}, 'platforms': {'osx': '13.0'}, 'source_files': '*.{h,c}'}))
    work.joinpath('Sources').mkdir()
    work.joinpath('Sources/main.mm').write_text('''#import <Foundation/Foundation.h>
#if !defined(BATCH_ISOLATED)
#import <BatchKit/BatchKit.h>
#endif
#if defined(BATCH_DEBUG) || defined(BATCH_ISOLATED)
#import <DebugKit/DebugKit.h>
#endif
#include <stdio.h>
int main(void) { @autoreleasepool {
#if defined(BATCH_SEARCH_ONLY)
    printf("search-ok\\n");
#elif defined(BATCH_ISOLATED)
    printf("isolated=%d\\n", debug_value());
#elif defined(BATCH_MOBILE)
    return batch_value() == 17 ? 0 : 1;
#else
    NSBundle *bundle = [BatchProbe bundle];
    if ([bundle pathForResource:@"direct" ofType:@"txt"] == nil || ![[bundle localizedStringForKey:@"batch" value:nil table:nil] isEqualToString:@"batch-direct"]) return 1;
    int value = batch_value();
#if defined(BATCH_DEBUG)
    value += debug_value();
#endif
    printf("batch=%d resources=ok\\n", value);
#endif
    return 0;
} }
''')
    for name in ['Demo', 'Search', 'Isolated']: user_project(work, name)
    if mobile:
        user_project(work, 'Mobile', 'ios')
        shutil.copy2(ROOT / 'Tests/Fixtures/iOS/FixtureIntent.swift', work / 'Sources/FixtureIntent.swift')
        work.joinpath('Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': '$(EXECUTABLE_NAME)', 'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)', 'CFBundleName': 'Mobile', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0', 'UILaunchScreen': {}, 'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationPortraitUpsideDown', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight']}))
    podfile(work, linkage, multiple, mobile)


def build(work, parent, scheme='Demo', configuration='Debug', destination=None, expected=None):
    import platform
    destination = destination or 'platform=macOS,arch=' + platform.machine()
    swift = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
    from pathlib import Path
    arguments = ['xcodebuild', '-workspace', 'Batch.xcworkspace', '-scheme', scheme, '-configuration', configuration, '-destination', destination, '-derivedDataPath', parent / 'DerivedData', 'CODE_SIGNING_ALLOWED=NO', 'TOOLCHAIN_DIR=' + str(Path(swift).parents[2]), 'build']
    run(arguments, work, parent / (scheme + '-' + configuration + '-' + ('ios' if 'iOS' in destination else 'macos') + '.log'))
    if expected is not None:
        executable = parent / 'DerivedData/Build/Products' / configuration / (scheme + '.app/Contents/MacOS/' + scheme)
        actual = subprocess.check_output([str(executable)], text=True).strip()
        assert actual == expected, (actual, expected)
