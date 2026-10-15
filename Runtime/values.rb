# frozen_string_literal: true

module Pod
  class Version < Gem::Version
  end

  class Requirement < Gem::Requirement
  end

  class Platform
    attr_reader :name, :deployment_target

    def initialize(name, deployment = nil)
      @name = name.to_sym
      @deployment_target = deployment && Version.new(deployment)
    end

    def to_s = [self.class.string_name(name), deployment_target].compact.join(" ")

    def self.string_name(name)
      { ios: "iOS", osx: "macOS", tvos: "tvOS", watchos: "watchOS", visionos: "visionOS" }.fetch(name.to_sym)
    end

    def ==(other)
      other.is_a?(Platform) && name == other.name && deployment_target == other.deployment_target
    end

    alias eql? ==

    def hash = [name, deployment_target].hash

    def supports?(other)
      name == other.name && (!deployment_target || !other.deployment_target || deployment_target >= other.deployment_target)
    end

    def supports_dynamic_frameworks?
      name != :ios || !deployment_target || deployment_target >= Version.new("8.0")
    end
  end

  class BuildType
    attr_reader :linkage, :packaging

    def initialize(linkage: :static, packaging: :library)
      raise ArgumentError, "Unknown linkage or packaging" unless [:static, :dynamic].include?(linkage) && [:library, :framework].include?(packaging)
      @linkage = linkage
      @packaging = packaging
    end

    def self.static_library = new
    def self.static_framework = new(packaging: :framework)
    def self.dynamic_framework = new(linkage: :dynamic, packaging: :framework)
    def self.dynamic_library = new(linkage: :dynamic)

    def static? = linkage == :static
    def dynamic? = linkage == :dynamic
    def framework? = packaging == :framework
    def library? = packaging == :library
    def static_library? = static? && library?
    def static_framework? = static? && framework?
    def dynamic_framework? = dynamic? && framework?
    def dynamic_library? = dynamic? && library?
    def to_hash = { linkage: linkage, packaging: packaging }
    def ==(other) = other.is_a?(BuildType) && to_hash == other.to_hash

    alias eql? ==

    def hash = to_hash.hash
  end
end
