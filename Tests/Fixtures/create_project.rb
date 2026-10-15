require 'xcodeproj'
project = Xcodeproj::Project.new('Demo.xcodeproj')
target = project.new_target(:application, 'Demo', :osx, '13.0')
target.source_build_phase.add_file_reference(project.main_group.new_file('Sources/main.mm'))
target.build_configurations.each do |config|
  config.build_settings.merge!(
    'GENERATE_INFOPLIST_FILE' => 'YES', 'PRODUCT_BUNDLE_IDENTIFIER' => 'org.swiftpods.fixture',
    'CODE_SIGNING_ALLOWED' => 'NO', 'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17', 'SWIFT_VERSION' => '5.0',
    'GCC_TREAT_WARNINGS_AS_ERRORS' => 'YES', 'SWIFT_TREAT_WARNINGS_AS_ERRORS' => 'YES',
    'GCC_PREPROCESSOR_DEFINITIONS' => ['$(inherited)', 'FIXTURE_USER_FLAG=1']
  )
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.set_launch_target(target)
scheme.save_as(project.path, 'Demo', true)
