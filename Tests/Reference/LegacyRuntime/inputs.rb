# frozen_string_literal: true

module SwiftPods
  module Inputs
    @initial_environment = ENV.to_h.freeze
    @environment_reads = {}
    @loaded = []
    @project = File.expand_path(Dir.pwd)

    def self.project=(value)
      @project = File.expand_path(value)
    end

    def self.environment_read(key, locations)
      return unless key.is_a?(String)
      return unless locations.any? { |location| location.absolute_path&.start_with?(@project + '/') && !location.absolute_path.start_with?(@project + '/Pods/', @project + '/.swiftpods/') }
      if key.match?(/TOKEN|PASSWORD|SECRET|CREDENTIAL|PRIVATE_KEY|API_KEY|ACCESS_KEY/i)
        @environment_reads[key] = { 'status' => 'sensitive_not_recorded', 'present' => @initial_environment.key?(key) }
      else
        value = @initial_environment[key]
        @environment_reads[key] = { 'status' => 'tracked', 'sha256' => Digest::SHA256.hexdigest(value.nil? ? 'absent' : 'value:' + value) }
      end
    end

    def self.loaded(path)
      @loaded << File.expand_path(path) if path.is_a?(String) && File.file?(path)
    end

    def self.report(podfile, specs)
      paths = $LOADED_FEATURES + @loaded + [podfile.defined_in_file&.to_s] + specs.map { |spec| spec.defined_in_file&.to_s }
      files = paths.compact.uniq.select { |path| path.start_with?(@project + '/') && !path.start_with?(@project + '/Pods/', @project + '/.swiftpods/') && File.file?(path) }
      { 'files' => files.sort.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] },
        'environment' => @environment_reads,
        'coverage' => 'Podfile, local podspecs, require/load features and observed ENV reads; arbitrary filesystem/syscalls, time and network inputs remain unknown' }
    end
  end

  module EnvironmentReads
    def [](key)
      SwiftPods::Inputs.environment_read(key, caller_locations(1, 8))
      super
    end

    def fetch(key, *args, &block)
      SwiftPods::Inputs.environment_read(key, caller_locations(1, 8))
      super
    end

    def values_at(*keys)
      keys.each { |key| SwiftPods::Inputs.environment_read(key, caller_locations(1, 8)) }
      super
    end
  end
  ENV.singleton_class.prepend(EnvironmentReads)

  module LoadedInputs
    def load(path, *args)
      SwiftPods::Inputs.loaded(path)
      super
    end
    private :load
  end
  Kernel.prepend(LoadedInputs)
end
