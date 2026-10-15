# frozen_string_literal: true

require 'bundler'
require 'fileutils'
require 'digest'

module SwiftPods
  def self.import_environment(gemfile, destination, bundle, local = 'false')
    baseline = Bundler::LockfileParser.new(File.read(File.join(bundle, 'Gemfile.lock')))
    by_name = baseline.specs.group_by(&:name)
    queue = %w[cocoapods cocoapods-core benchmark bigdecimal mutex_m]
    pins = { 'bundler' => Bundler::VERSION }
    until queue.empty?
      name = queue.shift
      next if pins[name]
      candidates = by_name.fetch(name)
      versions = candidates.map { |spec| spec.version.to_s }.uniq
      raise "Ambiguous baseline gem #{name}" unless versions.length == 1
      pins[name] = versions.first
      candidates.first.dependencies.each { |dependency| queue << dependency.name }
    end
    original_lock = gemfile + '.lock'
    original = File.read(original_lock) if File.file?(original_lock)
    if original
      Bundler::LockfileParser.new(original).specs.each do |spec|
        version = spec.version.to_s
        if pins[spec.name] && pins[spec.name] != version
          raise "SP-ENV-CONFLICT: locked #{spec.name} #{version} conflicts with required #{pins[spec.name]}; the project lock was not updated"
        end
        pins[spec.name] = version
      end
      # Locked path sources were relative to the user's Gemfile, not this
      # private profile's generated Gemfile.
      section = nil
      copied = original.lines.map do |line|
        section = line.strip if line.match?(/\A[A-Z][A-Z ]*\n\z/)
        if section == 'PATH' && line.start_with?('  remote: ')
          remote = line.delete_prefix('  remote: ').strip
          line = "  remote: #{File.expand_path(remote, File.dirname(gemfile))}\n"
        end
        line
      end.join
      File.write(File.join(destination, 'Gemfile.lock'), copied)
    end
    config = { 'gemfile' => gemfile, 'bundle' => bundle, 'pins' => pins }
    File.write(File.join(destination, 'constraints.json'), JSON.pretty_generate(config) + "\n")
    wrapper = <<~RUBY
      require #{File.join(bundle, 'host/environment_import.rb').inspect}
      SwiftPodsEnvironment.configure(self, JSON.parse(File.read(File.join(__dir__, 'constraints.json'))))
    RUBY
    File.write(File.join(destination, 'Gemfile'), wrapper)
    ENV['BUNDLE_GEMFILE'] = File.join(destination, 'Gemfile')
    ENV['BUNDLE_FROZEN'] = 'false'
    ENV['BUNDLE_WITHOUT'] = ''
    Bundler.reset!
    definition = Bundler.definition
    Bundler::Installer.install(Pathname(destination), definition, 'system' => true, 'local' => local == 'true')
    selected = definition.specs
    selected.each do |spec|
      next unless pins[spec.name]
      raise "SP-ENV-CONFLICT: Bundler changed pinned #{spec.name}" unless spec.version.to_s == pins[spec.name]
    end
    if original && File.read(original_lock) != original
      raise 'SP-ENV-INPUT-CHANGED: original Gemfile.lock changed during import'
    end
    gems = selected.map { |spec| { 'name' => spec.name, 'version' => spec.version.to_s, 'platform' => spec.platform.to_s } }
    SwiftPods.emit('environment_imported', 'gems' => gems.sort_by { |entry| entry['name'] },
                   'plugins' => gems.select { |entry| entry['name'].start_with?('cocoapods-') },
                   'locked_input' => !original.nil?)
  end
end
