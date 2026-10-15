Pod::Spec.new do |spec|
  spec.name = 'GameCore'
  spec.version = '1.2.3.4'
  spec.summary = 'SwiftPods mixed-language compatibility fixture.'
  spec.homepage = 'https://example.invalid/gamecore'
  spec.license = { :type => 'MIT', :file => 'LICENSE' }
  spec.author = { 'SwiftPods Tests' => 'tests@example.invalid' }
  spec.source = { :git => 'https://example.invalid/gamecore.git', :tag => spec.version.to_s }
  spec.osx.deployment_target = '13.0'
  spec.swift_versions = ['5.0']
  spec.source_files = 'Sources/**/*.{h,c,cpp,m,mm,swift}'
  spec.public_header_files = 'Sources/GameCore.h'
  spec.requires_arc = true
  spec.libraries = 'c++'
  spec.frameworks = 'Foundation'
  spec.pod_target_xcconfig = { 'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17' }
  spec.resource_bundles = { 'GameCoreResources' => ['Resources/**/*'] }
  spec.prepare_command = 'touch prepare-ran'
end
