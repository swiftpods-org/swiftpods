# frozen_string_literal: true

module SwiftPods
  class Unsupported < StandardError
  end

  class Record
    def initialize(values)
      @values = values.transform_keys(&:to_sym).freeze
      @values.each_key { |name| define_singleton_method(name) { @values.fetch(name) } }
    end

    def to_h = @values.dup
  end

  module EngineIsolation
    COMPATIBLE_FEATURES = %w[
      xcodeproj xcodeproj/project cocoapods cocoapods-core cocoapods/version cocoapods-core/version
      cocoapods-core/platform cocoapods-core/requirement cocoapods-core/specification cocoapods-
      core/specification/dsl cocoapods/target/build_type cocoapods/installer cocoapods/hooks_manager
      cocoapods/installer/base_install_hooks_context cocoapods/installer/pre_install_hooks_context
      cocoapods/installer/post_install_hooks_context
      cocoapods/installer/source_provider_hooks_context
    ].freeze

    def require(path)
      if COMPATIBLE_FEATURES.include?(path.to_s)
        return false if ($swiftpods_own_features ||= []).include?(path.to_s)
        $swiftpods_own_features << path.to_s
        return true
      end
      if path.to_s.match?(%r{\A(?:cocoapods(?:-core)?)(?:/|\z)})
        raise Unsupported, "Loading a third-party installation engine is forbidden: #{path}"
      end
      super
    end
  end
end

Kernel.prepend(SwiftPods::EngineIsolation)
require "bundler/setup" if ENV["SWIFTPODS_PROFILE_GEMFILE"]
# Bundler's setup API does not populate the executable marker set by `bundle
# exec`. Both enter the same verified imported gem environment here.
if ENV["SWIFTPODS_PROFILE_GEMFILE"]
  ENV["BUNDLE_BIN_PATH"] = Gem.bin_path("bundler", "bundle", Bundler::VERSION)
end
