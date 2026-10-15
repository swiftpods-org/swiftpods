#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone regressions for the public Ruby adapter. No test gems are required.
require "tmpdir"
require "open3"
require "rbconfig"
require_relative "../Runtime/runtime"

class RubyAdapterRegressions
  def assert(value, message)
    raise message unless value
  end

  def graph
    {
      "path" => "/tmp/SwiftPodsAdapter/App.xcodeproj",
      "graph" => {
        "rootObject" => "ROOT",
        "objects" => {
          "ROOT" => { "isa" => "PBXProject", "mainGroup" => "MAIN", "targets" => [] },
          "MAIN" => { "isa" => "PBXGroup", "children" => ["FILE"], "sourceTree" => "<group>" },
          "FILE" => { "isa" => "PBXFileReference", "path" => "Value.swift", "sourceTree" => "<group>" },
          "CONFIG" => { "isa" => "XCBuildConfiguration", "name" => "Debug",
                        "buildSettings" => { "OTHER_SWIFT_FLAGS" => ["$(inherited)"] } },
        },
      },
    }
  end

  def test_captured_object_list_remains_live_after_project_refresh
    project = Xcodeproj::Project.new(graph)
    children = project.main_group.children
    incoming = Marshal.load(Marshal.dump(project.to_hash))
    incoming["graph"]["objects"]["MAIN"]["children"] << "SECOND"
    incoming["graph"]["objects"]["SECOND"] = { "isa" => "PBXFileReference", "path" => "Second.swift" }
    project.update!(incoming)
    assert(children.map(&:uuid) == %w[FILE SECOND], "A retained object list missed newly analyzed project objects")
    children.clear
    assert(project.main_group.children.empty?, "A retained object list stopped modifying the live project")
  end

  def test_captured_nested_build_settings_remain_live
    project = Xcodeproj::Project.new(graph)
    flags = project.object("CONFIG").build_settings["OTHER_SWIFT_FLAGS"]
    incoming = Marshal.load(Marshal.dump(project.to_hash))
    incoming["graph"]["objects"]["CONFIG"]["buildSettings"]["OTHER_SWIFT_FLAGS"] << "-DANALYZED"
    project.update!(incoming)
    flags << "-DHOOK"
    assert(project.object("CONFIG").build_settings["OTHER_SWIFT_FLAGS"] == %w[$(inherited) -DANALYZED -DHOOK], "Nested settings retained by a hook became detached")
  end

  def test_object_list_ranges_decode_references
    project = Xcodeproj::Project.new(graph)
    values = project.main_group.children[0..0]
    assert(values.first.equal?(project.object("FILE")), "ObjectList range indexing returned raw UUIDs")
    values = project.main_group.children[0, 1]
    assert(values.first.equal?(project.object("FILE")), "ObjectList slice indexing returned raw UUIDs")
  end

  def test_object_list_delete_reports_absence
    project = Xcodeproj::Project.new(graph)
    children = project.main_group.children
    assert(children.delete("missing").nil?, "Deleting a missing object reported success")
    existing = project.object("FILE")
    assert(children.delete(existing).equal?(existing) && children.empty?, "Deleting an existing object lost its identity")
  end

  def test_reloaded_projects_do_not_overwrite_existing_generated_objects
    project = Xcodeproj::Project.new(graph)
    first = project.new_object("PBXFileReference", "path" => "Hook.swift")
    reloaded = Xcodeproj::Project.new(Marshal.load(Marshal.dump(project.to_hash)))
    second = reloaded.new_object("PBXFileReference", "path" => "Hook.swift")
    assert(first.uuid != second.uuid, "A second install overwrote a previously generated PBX object")
    assert(reloaded.object(first.uuid) && reloaded.object(second.uuid), "Generated object collision discarded an object")
  end

  def test_project_references_resolve_parent_group_paths
    project = Xcodeproj::Project.new(graph)
    group = project.main_group.new_group("Dependencies", "Deps")
    reference = group.new_file("Child.xcodeproj")
    assert(project.reference_for_path("/tmp/SwiftPodsAdapter/Deps/Child.xcodeproj").equal?(reference), "Subproject discovery ignored its enclosing PBX group path")
  end

  def test_recursive_specs_are_not_duplicated
    spec = Pod::Spec.new("Kit")
    spec.subspec("Core") { }
    spec.test_spec("Tests") { }
    spec.app_spec("App") { }
    expected = %w[Kit/Core Kit/Tests Kit/App]
    assert(spec.recursive_subspecs.map(&:name) == expected, "Recursive specification order changed")
    assert(spec.recursive_subspecs(true).map(&:name) == expected, "Test and app specifications were traversed twice")
  end

  def test_spec_consumers_normalize_platform_names
    spec = Pod::Spec.new("Kit")
    spec.ios.deployment_target = "15.0"
    [:ios, "ios", Pod::Platform.new(:ios, "16.0")].each do |platform|
      consumer = spec.consumer(platform)
      assert(consumer.platform_name == :ios && consumer.deployment_target == "15.0", "Consumer platform identity differs for symbol/string/Platform inputs")
    end
  end

  def test_child_platform_declarations_inherit_the_parent_minimum
    spec = Pod::Spec.new("Kit")
    spec.ios.deployment_target = "15.0"
    child = spec.subspec("Core") { |value| value.platforms = ["ios"] }
    assert(child.deployment_target(:ios) == "15.0", "A child platform declaration erased the inherited deployment target")
    assert(child.available_platforms == [Pod::Platform.new(:ios, "15.0")], "Available platforms exposed a lower child deployment target")
    assert(child.consumer(:ios).deployment_target == "15.0", "Hook consumers missed the inherited deployment target")
  end

  def test_default_subspec_none_is_a_sentinel
    spec = Pod::Spec.new("Kit")
    spec.default_subspecs = :none
    assert(spec.default_subspecs == :none, "The default-subspec none sentinel became a dependency name")
  end

  def test_all_dependencies_include_selected_subspecs_without_their_transitive_dependencies
    spec = Pod::Spec.new("Kit")
    spec.version = "1.0"
    spec.dependency("Direct", "~> 1")
    spec.subspec("Core") { |child| child.dependency("Transitive", "~> 2") }
    spec.subspec("Optional") { }
    spec.test_spec("Tests") { }
    spec.default_subspecs = ["Core"]
    expected = [["Direct", "~> 1"], ["Kit/Core", "= 1.0"]]
    actual = spec.all_dependencies.map { |dependency| [dependency.name, dependency.requirement.to_s] }
    assert(actual == expected, "all_dependencies replaced immediate subspec edges with transitive external dependencies")
    spec.default_subspecs = :none
    assert(spec.all_dependencies.map(&:name) == ["Direct"], "No-default-subspec sentinel still introduced subspec dependencies")
  end

  def test_podfile_dependencies_retain_distinct_requirements
    podfile = SwiftPods::Podfile.new
    podfile.target("First") { pod "Kit", "~> 1" }
    podfile.target("Second") { pod "Kit", ">= 1.2" }
    assert(podfile.dependencies.map { |dependency| dependency.requirement.to_s }.sort == [">= 1.2", "~> 1"], "Podfile.dependencies discarded one target requirement")
  end

  def test_dependency_objects_retain_external_source_metadata
    podfile = SwiftPods::Podfile.new
    podfile.target("App") do
      pod "ArchiveKit", http: "https://example.org/Kit.zip", sha256: "abc", headers: { "Authorization" => "fixture" }, inhibit_warnings: true
      pod "SVNKit", svn: "https://example.org/svn/Kit", revision: "42"
      pod "HGKit", hg: "https://example.org/hg/Kit", revision: "tag"
    end
    dependencies = podfile.analyzed_target_definitions.first.dependencies
    archive, svn, hg = dependencies
    assert(archive.external_source == { http: "https://example.org/Kit.zip", sha256: "abc", headers: { "Authorization" => "fixture" } }, "Hook dependency omitted HTTP source options or included build-only options")
    assert(svn.external_source == { svn: "https://example.org/svn/Kit", revision: "42" }, "Hook dependency omitted Subversion source options")
    assert(hg.external_source == { hg: "https://example.org/hg/Kit", revision: "tag" }, "Hook dependency omitted Mercurial source options")
    assert(podfile.dependencies == dependencies, "Podfile and target dependency objects expose different sources")
  end

  def test_plugin_options_preserve_indifferent_access_after_mutation
    options = SwiftPods::PluginOptions.new("enabled" => true, "nested" => [{ "name" => "before" }])
    options[:enabled] = false
    options[:added] = { value: "after" }
    assert(options["enabled"] == false, "A symbol assignment created a second hidden plugin option")
    assert(options[:added]["value"] == "after", "An assigned nested plugin option lost indifferent access")
    assert(options["nested"].first[:name] == "before", "Plugin options inside arrays lost indifferent access")
    options.update(enabled: true)
    assert(options["enabled"] == true && options.include?(:enabled), "Updated plugin options used inconsistent keys")
    assert(options.delete(:enabled) == true && !options.key?("enabled"), "Deleting a plugin option left its string key behind")
  end

  def test_invalid_lockfile_reports_input_error
    Dir.mktmpdir("swiftpods-ruby-lock-") do |directory|
      path = File.join(directory, "Podfile.lock")
      File.write(path, "PODS:\n  - invalid-entry\n")
      begin
        Pod::Lockfile.from_file(path).versions
        raise "Malformed lockfile was accepted"
      rescue Pod::Informative => error
        assert(error.message.include?("invalid-entry"), "Malformed lockfile error omitted the input entry")
      end
    end
  end

  def test_protocol_serializes_cached_json_podspecs_without_evaluating_json_as_ruby
    Dir.mktmpdir("swiftpods-ruby-json-cache-") do |directory|
      spec = { "name" => "JSONKit", "version" => "1.2.3", "source_files" => "Sources/*.swift",
               "subspecs" => [{ "name" => "Core", "resources" => ["Assets/*.xcassets"] }] }
      path = File.join(directory, Digest::SHA256.hexdigest(JSON.generate(spec)) + ".podspec.json")
      File.write(path, JSON.generate(spec))
      requests = [{ "operation" => "spec", "path" => path }, { "operation" => "spec_serialization", "path" => path }]
      output, errors, status = Open3.capture3(
        RbConfig.ruby, File.expand_path("../Runtime/dsl.rb", __dir__),
        stdin_data: requests.map { |request| JSON.generate(request) }.join("\n") + "\n",
      )
      parsed = output.lines.map { |line| JSON.parse(line) }
      assert(status.success? && parsed.size == 2 && parsed.all? { |response| response["ok"] }, "JSON cache serialization failed: #{errors} #{parsed.inspect}")
      serialized = JSON.parse(parsed.last["value"]["json"])
      assert(serialized["name"] == "JSONKit" && serialized["subspecs"].first["resources"] == ["Assets/*.xcassets"], "JSON cache projection lost nested specification values")
    end
  end

  def test_protocol_reports_user_errors_without_corrupting_json_output
    Dir.mktmpdir("swiftpods-ruby-errors-") do |directory|
      sources = ["target 'Broken' do\n", "exit 7\n", "puts 'helper-output'\nunknown_manifest_operation\n"]
      requests = sources.each_with_index.map do |source, index|
        path = File.join(directory, "#{index}.Podfile")
        File.write(path, source)
        JSON.generate("operation" => "podfile", "path" => path)
      end
      output, errors, status = Open3.capture3(
        RbConfig.ruby, File.expand_path("../Runtime/dsl.rb", __dir__),
        stdin_data: requests.join("\n") + "\n",
      )
      parsed = output.lines.map { |line| JSON.parse(line) }
      assert(status.success? && parsed.size == 3 && parsed.none? { |response| response["ok"] }, "A user error killed the protocol or reported false success")
      assert(parsed.map { |response| response["class"] } == ["SyntaxError", "SystemExit", "NameError"], "User errors lost their exception classes")
      assert(errors.include?("helper-output") && !output.include?("helper-output"), "User stdout corrupted JSON protocol messages")
      assert(parsed.last["backtrace"].first.include?("2.Podfile:2"), "Adapter diagnostics lost the user source location")
    end
  end

  def test_protocol_manifest_helpers_and_hook_closures_remain_isolated
    Dir.mktmpdir("swiftpods-ruby-protocol-") do |directory|
      manifest = File.join(directory, "Podfile")
      File.write(manifest, <<~PODFILE)
        project = 1
        installer = 2
        request = 3
        inputs = 4
        result = 5
        platform :osx, '13.0'
        target 'App' do
          pod 'Kit', '~> 1'
          spm 'SwiftKit', :url => 'https://example.org/SwiftKit.git', :from => '1.0'
        end
        post_install do |installer|
          raise 'User lexical scope changed' unless [project, request, inputs, result] == [1, 3, 4, 5]
          installer.pods_project.main_group.new_file('Hook.swift')
        end
      PODFILE
      requests = [
        { "operation" => "podfile", "path" => manifest },
        { "operation" => "hook", "name" => "post_install", "project" => graph, "pod_targets" => [] },
        { "operation" => "unknown" },
      ].map { |value| JSON.generate(value) }.join("\n") + "\n"
      output, errors, status = Open3.capture3(RbConfig.ruby, File.expand_path("../Runtime/dsl.rb", __dir__), stdin_data: requests)
      assert(status.success?, "Adapter protocol process failed: #{errors}")
      parsed = output.lines.map { |line| JSON.parse(line) }
      assert(parsed.size == 3 && parsed.first["ok"] && parsed[1]["ok"], "Protocol failed: #{parsed.inspect}")
      assert(parsed.first["value"]["targets"].first["packages"].first["name"] == "SwiftKit", "The SPM declaration did not survive protocol serialization")
      assert(parsed[1]["value"]["graph"]["objects"].values.any? { |entry| entry["path"] == "Hook.swift" }, "A live hook mutation did not reach Swift")
      assert(parsed.last["ok"] == false && parsed.last["class"] == "SwiftPods::Unsupported", "Unknown protocol operations lost their explicit error")
    end
  end

  def run
    tests = public_methods(false).grep(/^test_/).sort
    failures = tests.filter_map do |test|
      public_send(test)
      nil
    rescue StandardError => error
      "#{test}: #{error.class}: #{error.message}"
    end
    failures.each { |message| warn message }
    abort "#{failures.length}/#{tests.length} Ruby adapter regressions failed" unless failures.empty?
    puts "#{tests.length} Ruby adapter regressions passed"
  end
end

RubyAdapterRegressions.new.run if $PROGRAM_NAME == __FILE__
