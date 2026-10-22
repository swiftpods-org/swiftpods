# frozen_string_literal: true

module SwiftPods
  # Track observable manifest inputs without exposing environment values.
  module EnvironmentInputs
    def [](name)
      value = super
      SwiftPods.environment_inputs[name.to_s] = {
        "status" => "tracked",
        "sha256" => Digest::SHA256.hexdigest(value.nil? ? "absent" : "value:" + value),
      }
      value
    end

    def fetch(name, *arguments, &block)
      self[name]
      super
    end

    def key?(name)
      self[name]
      super
    end
  end

  class << self
    attr_accessor :session

    def environment_inputs
      @environment_inputs ||= {}
    end

    def callback(operation, data)
      raise Unsupported, "Swift callback requested outside an adapter session" unless session
      session.callback(operation, data)
    end
  end

  # A single JSON-lines session owns the evaluated manifests and live hook
  # objects. User closures never share the request handler's lexical scope.
  class Session
    INPUT_COVERAGE = "Evaluated manifests, loaded project helpers and observed ENV reads; arbitrary filesystem, process and network inputs are not fully tracked"

    def initialize(input: STDIN, output: STDOUT.dup)
      @input = input
      @output = output
      @inputs = {}
      @evaluated_specs = {}
    end

    def run
      @output.sync = true
      SwiftPods.session = self
      ENV.singleton_class.prepend(EnvironmentInputs) unless ENV.singleton_class.ancestors.include?(EnvironmentInputs)
      STDOUT.reopen(STDERR)
      $stdout = STDOUT
      while (line = @input.gets)
        handle_line(line)
      end
    ensure
      SwiftPods.session = nil
    end

    def callback(operation, data)
      @output.puts(JSON.generate("callback" => operation, "value" => data))
      line = @input.gets || raise(Unsupported, "Swift callback channel closed")
      response = JSON.parse(line)
      raise Unsupported, response["message"] unless response["ok"]
      response["value"]
    end

    def handle_line(line)
      value = dispatch(JSON.parse(line))
      @output.puts(JSON.generate("ok" => true, "value" => value))
    rescue StandardError, ScriptError, SystemExit => error
      # Syntax/load failures and an explicit exit in user Ruby are protocol
      # errors. Fatal VM exceptions are deliberately not swallowed here.
      @output.puts(JSON.generate("ok" => false, "class" => error.class.name,
                                 "message" => error.message, "backtrace" => error.backtrace))
    end

    def dispatch(request)
      case request.fetch("operation")
      when "podfile" then evaluate_podfile(request)
      when "analyzed_podfile" then apply_analysis(request)
      when "spec" then evaluate_spec(request)
      when "spec_serialization" then serialize_spec(request)
      when "yaml" then read_yaml(request.fetch("path"))
      when "plugins_prepare" then prepare_plugins
      when "hook", "plugin_hook" then run_hook(request)
      when "glob" then Dir.glob(request.fetch("patterns"), base: request.fetch("root")).sort
      when "inputs" then input_manifest
      else raise Unsupported, "Unknown DSL operation #{request["operation"]}"
      end
    end

    private

    def evaluate_podfile(request)
      path = File.realpath(request.fetch("path"))
      Dir.chdir(File.dirname(path))
      @podfile = Podfile.new
      @podfile.evaluate_file(path)
      record_file(path)
      @podfile.to_hash
    end

    def apply_analysis(request)
      request.fetch("targets").each do |value|
        entry = @podfile.targets.find { |target| target["_id"] == value["_id"] }
        raise Unsupported, "Analyzed target identity is missing" unless entry
        %w[platform project swift_version application_extension_api_only].each do |key|
          value[key].nil? ? entry.delete(key) : entry[key] = value[key]
        end
      end
      @podfile.to_hash
    end

    def evaluate_spec(request)
      path = File.realpath(request.fetch("path"))
      @evaluated_specs[path] = Pod::Spec.from_file(path)
      record_file(path)
      @evaluated_specs[path].to_hash
    end

    def serialize_spec(request)
      path = File.realpath(request.fetch("path"))
      spec = @evaluated_specs[path] ||= Pod::Spec.from_file(path)
      record_file(path)
      { "json" => spec.to_pretty_json }
    end

    def read_yaml(path)
      YAML.safe_load(File.read(path), permitted_classes: [Symbol], aliases: false) || {}
    end

    def prepare_plugins
      sandbox = Pod::Sandbox.new(File.join(Dir.pwd, "Pods"))
      lockfile = File.file?("Podfile.lock") ? read_yaml("Podfile.lock") : nil
      context = Pod::Installer::PreInstallHooksContext.new(@podfile, sandbox, sandbox.root.to_s, lockfile)
      Pod::HooksManager.run(:pre_install, context, @podfile.data["plugins"])
      sources = Pod::Installer::SourceProviderHooksContext.new
      Pod::HooksManager.run(:source_provider, sources, @podfile.data["plugins"])
      @podfile.data["sources"].concat(sources.sources.map { |source| source.respond_to?(:url) ? source.url : source.to_s })
      @podfile.to_hash
    end

    def run_hook(request)
      @podfile.instance_variable_set(:@analyzed_targets, request["manifest"]["targets"]) if request["manifest"]
      project = update_installer(request)
      @installer.instance_variable_set(:@hook_phase, request.fetch("name"))
      @installer.instance_variable_set(:@integrate_user_projects, request["integrate_user_projects"])
      @installer.update_targets!(request.fetch("pod_targets", []))
      if request.fetch("operation") == "plugin_hook"
        context = Pod::Installer::PostInstallHooksContext.new(
          @installer.sandbox, @installer.sandbox.root.to_s, project,
          @child_projects, @installer.aggregate_targets
        )
        Pod::HooksManager.run(request.fetch("name"), context, @podfile.data["plugins"])
      else
        @podfile.hooks[request.fetch("name")]&.call(@installer)
      end
      hook_result(project, request.fetch("project"))
    end

    def update_installer(request)
      data = request.fetch("project")
      project = if data["generated"] == false
          nil
        elsif @installer&.pods_project
          @installer.pods_project.update!(data)
        else
          Xcodeproj::Project.new(data)
        end
      if @installer
        @installer.pods_project = project
      else
        @installer = Pod::Installer.new(project, @podfile, Dir.pwd)
      end
      previous = @installer.generated_projects.to_h { |entry| [entry.path.to_s, entry] }
      @child_projects = request.fetch("projects", []).map do |entry|
        previous[entry.fetch("path")]&.update!(entry) || Xcodeproj::Project.new(entry)
      end
      @installer.generated_projects = @child_projects.empty? ? [project].compact : @child_projects
      project
    end

    def hook_result(project, data)
      graph = project ? project.to_hash.merge("projects" => @child_projects.map(&:to_hash)) : data
      graph.merge("pod_targets" => @installer.pod_targets.map(&:to_native),
                  "user_projects" => @installer.user_projects.map(&:to_hash))
    end

    def record_file(path)
      @inputs[path] = Digest::SHA256.file(path).hexdigest
    end

    def input_manifest
      @inputs.merge!(Pod.instance_variable_get(:@spec_inputs) || {})
      $LOADED_FEATURES.select { |path| path.start_with?(Dir.pwd + "/") }.each do |path|
        record_file(path) if File.file?(path)
      end
      { "files" => @inputs, "environment" => SwiftPods.environment_inputs, "coverage" => INPUT_COVERAGE }
    end
  end
end
