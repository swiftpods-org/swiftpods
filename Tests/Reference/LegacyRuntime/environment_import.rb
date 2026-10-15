# frozen_string_literal: true

# This file is evaluated inside the imported Gemfile's Bundler::Dsl context.
# It preserves the original Gemfile's path for require_relative/path gems and
# adds exact constraints without silently upgrading any locked gem.
module SwiftPodsEnvironment
  def self.configure(dsl, configuration)
    dsl.eval_gemfile(configuration.fetch('gemfile'))
    pins = configuration.fetch('pins')
    dsl.dependencies.each do |dependency|
      version = pins[dependency.name]
      next unless version
      unless dependency.requirement.satisfied_by?(Gem::Version.new(version))
        raise Bundler::GemfileError, "SP-ENV-CONFLICT: #{dependency.name} #{dependency.requirement} conflicts with pinned #{version}"
      end
      if %w[cocoapods cocoapods-core].include?(dependency.name) && dependency.source
        raise Bundler::GemfileError, "SP-ENV-CORE-SOURCE: #{dependency.name} must use SwiftPods' maintained core, not a custom source"
      end
      dependency.instance_variable_set(:@requirement, Gem::Requirement.new("= #{version}"))
    end
    dsl.dependencies.reject! { |dependency| %w[cocoapods cocoapods-core].include?(dependency.name) }
    pins.each do |name, version|
      next if dsl.dependencies.any? { |dependency| dependency.name == name }
      if %w[cocoapods cocoapods-core].include?(name)
        dsl.gem(name, "= #{version}", :path => File.join(configuration.fetch('bundle'), 'vendor', name))
      else
        dsl.gem(name, "= #{version}")
      end
    end
    # A Gemfile containing only local gems need not have declared a remote.
    dsl.source('https://rubygems.org') if dsl.instance_variable_get(:@sources).rubygems_remotes.empty?
  end
end
