module Fastlane
  module Swiftpods
    VERSION = (Gem.loaded_specs['fastlane-plugin-swiftpods']&.version&.to_s || 'development').freeze

    def self.all_classes
      Dir[File.expand_path('swiftpods/actions/*.rb', __dir__)]
    end
  end
end

Fastlane::Swiftpods.all_classes.each { |path| require path }
