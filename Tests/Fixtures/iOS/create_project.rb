require 'xcodeproj'
project = Xcodeproj::Project.new('Demo.xcodeproj')
target = project.new_target(:application, 'Demo', :ios, '15.0')
target.add_system_framework('UIKit')
target.source_build_phase.add_file_reference(project.main_group.new_file('Sources/main.mm'))
target.source_build_phase.add_file_reference(project.main_group.new_file('Sources/FixtureIntent.swift'))
target.build_configurations.each do |config|
  config.build_settings.merge!(
    'GENERATE_INFOPLIST_FILE' => 'NO', 'INFOPLIST_FILE' => 'Info.plist',
    'PRODUCT_BUNDLE_IDENTIFIER' => 'org.swiftpods.ios-fixture', 'TARGETED_DEVICE_FAMILY' => '1,2',
    # This is an unsigned test application, not a product signing policy.
    'CODE_SIGNING_ALLOWED' => 'NO', 'CLANG_ENABLE_OBJC_ARC' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17', 'SWIFT_VERSION' => '5.0',
    'GCC_TREAT_WARNINGS_AS_ERRORS' => 'YES', 'SWIFT_TREAT_WARNINGS_AS_ERRORS' => 'YES',
    'GCC_PREPROCESSOR_DEFINITIONS' => ['$(inherited)', 'FIXTURE_USER_FLAG=1']
  )
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.set_launch_target(target)
scheme.save_as(project.path, 'Demo', true)
