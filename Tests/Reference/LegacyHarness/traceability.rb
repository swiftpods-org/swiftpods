# frozen_string_literal: true

# Observe actual baseline test execution without wrapping DSL methods or
# changing arity, caller locations, exceptions or argument forwarding.
require 'bundler/setup'
require 'json'
require 'set'
checkout, output = ARGV.shift(2)
$LOAD_PATH.unshift(File.join(checkout, 'lib'), File.join(checkout, 'spec'))
require File.join(checkout, 'spec/spec_helper')

module SwiftPodsTrace
  @active = {}
  @calls = Hash.new { |hash, key| hash[key] = Set.new }
  @cases = {}
  class << self
    attr_reader :calls, :cases, :active
  end

  module CaseScope
    def run_requirement(description, block)
      file, line = block.source_location
      id = "#{file}:#{line}"
      SwiftPodsTrace.cases[id] = { 'file' => file, 'line' => line, 'context' => name, 'description' => description }
      SwiftPodsTrace.active[Thread.current.object_id] = id
      super
    ensure
      SwiftPodsTrace.active.delete(Thread.current.object_id)
    end
  end
end
Bacon::Context.prepend(SwiftPodsTrace::CaseScope)

podfile = Pod::Podfile::DSL
specification = Pod::Specification::DSL
owners = { podfile => 'podfile', specification => 'podspec' }
options = defined?(Pod::Installer::InstallationOptions) && Pod::Installer::InstallationOptions
owners[options] = 'installation_options' if options
trace = TracePoint.new(:call, :c_call) do |point|
  case_id = SwiftPodsTrace.active[Thread.current.object_id]
  next unless case_id
  if (group = owners[point.defined_class])
    SwiftPodsTrace.calls["#{group}.#{point.method_id}"] << case_id
    SwiftPodsTrace.calls["#{group}.#{point.callee_id}"] << case_id
  elsif point.defined_class == Pod::Specification::DSL::Attribute
    attribute = point.self
    SwiftPodsTrace.calls["attribute.#{attribute.name}"] << case_id
  end
end
trace.enable
ARGV.each { |file| require File.expand_path(file) }
trace.disable

inventory = {}
[[podfile, 'podfile'], [specification, 'podspec'], [options, 'installation_options']].each do |owner, prefix|
  next unless owner
  owner.instance_methods(false).sort.each do |method|
    id = "#{prefix}.#{method}"
    inventory[id] = { 'kind' => prefix, 'name' => method.to_s, 'cases' => SwiftPodsTrace.calls[id].to_a.sort }
  end
end
specification.attributes.each do |name, attribute|
  id = "attribute.#{name}"
  inventory[id] = { 'kind' => 'attribute', 'name' => name.to_s,
                    'types' => attribute.types.map(&:to_s), 'root_only' => attribute.root_only?,
                    'multi_platform' => attribute.multi_platform?, 'cases' => SwiftPodsTrace.calls[id].to_a.sort }
end
counts = Bacon::Counter
result = { 'schema_version' => 1, 'suite' => File.basename(checkout),
           'status' => counts[:failed].to_i.zero? && counts[:errors].to_i.zero? ? 'passed' : 'failed',
           'specifications' => counts[:specifications], 'requirements' => counts[:requirements],
           'failed' => counts[:failed], 'errors' => counts[:errors],
           'inventory' => inventory, 'cases' => SwiftPodsTrace.cases,
           'scope' => 'Observed calls in upstream assertions; a call alone does not certify every type/default/inheritance/build combination' }
File.write(output, JSON.pretty_generate(result) + "\n")
