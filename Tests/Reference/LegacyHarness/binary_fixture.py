"""Build real, distinct device/simulator XCFrameworks without network or signing identities."""
from pathlib import Path
import platform
import plistlib
import shutil
from integration import ROOT, run


def add_vendor(project, env, dynamic):
    vendor = project / 'Modules/VendorAdapter'
    vendor.mkdir()
    (vendor / 'VendorAdapter.h').write_text('''#ifdef __cplusplus
extern "C" {
#endif
int vendor_adapter_value(void);
#ifdef __cplusplus
}
#endif
''')
    (vendor / 'VendorAdapter.m').write_text('#import "VendorAdapter.h"\n#import <VendorKit/VendorKit.h>\nint vendor_adapter_value(void) { return vendorkit_value(); }\n')
    (vendor / 'VendorKit.c').write_text('int vendorkit_value(void) { return 42; }\n')
    frameworks = []
    for sdk, architectures in [('iphoneos', ['arm64']), ('iphonesimulator', ['arm64', 'x86_64'])]:
        folder = vendor / sdk
        framework = folder / 'VendorKit.framework'
        (framework / 'Headers').mkdir(parents=True)
        (framework / 'Modules').mkdir()
        (framework / 'Headers/VendorKit.h').write_text('int vendorkit_value(void);\n')
        (framework / 'Modules/module.modulemap').write_text('framework module VendorKit { umbrella header "VendorKit.h" export * }\n')
        (framework / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'org.swiftpods.VendorKit', 'CFBundleName': 'VendorKit',
            'CFBundleExecutable': 'VendorKit', 'CFBundlePackageType': 'FMWK',
            'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0', 'MinimumOSVersion': '15.0',
            'CFBundleSupportedPlatforms': ['iPhoneOS' if sdk == 'iphoneos' else 'iPhoneSimulator']}))
        binaries = []
        for architecture in architectures:
            target = architecture + '-apple-ios15.0' + ('-simulator' if sdk == 'iphonesimulator' else '')
            flags = ['/usr/bin/xcrun', '--sdk', sdk, 'clang', '-target', target, '-Wall', '-Wextra', '-Werror']
            binary = folder / ('VendorKit-' + architecture)
            if dynamic:
                run([*flags, '-dynamiclib', vendor / 'VendorKit.c', '-install_name', '@rpath/VendorKit.framework/VendorKit',
                     '-compatibility_version', '1.0', '-current_version', '1.0', '-o', binary], project, env, folder / (architecture + '-compile.log'), reject_warnings=True)
            else:
                obj = folder / (architecture + '.o')
                run([*flags, '-c', vendor / 'VendorKit.c', '-o', obj], project, env, folder / (architecture + '-compile.log'), reject_warnings=True)
                run(['/usr/bin/xcrun', 'libtool', '-static', '-o', binary, obj], project, env, folder / (architecture + '-archive.log'), reject_warnings=True)
            binaries.append(binary)
        run(['/usr/bin/xcrun', 'lipo', '-create', *binaries, '-output', framework / 'VendorKit'], project, env, folder / 'universal.log', reject_warnings=True)
        frameworks.append(framework)
    run(['xcodebuild', '-create-xcframework', '-framework', frameworks[0], '-framework', frameworks[1],
         '-output', vendor / 'VendorKit.xcframework'], project, env, vendor / 'xcframework.log', reject_warnings=True)
    # Keep SDK producer intermediates/logs outside the consumer project. The
    # pod distributes the XCFramework, not its separate raw device/sim builds.
    intermediates = project.parent / (project.name + '-vendor-build')
    intermediates.mkdir()
    for framework in frameworks:
        shutil.move(framework.parent, intermediates / framework.parent.name)
    (vendor / 'VendorAdapter.podspec').write_text('''Pod::Spec.new do |s|
  s.name = 'VendorAdapter'
  s.version = '1.0.0'
  s.summary = 'Real binary SDK fixture'
  s.homepage = 'https://example.invalid'
  s.license = 'MIT'
  s.author = 'SwiftPods Tests'
  s.source = { :git => 'https://example.invalid/vendor.git', :tag => s.version.to_s }
  s.ios.deployment_target = '15.0'
  s.source_files = 'VendorAdapter.{h,m}'
  s.vendored_frameworks = 'VendorKit.xcframework'
end
''')
    podfile = project / 'Podfile'
    podfile.write_text(podfile.read_text().replace("target 'Demo' do", "target 'Demo' do\n  pod 'VendorAdapter', :path => './Modules/VendorAdapter'"))
    # Define the SDK consumer explicitly; product code never changes user flags.
    script = project / 'enable_vendor.rb'
    script.write_text('''require 'xcodeproj'
p = Xcodeproj::Project.open('Demo.xcodeproj')
p.targets.first.build_configurations.each do |c|
  c.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] << 'SWIFTPODS_VENDOR_FIXTURE=1'
end
p.save
''')
    from integration import RUBY
    run([RUBY, '-rbundler/setup', script], project, env, vendor / 'consumer.log')
    return dynamic
