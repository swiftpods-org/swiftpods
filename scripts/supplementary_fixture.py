"""Local source/test/app specs with distinct scoped dependencies and resources."""
import json
import subprocess
from native_integration import project
from script_phase_fixture import ruby, ruby_phase
from vendor_fixture import run

RESULT_HOOK = r'''
post_install do |installer|
  results = installer.target_installation_results
  observations = results.pod_target_installation_results.sort.to_h do |name, result|
    raise 'Installation result identity changed' unless result.equal?(installer.target_installation_results.pod_target_installation_results[name])
    result.non_library_specs_by_native_target.each_key do |target|
      target.build_configurations.each { |config| config.build_settings['SWIFTPODS_INSTALLATION_RESULT_MARKER'] = 'retained' }
    end
    [name, {
      'specs' => result.target.specs.map(&:name).sort,
      'native' => result.native_target&.name,
      'by_spec' => result.target.specs.to_h { |spec| [spec.name, result.native_target_for_spec(spec)&.name] },
      'bundles' => result.resource_bundle_targets.map(&:name).sort,
      'tests' => result.test_specs_by_native_target.to_h { |target, spec| [spec.name, target.name] },
      'apps' => result.app_specs_by_native_target.to_h { |target, spec| [spec.name, target.name] },
      'test_bundles' => result.test_resource_bundle_targets.transform_values { |targets| targets.map(&:name).sort },
      'app_bundles' => result.app_resource_bundle_targets.transform_values { |targets| targets.map(&:name).sort }
    }]
  end
  observations['aggregates'] = results.aggregate_target_installation_results.transform_values { |result| result.native_target.name }
  File.write('installation-results.json', JSON.pretty_generate(observations))
end
'''


def declarative(work):
    """Use the installed spec snapshot and JSON manifest without executing Ruby."""
    snapshot = work / 'Pods/Local Podspecs/SpecKit.podspec.json'
    work.joinpath('Modules/SpecKit/SpecKit.podspec.json').write_bytes(snapshot.read_bytes())
    manifest = {'schema_version': 1, 'platform': {'name': 'osx', 'deployment_target': '13.0'},
                'project': 'Demo.xcodeproj', 'sources': [(work / 'Specs').as_uri()], 'frameworks': 'static',
                'targets': [{'name': 'Demo', 'pods': [{'name': 'SpecKit', 'path': './Modules/SpecKit',
                                                     'testspecs': ['Tests'], 'appspecs': ['Example']}]}]}
    work.joinpath('Podfile.json').write_text(json.dumps(manifest, indent=2) + '\n')


def podfile(work, linkage='static', selections=True):
    options = ", :testspecs => ['Tests'], :appspecs => ['Example']" if selections else ''
    text = "platform :osx, '13.0'\nsource '" + (work / 'Specs').as_uri() + "'\nproject 'Demo.xcodeproj'\n"
    if linkage: text += 'use_frameworks! :linkage => :' + linkage + '\n'
    work.joinpath('Podfile').write_text(text + "target 'Demo' do\n  pod 'SpecKit', :path => './Modules/SpecKit'" + options + '\nend\n')


def create(work, linkage='static'):
    work.mkdir()
    module = work / 'Modules/SpecKit'; module.mkdir(parents=True)
    for name, function, value in [('TestHelper', 'testhelper_value', 8), ('AppHelper', 'apphelper_value', 9)]:
        source = work.parent / (work.name + '-source-' + name); source.mkdir()
        source.joinpath(name + '.h').write_text('#ifdef __cplusplus\nextern "C" {\n#endif\nint ' + function + '(void);\n#ifdef __cplusplus\n}\n#endif\n')
        source.joinpath(name + '.c').write_text('int ' + function + '(void) { return ' + str(value) + '; }\n')
        run(['git', 'init', '-b', 'main', source], work, work.parent / (work.name + name + '-init.log'))
        run(['git', '-C', source, 'add', '.'], work, work.parent / (work.name + name + '-add.log'))
        run(['git', '-C', source, '-c', 'user.name=SwiftPods Fixture', '-c', 'user.email=fixture@swiftpods.org', '-c', 'commit.gpgsign=false', 'commit', '-m', 'Fixture'], work, work.parent / (work.name + name + '-commit.log'))
        commit = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
        catalog = work / 'Specs' / name / '1.0'; catalog.mkdir(parents=True)
        catalog.joinpath(name + '.podspec.json').write_text(json.dumps({'name': name, 'version': '1.0', 'summary': name, 'homepage': 'https://swiftpods.org', 'license': 'MIT', 'author': 'SwiftPods', 'source': {'git': source.as_uri(), 'commit': commit}, 'source_files': '*.{h,c}', 'platforms': {'osx': '13.0'}}))
    for command, label in [(['git', 'init', '-b', 'main', work / 'Specs'], 'init'), (['git', '-C', work / 'Specs', 'add', '.'], 'add'), (['git', '-C', work / 'Specs', '-c', 'user.name=SwiftPods Fixture', '-c', 'user.email=fixture@swiftpods.org', '-c', 'commit.gpgsign=false', 'commit', '-m', 'Specs fixture'], 'commit')]:
        run(command, work, work.parent / (work.name + '-catalog-' + label + '.log'))
    module.joinpath('Sources').mkdir()
    module.joinpath('Sources/SpecKit.h').write_text('#ifdef __cplusplus\nextern "C" {\n#endif\nint speckit_value(void);\n#ifdef __cplusplus\n}\n#endif\n')
    module.joinpath('Sources/SpecKit.m').write_text('#import "SpecKit.h"\n#ifdef SWIFTPODS_TEST_ONLY\n#error Test configuration leaked into library\n#endif\nint speckit_value(void) { return 7; }\n')
    module.joinpath('Tests').mkdir()
    module.joinpath('Tests/testOnly.txt').write_text('test-resource')
    module.joinpath('Tests/Bundled.txt').write_text('test-packed-resource')
    module.joinpath('Tests/SpecKitTests.m').write_text('''#import <XCTest/XCTest.h>
#import <SpecKit/SpecKit.h>
#import <TestHelper/TestHelper.h>
#ifndef SWIFTPODS_TEST_ONLY
#error Missing test-specific configuration
#endif
@interface SpecKitTests : XCTestCase @end
@implementation SpecKitTests
- (void)testScopedDependenciesAndResources {
    XCTAssertEqual(speckit_value() + testhelper_value(), 15);
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    XCTAssertEqualObjects(bundle.infoDictionary[@"OwnMarker"], @"test");
    XCTAssertNil(bundle.infoDictionary[@"ParentMarker"]);
    XCTAssertNotNil([bundle pathForResource:@"testOnly" ofType:@"txt"]);
    XCTAssertNil([bundle pathForResource:@"appOnly" ofType:@"txt"]);
    XCTAssertNotNil([bundle pathForResource:@"SpecTestResources" ofType:@"bundle"]);
    XCTAssertNil([bundle pathForResource:@"SpecAppResources" ofType:@"bundle"]);
    XCTAssertEqualObjects([NSProcessInfo processInfo].environment[@"SWIFTPODS_TEST_VALUE"], @"expected");
}
@end
''')
    module.joinpath('Example').mkdir()
    module.joinpath('Example/appOnly.txt').write_text('app-resource')
    module.joinpath('Example/Bundled.txt').write_text('app-packed-resource')
    module.joinpath('Example/main.m').write_text('''#import <Foundation/Foundation.h>
#import <SpecKit/SpecKit.h>
#import <AppHelper/AppHelper.h>
#include <stdio.h>
int main(void) { @autoreleasepool {
    NSBundle *bundle = [NSBundle mainBundle];
    if (![bundle.infoDictionary[@"OwnMarker"] isEqual:@"app"] || [bundle pathForResource:@"testOnly" ofType:@"txt"] != nil || [bundle pathForResource:@"appOnly" ofType:@"txt"] == nil || [bundle pathForResource:@"SpecAppResources" ofType:@"bundle"] == nil || [bundle pathForResource:@"SpecTestResources" ofType:@"bundle"] != nil) return 1;
    printf("app-value=%d resources=ok\\n", speckit_value() + apphelper_value());
    return 0;
} }
''')
    module.joinpath('SpecKit.podspec').write_text('''Pod::Spec.new do |s|
  s.name = 'SpecKit'
  s.version = '1.0.0'
  s.summary = 'Native supplementary targets fixture'
  s.homepage = 'https://swiftpods.org'
  s.license = 'MIT'
  s.author = 'SwiftPods'
  s.source = { :git => 'https://example.invalid/spec.git', :tag => '1.0.0' }
  s.osx.deployment_target = '13.0'
  s.source_files = 'Sources/*.{h,m}'
  s.info_plist = { 'ParentMarker' => 'parent' }
  s.pod_target_xcconfig = { 'PARENT_CONFIG_FLAG' => 'present' }
  s.test_spec do |t|
    t.osx.deployment_target = '14.0'
    t.source_files = 'Tests/*.m'
    t.resources = 'Tests/testOnly.txt'
    t.resource_bundles = { 'SpecTestResources' => ['Tests/Bundled.txt'] }
    t.dependency 'TestHelper'
    t.info_plist = { 'OwnMarker' => 'test' }
    t.pod_target_xcconfig = { 'GCC_PREPROCESSOR_DEFINITIONS' => ['$(inherited)', 'SWIFTPODS_TEST_ONLY=1'] }
    t.scheme = { :environment_variables => { 'SWIFTPODS_TEST_VALUE' => 'expected' }, :code_coverage => true }
  end
  s.test_spec 'UnselectedUI' do |t|
    t.test_type = :ui
    t.source_files = 'Missing/*'
  end
  s.app_spec 'Example' do |a|
    a.source_files = 'Example/*.m'
    a.resources = 'Example/appOnly.txt'
    a.resource_bundles = { 'SpecAppResources' => ['Example/Bundled.txt'] }
    a.info_plist = { 'OwnMarker' => 'app' }
    a.dependency 'AppHelper'
  end
end
''')
    work.joinpath('Sources').mkdir()
    work.joinpath('Sources/main.mm').write_text('#include <stdio.h>\n#include <SpecKit/SpecKit.h>\nint main(void) { printf("library-value=%d\\n", speckit_value()); return 0; }\n')
    project(work / 'Demo.xcodeproj')
    podfile(work, linkage)
    return module
