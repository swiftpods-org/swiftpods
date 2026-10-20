# frozen_string_literal: true

module Pod
  class Version < Gem::Version
    PATTERN = /\A[0-9]+(?:[.-][0-9A-Za-z-]++)*(?:\+[0-9A-Za-z.-]+)?\z/

    def self.correct?(value)
      PATTERN.match?(value.to_s.strip)
    end

    def initialize(value)
      @original_version = value.to_s.strip.freeze
      raise ArgumentError, "Malformed version number string #{value}" unless self.class.correct?(value)
      @comparison_parts = nil
      super(@original_version.split("+", 2).first)
    end

    def to_s
      @original_version
    end

    def prerelease?
      !comparison_parts.last.nil?
    end

    # Keep the same release/prerelease ordering as the native resolver. Gem's
    # normalization drops significant prerelease zeros and reverses mixed tokens.
    def <=>(other)
      other = self.class.new(other) if other.is_a?(String) && self.class.correct?(other)
      return nil unless other.is_a?(Version)
      release, prerelease = comparison_parts
      other_release, other_prerelease = other.send(:comparison_parts)
      order = release <=> other_release
      return order unless order.zero?
      return 0 if prerelease == other_prerelease
      return 1 if prerelease.nil?
      return -1 if other_prerelease.nil?
      prerelease.zip(other_prerelease).each do |left, right|
        return 1 if right.nil?
        next if left == right
        return -1 if left.is_a?(Integer) && right.is_a?(String)
        return 1 if left.is_a?(String) && right.is_a?(Integer)
        return left <=> right
      end
      prerelease.length <=> other_prerelease.length
    end

    def hash
      comparison_parts.hash
    end

    def eql?(other)
      other.is_a?(Version) && self == other
    end

    def marshal_dump
      [to_s]
    end

    def encode_with(coder)
      coder.add("version", to_s)
    end

    def yaml_initialize(_tag, values)
      initialize(values.fetch("version"))
    end

    def freeze
      comparison_parts
      super
    end

    alias version to_s

    private

    def comparison_parts
      @comparison_parts ||= begin
        body, suffix = to_s.split("+", 2).first.split("-", 2)
        tokens = body.scan(/[0-9]+|[A-Za-z]+/).map { |part| /\A[0-9]+\z/.match?(part) ? part.to_i : part }
        release = tokens.take_while { |part| part.is_a?(Integer) }
        prerelease = tokens.drop(release.length)
        if suffix
          prerelease += suffix.scan(/[0-9]+|[A-Za-z]+/).map { |part| /\A[0-9]+\z/.match?(part) ? part.to_i : part }
        end
        release.pop while release.last == 0
        prerelease = nil if suffix.nil? && prerelease.empty?
        [release.freeze, prerelease&.freeze].freeze
      end
    end
  end

  class Requirement < Gem::Requirement
    def self.parse(value)
      return ["=", value] if value.is_a?(Gem::Version)
      match = /\A\s*(~>|>=|<=|!=|=|>|<)?\s*([^\s]+)\s*\z/.match(value.to_s)
      raise BadRequirementError, "Illformed requirement #{value.inspect}" unless match
      [match[1] || "=", Version.new(match[2])]
    end
  end

  class Platform
    attr_reader :name, :deployment_target

    def initialize(input, deployment = nil)
      if input.is_a?(Platform)
        @name = input.name
        @deployment_target = input.deployment_target
      else
        name = input.to_s.downcase
        @name = { "macos" => "osx", "xros" => "visionos" }.fetch(name, name).to_sym
        deployment = deployment[:deployment_target] if deployment.is_a?(Hash)
        @deployment_target = deployment && Version.new(deployment)
      end
    end

    def to_s
      [self.class.string_name(name), deployment_target].compact.join(" ")
    end

    def self.string_name(name)
      { ios: "iOS", osx: "macOS", tvos: "tvOS", watchos: "watchOS", visionos: "visionOS" }.fetch(name.to_sym)
    end

    def ==(other)
      return name == other if other.is_a?(Symbol)
      other.is_a?(Platform) && name == other.name && deployment_target == other.deployment_target
    end

    def eql?(other)
      other.is_a?(Platform) && self == other
    end

    def hash
      [name, deployment_target].hash
    end

    def supports?(other)
      other = Platform.new(other)
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

    def self.static_library
      new
    end

    def self.static_framework
      new(packaging: :framework)
    end

    def self.dynamic_framework
      new(linkage: :dynamic, packaging: :framework)
    end

    def self.dynamic_library
      new(linkage: :dynamic)
    end

    def static?
      linkage == :static
    end

    def dynamic?
      linkage == :dynamic
    end

    def framework?
      packaging == :framework
    end

    def library?
      packaging == :library
    end

    def static_library?
      static? && library?
    end

    def static_framework?
      static? && framework?
    end

    def dynamic_framework?
      dynamic? && framework?
    end

    def dynamic_library?
      dynamic? && library?
    end

    def to_hash
      { linkage: linkage, packaging: packaging }
    end

    def ==(other)
      other.is_a?(BuildType) && to_hash == other.to_hash
    end

    alias eql? ==

    def hash
      to_hash.hash
    end
  end
end
