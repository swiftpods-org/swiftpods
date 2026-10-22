#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone regressions for the public Ruby adapter. No test gems are required.
require "tmpdir"
require "open3"
require "rbconfig"
require "yaml"
require "set"
require_relative "../../Runtime/runtime"
require_relative "../../Runtime/session"

class RubyAdapterRegressions
  def test_analyzed_extension_safety_survives_the_dsl_session
    podfile = SwiftPods::Podfile.new
    podfile.target("Demo") {}
    session = SwiftPods::Session.new
    session.instance_variable_set(:@podfile, podfile)
    target = podfile.to_hash.fetch("targets").first.merge("application_extension_api_only" => true)
    result = session.dispatch("operation" => "analyzed_podfile", "targets" => [target])
    assert(result.fetch("targets").first["application_extension_api_only"] == true, "Extension safety was lost after analysis")
  end

  def test_yaml_booleans_reject_strings_numbers_and_collections
    invalid = ["false", "true", 0, 1, [], {}]
    invalid.each do |value|
      [
        { "set_arc_compatibility_flag" => value },
        { "generate_bridge_support" => value },
        { "target_definitions" => [{ "name" => "Demo", "abstract" => value }] },
        { "target_definitions" => [{ "name" => "Demo", "inhibit_warnings" => { "all" => value } }] },
        { "target_definitions" => [{ "name" => "Demo", "use_modular_headers" => { "all" => value } }] },
      ].each do |input|
        begin
          SwiftPods::Podfile.new.import_yaml(input)
          raise "Invalid YAML boolean was accepted: #{input.inspect}"
        rescue SwiftPods::Unsupported
          nil
        end
      end
    end
  end

  def test_yaml_false_flags_preserve_boolean_semantics
    podfile = SwiftPods::Podfile.new
    podfile.import_yaml("set_arc_compatibility_flag" => false, "generate_bridge_support" => false,
                        "target_definitions" => [{ "name" => "Demo", "abstract" => false, "inhibit_warnings" => { "all" => false }, "use_modular_headers" => { "all" => false } }])
    manifest = podfile.to_hash
    assert(!manifest["set_arc_compatibility_flag"] && !manifest["generate_bridge_support"], "False YAML flags were enabled")
    target = manifest.fetch("targets").first
    assert(target && target["inhibit_warnings"] == false && target["modular_headers"] == false, "False target flags were changed")
  end

  def test_yaml_podfile_uses_the_same_inherited_declarations_as_ruby
    value = {
      "installation_method" => { "name" => "swiftpods", "options" => { "integrate_targets" => false } },
      "target_definitions" => [{ "name" => "Pods", "abstract" => true, "platform" => { "osx" => "13.0" },
                                 "build_configurations" => { "Staging" => "debug" },
                                 "inhibit_warnings" => { "for_pods" => ["ChildKit"] },
                                 "configuration_pod_whitelist" => { "Staging" => ["ChildKit"] },
                                 "uses_frameworks" => { "linkage" => "static", "packaging" => "framework" },
                                 "dependencies" => [{ "Kit" => ["~> 1.0", { "path" => "./Kit" }] }],
                                 "children" => [{ "name" => "Demo", "user_project_path" => "App.xcodeproj", "dependencies" => ["ChildKit"] }] }],
    }
    Dir.mktmpdir("yaml-podfile-") do |root|
      path = File.join(root, "CocoaPods.podfile.yaml")
      File.write(path, YAML.dump(value))
      podfile = SwiftPods::Podfile.new
      podfile.evaluate_file(path)
      manifest = podfile.to_hash
      assert(manifest["options"]["integrate_targets"] == false, "YAML installation options were lost")
      target = manifest.fetch("targets").first
      assert(manifest["targets"].length == 1 && target["label"] == "Pods-Demo", "YAML abstract root changed target identity")
      assert(target["platform"] == { "name" => "osx", "deployment_target" => "13.0" } && target["frameworks"] == "static", "YAML inheritance changed")
      assert(target["dependencies"].find { |entry| entry["name"] == "Kit" } == { "name" => "Kit", "requirements" => ["~> 1.0"], "options" => { "path" => "./Kit" } }, "YAML dependency changed")
      child = target["dependencies"].find { |entry| entry["name"] == "ChildKit" }
      assert(child["options"] == { "inhibit_warnings" => true, "configurations" => ["Staging"] }, "YAML per-pod rules did not inherit")
      assert(target["configurations"] == { "Staging" => "debug" }, "YAML configuration mapping without a project was lost")
    end
  end

  def test_yaml_podfile_rejects_unknown_fields_and_executable_object_tags
    rejected = false
    begin
      SwiftPods::Podfile.new.import_yaml("unrecognized" => true)
    rescue SwiftPods::Unsupported
      rejected = true
    end
    assert(rejected, "Unknown YAML declarations silently succeeded")
    Dir.mktmpdir("yaml-podfile-") do |root|
      path = File.join(root, "CocoaPods.podfile.yaml")
      File.write(path, "--- !ruby/object:Object {}\n")
      rejected = false
      begin
        SwiftPods::Podfile.new.evaluate_file(path)
      rescue Psych::DisallowedClass
        rejected = true
      end
      assert(rejected, "YAML object tags were accepted")
    end
  end

  def test_specification_metadata_getters_use_public_key_types_without_mutating_raw_data
    raw = { "name" => "Kit", "license" => { "type" => "MIT", "text" => "    hello\n    world\n" },
            "source" => { "git" => "fixture.git", "tag" => 1.0 } }
    spec = Pod::Spec.from_hash(raw)
    assert(spec.source[:git] == "fixture.git" && spec.source[:tag].is_a?(Float), "Source getter lost symbol keys or numeric type")
    assert(spec.license == { type: "MIT", text: "hello\nworld\n" }, "License getter lost keys or text normalization")
    assert(spec.attributes_hash["source"]["tag"].is_a?(Float), "Source getter rewrote raw attributes")
    assert(spec.attributes_hash["license"]["text"].start_with?("    "), "License getter rewrote raw text")
  end

  def test_consumer_metadata_preserves_root_value_objects_and_defaults
    root = Pod::Spec.from_hash({ "name" => "Kit", "version" => "1.0", "swift_versions" => ["5", "6"],
                                 "authors" => ["A", { "B" => "mail" }], "screenshots" => "image", "deprecated_in_favor_of" => "Other" })
    child = root.subspec("Core") { }
    consumer = child.consumer(:osx)
    assert(consumer.version.is_a?(Pod::Version) && consumer.swift_versions.all? { |v| v.is_a?(Pod::Version) }, "Consumer lost version value objects")
    assert(consumer.authors == { "A" => nil, "B" => "mail" } && consumer.screenshots == ["image"], "Consumer lost normalized metadata")
    assert(consumer.deprecated? && consumer.base_name == "Kit", "Consumer lost root metadata")
    empty = Pod::Spec.new("Empty")
    assert(empty.license == {} && empty.screenshots == [] && empty.authors.nil? && empty.static_framework.nil?, "Unset root getter defaults differ")
  end

  def test_consumer_checks_platform_compatibility_and_keeps_object_identity
    spec = Pod::Spec.from_hash({ "name" => "Kit", "platforms" => { "osx" => "13.0" } })
    rejected = false
    begin
      spec.consumer(:ios)
    rescue StandardError
      rejected = true
    end
    assert(rejected && !spec.supported_on_platform?(:ios), "Consumer accepted an unsupported platform")
    assert(!spec.supported_on_platform?(Pod::Platform.new(:osx, "12.0")), "Platform support ignored deployment minima")
    first = spec.consumer(:osx)
    assert(first.equal?(spec.consumer("osx")), "Consumer identity changes between equivalent requests")
    assert(first.equal?(spec.consumer(Pod::Platform.new(:osx, "12.0"))), "Specification consumer should select platform metadata by name")
  end

  def test_module_identity_normalizes_header_directories_and_keeps_explicit_names
    { "Kit--Core" => "Kit_Core", "1__Kit" => "_1_Kit" }.each do |name, expected|
      assert(Pod::Spec.from_hash("name" => name).module_name == expected, "Derived module normalization differs")
    end
    spec = Pod::Spec.from_hash("name" => "Kit", "header_dir" => "Custom--Kit", "subspecs" => [{ "name" => "Core" }])
    assert(spec.module_name == "Custom_Kit" && spec.subspecs.first.module_name == "Custom_Kit", "Header directory or root identity was not normalized")
    spec.module_name = "_Kit__Core"
    assert(spec.module_name == "_Kit__Core", "Explicit module identifier changed")
  end

  def test_module_identifiers_transliterate_fixed_latin_characters_without_runtime_gems
    { "École" => "Ecole", "Straße" => "Strasse", "Æther-Œuvre" => "AEther_OEuvre", "Łódź" => "Lodz", "ĐÞĲŊŉ×ẞ" => "DThIJNG_nxSS", "東京" => "_", "E\u0301cole" => "E_cole" }.each do |input, expected|
      spec = Pod::Spec.from_hash("name" => "Kit", "header_dir" => input)
      assert(spec.module_name == expected, "Module identity differs for #{input}")
    end
  end

  def test_json_and_ruby_ui_types_share_symbols_and_the_generated_target_label
    target = Pod::PodTarget.allocate
    target.instance_variable_set(:@name, "Kit")
    ["ui", :ui].each do |type|
      root = Pod::Spec.from_hash("name" => "Kit", "testspecs" => [{ "name" => "UI", "test_type" => type }])
      spec = root.test_specs.first
      assert(spec.test_type == :ui && spec.consumer(:osx).test_type == :ui, "UI type was not normalized")
      assert(target.test_target_label(spec) == "Kit-UI-UI", "UI label differs from its generated target")
    end
    unit = Pod::Spec.from_hash("name" => "Kit", "testspecs" => [{ "name" => "Tests" }]).test_specs.first
    assert(unit.test_type == :unit && target.test_target_label(unit) == "Kit-Unit-Tests", "Default unit type was lost")
  end

  def test_none_inheritance_keeps_own_dependencies_and_ignores_parent_configurations
    podfile = SwiftPods::Podfile.new
    podfile.target("Parent") do
      pod "Inherited"
      pod "Kit", configurations: ["Debug"]
      target "Child" do
        inherit! :none
        pod "Kit"
        pod "Own", configurations: ["Release"]
      end
    end
    child = podfile.to_hash.fetch("targets").find { |target| target["name"] == "Child" }
    dependencies = child.fetch("dependencies")
    assert(dependencies.map { |dependency| dependency["name"] } == %w[Kit Own], "Parent dependencies leaked through none inheritance")
    assert(!dependencies.first["options"].key?("configurations"), "Own dependency inherited a configuration whitelist")
    assert(dependencies.last["options"]["configurations"] == ["Release"], "Own explicit configurations were lost")
  end

  def test_search_path_inheritance_builds_packages_without_linking_them_into_plugins
    podfile = SwiftPods::Podfile.new
    podfile.target("App") do
      pod "PodSDK"
      spm "PackageSDK", git: "https://example.invalid/package.git", exact: "1.0.0", products: ["SDK"]
      target "Plugin" do
        inherit! :search_paths
      end
      target "Tests" do
        inherit! :complete
      end
      target "Extension" do
        inherit! :none
      end
    end
    targets = podfile.to_hash.fetch("targets").to_h { |target| [target["name"], target] }
    plugin = targets.fetch("Plugin")
    assert(plugin.fetch("dependencies").empty?, "Search-only plugin links its parent's pods")
    assert(plugin.fetch("search_dependencies").first["name"] == "PodSDK", "Plugin lost pod search paths")
    assert(plugin.fetch("packages").first["link"] == false, "Plugin links an inherited Swift package")
    assert(!targets.fetch("App").fetch("packages").first.key?("link"), "Inheritance mutated the app's package")
    assert(!targets.fetch("Tests").fetch("packages").first.key?("link"), "Complete inheritance lost package linking")
    assert(targets.fetch("Extension").fetch("packages").empty?, "Packages leaked through none inheritance")
  end

  def test_compatible_specification_dsl_require_does_not_load_an_external_engine
    feature = "cocoapods-core/specification/dsl"
    require feature
    assert(require(feature) == false, "Repeated compatibility import changed require semantics")
    assert(!$LOADED_FEATURES.any? { |path| path.end_with?(feature + ".rb") }, "Compatibility import loaded an external implementation")
    assert(Pod::Spec.new("Kit").respond_to?(:source_files=), "Specification DSL is unavailable")
  end

  def test_platform_normalizes_constructor_arguments_without_losing_deployment
    platform = Pod::Platform.new(:osx, "13.0")
    copy = Pod::Platform.new(platform)
    assert(copy == platform && !copy.equal?(platform), "Platform copy changed its value")
    assert(copy.deployment_target.equal?(platform.deployment_target), "Platform copy replaced its deployment")
    assert(Pod::Platform.new("macOS", "13.0") == platform, "macOS alias was not normalized")
    assert(Pod::Platform.new("xrOS").name == :visionos, "xrOS alias was not normalized")
    assert(Pod::Platform.new("IOS", deployment_target: "14.0") == Pod::Platform.new(:ios, "14.0"), "Deployment hash was ignored")
    assert(Pod::Platform.new(:ios, {}).deployment_target.nil?, "Empty deployment hash acquired a version")
  end

  def test_platform_support_checks_accept_names_and_preserve_version_boundaries
    platform = Pod::Platform.new(:osx, "13.0")
    assert(platform.supports?(:osx) && platform.supports?("macos"), "Platform name support failed")
    assert(!platform.supports?(:ios), "Different platform was accepted")
    assert(platform.supports?(Pod::Platform.new(:osx, "12.0")), "Older deployment was rejected")
    assert(!platform.supports?(Pod::Platform.new(:osx, "14.0")), "Newer deployment was accepted")
    assert(Pod::Platform.new(:osx).supports?(platform), "Unspecified deployment rejected the platform")
  end

  def test_sandbox_subspec_lookups_use_the_same_root_objects
    sandbox = Pod::Sandbox.new("/tmp/Pods")
    spec = Pod::Spec.new("Kit")
    sandbox.directories["Kit"] = "/tmp/LocalKit"
    sandbox.specifications["Kit"] = spec
    assert(sandbox.pod_dir("Kit/Core") == sandbox.pod_dir("Kit"), "Subspec directory ignored its local root")
    assert(sandbox.specification("Kit/Core").equal?(spec), "Subspec specification lost root identity")
    assert(sandbox.pod_dir("Remote/Core").to_s == "/tmp/Pods/Remote", "Remote subspec retained its suffix")
    assert(sandbox.specification("KitA/Core").nil?, "Unrelated root matched a name prefix")
  end

  def test_platform_symbol_comparison_does_not_change_hash_equality
    platform = Pod::Platform.new(:osx, "13.0")
    other = Pod::Platform.new(:osx, "13.0.0")
    assert(platform == :osx && platform != :ios, "Platform Symbol comparison failed")
    assert(platform == other && platform.eql?(other) && platform.hash == other.hash, "Equal platform keys disagree")
    assert(!platform.eql?(:osx) && !:osx.eql?(platform), "Platform hash equality is asymmetric with Symbols")
    assert({ platform => :found }[other] == :found, "Equivalent platform hash lookup failed")
    assert([platform, :osx].permutation.all? { |keys| keys.to_h { |key| [key, true] }.length == 2 }, "Platform and Symbol keys collapsed")
  end

  def test_lockfile_root_version_lookup_preserves_subspec_names
    lockfile = Pod::Lockfile.new("PODS" => [{ "Kit/Core (1.0)" => ["Other"] }, "Kit/UI (1.0)", "KitA (2.0)"])
    assert(lockfile.version("Kit").to_s == "1.0", "Root version lookup missed installed subspecs")
    assert(lockfile.version("Kit/Core").to_s == "1.0", "Exact subspec lookup changed")
    assert(lockfile.version("KitA").to_s == "2.0", "Root names were matched by prefix")
    assert(lockfile.version("Ki").nil? && lockfile.version("Kit/Missing").nil?, "Missing dependency acquired another version")
    assert(lockfile.pod_names == %w[Kit/Core Kit/UI KitA], "Version lookup changed locked pod names")
    exact = Pod::Lockfile.new("PODS" => ["Kit/Core (1.0)", "Kit (2.0)"])
    assert(exact.version("Kit").to_s == "2.0", "Subspec fallback replaced an exact match")
  end

  def test_version_hash_equality_is_symmetric_and_semantic
    version = Pod::Version.new("1.0")
    assert(version == "1.0", "Friendly string comparison changed")
    assert(!version.eql?("1.0") && !"1.0".eql?(version), "Hash equality is asymmetric with strings")
    assert(!version.eql?(nil) && !version.eql?(Gem::Version.new("1.0")), "Hash equality accepts another key type")
    equivalents = [version, Pod::Version.new("1.0.0"), Pod::Version.new("1.0+build.7")]
    equivalents.each do |other|
      assert(version.eql?(other) && other.eql?(version) && version.hash == other.hash, "Equivalent versions disagree as hash keys")
      assert({ version => :found }[other] == :found && { other => :found }[version] == :found, "Equivalent version lookup failed")
    end
    assert(Set.new(equivalents).length == 1, "Equivalent versions are separate set members")
    ["1.0", version].permutation.each do |keys|
      assert(keys.to_h { |key| [key, key] }.length == 2, "String and version keys collapse in one insertion order")
    end
  end

  def test_prerelease_comparison_matches_native_requirements
    alpha = Pod::Version.new("1.0.0-alpha")
    zero = Pod::Version.new("1.0.0-alpha.0")
    assert(alpha < zero && alpha != zero, "Significant prerelease zero was removed")
    assert([alpha, zero].uniq.length == 2, "Prerelease hashing collapsed different versions")
    assert(!Pod::Requirement.new("= 1.0.0-alpha.0").satisfied_by?(alpha), "Wrong exact prerelease was accepted")
    assert(Pod::Version.new("1.0.0-alpha.2") < Pod::Version.new("1.0.0-alpha.beta"), "Numeric prerelease sorted above text")
    assert(alpha == Pod::Version.new("1.0.alpha+build.7"), "Equivalent prerelease spellings disagree")
    assert(Pod::Version.new("1.0.0-1") < alpha && Pod::Version.new("1.0.0-1").prerelease?, "Numeric prerelease was lost")
    assert(Pod::Version.new("1.0.0-1").release == Pod::Version.new("1.0.0"), "Wrong numeric prerelease release")
    assert(Pod::Requirement.new("~> 1.2.3-alpha.0").satisfied_by?(Pod::Version.new("1.2.9")), "Pessimistic requirement changed")
    assert(!Pod::Requirement.new("~> 1.2.3-alpha.0").satisfied_by?(Pod::Version.new("1.3.0-alpha")), "Upper prerelease was accepted")
  end

  def test_version_and_requirement_serialization_preserve_spelling_and_behavior
    yaml_loader = YAML.respond_to?(:unsafe_load) ? :unsafe_load : :load
    ["1.2.3", "1.2.3+build.7", "1.2.3-alpha-beta", "1.2.3-alpha.0", "1.2.3-1"].each do |spelling|
      version = Pod::Version.new(spelling)
      requirement = Pod::Requirement.new("= " + spelling)
      [Marshal.load(Marshal.dump(version)), YAML.public_send(yaml_loader, YAML.dump(version))].each do |restored|
        assert(restored.to_s == spelling && restored.version == spelling, "Version spelling was lost after serialization")
        assert(restored.prerelease? == version.prerelease? && restored == version, "Restored version behavior changed")
        assert([version, restored.freeze].uniq.length == 1, "Restored version hash changed")
        assert(requirement.satisfied_by?(restored), "Restored version failed its exact requirement")
      end
      [Marshal.load(Marshal.dump(requirement)), YAML.public_send(yaml_loader, YAML.dump(requirement))].each do |restored|
        assert(restored.to_s == requirement.to_s && restored.satisfied_by?(version), "Nested requirement serialization changed")
      end
    end
    version = Pod::Version.new("9.0")
    version.send(:yaml_initialize, nil, { "version" => "1.2.3-alpha.0" })
    assert(version == Pod::Version.new("1.2.3-alpha.0"), "YAML restoration retained stale comparison data")
  end

  def test_versions_and_dependency_requirements_accept_build_metadata
    version = Pod::Version.new("1.2.3+build.7")
    assert(version.to_s == "1.2.3+build.7", "Build metadata was lost")
    assert(!version.prerelease? && version == Pod::Version.new("1.2.3+other"), "Metadata affects version precedence")
    assert([version, Pod::Version.new("1.2.3+other")].uniq.length == 1, "Metadata breaks version hashing")
    dependency = Pod::Dependency.new("Kit", "= 1.2.3+build.7")
    assert(dependency.requirement.satisfied_by?(version), "Metadata requirement was rejected")
    assert(Pod::Requirement.new("~> 1.2.3+build.7").satisfied_by?(Pod::Version.new("1.2.9")), "Metadata changed pessimistic precision")
    prerelease = Pod::Version.new("1.2.3-alpha-beta")
    assert(prerelease.to_s == "1.2.3-alpha-beta" && prerelease.prerelease? && prerelease < version, "Compound prerelease was lost")
  end

  def test_project_directory_controls_group_and_source_root_paths
    value = graph
    value["graph"]["objects"]["ROOT"]["projectDirPath"] = "ActualRoot"
    project = Xcodeproj::Project.new(value)
    assert(project.object("FILE").real_path.to_s == "/tmp/SwiftPodsAdapter/ActualRoot/Value.swift", "projectDirPath ignored")
    reference = project.new_file("Standalone.swift", "SOURCE_ROOT")
    assert(reference.real_path.to_s == "/tmp/SwiftPodsAdapter/ActualRoot/Standalone.swift", "SOURCE_ROOT ignored projectDirPath")
  end

  def test_subspec_mutations_change_serialized_dependencies
    spec = Pod::Spec.from_hash("name" => "Kit", "subspecs" => [{ "name" => "Core" }])
    children = spec.subspecs
    optional = spec.subspec("Optional") { |child| child.dependency "Unwanted", "~> 1" }
    spec.test_spec("Tests") { }
    assert(children.include?(optional), "Captured subspec collection became detached")
    children.delete_if { |child| child.name.end_with?("/Optional") }
    assert(spec.to_hash["subspecs"].map { |child| child["name"] } == ["Core"], "Deleted subspec was serialized")
    assert(spec.to_hash["testspecs"].first["name"] == "Tests", "Library mutation discarded a test spec")
    assert(spec.subspec_dependencies.map(&:name) == ["Kit/Core"], "Deleted subspec still contributes dependencies")
    children.clear
    assert(!spec.to_hash.key?("subspecs") && !spec.to_hash.key?("testspecs"), "Cleared children survived serialization")
  end

  def test_public_source_phase_and_duplicate_file_policy
    project = Xcodeproj::Project.new(graph)
    target = project.new_object("PBXNativeTarget", "name" => "Kit", "buildPhases" => [])
    phase = target.source_build_phase
    assert(phase.equal?(target.sources_build_phase), "Source phase aliases created separate phases")
    file = project.object("FILE")
    first = phase.add_file_reference(file, true)
    assert(phase.add_file_reference(file, true).equal?(first), "avoid_duplicates created another build file")
    target.add_file_references([file])
    assert(phase.files.length == 1, "Target file insertion duplicated an existing source")
    phase.add_file_reference(file, false)
    assert(phase.files.length == 2, "Explicit duplicate insertion was suppressed")
  end

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
        RbConfig.ruby, File.expand_path("../../Runtime/dsl.rb", __dir__),
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
        RbConfig.ruby, File.expand_path("../../Runtime/dsl.rb", __dir__),
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
      output, errors, status = Open3.capture3(RbConfig.ruby, File.expand_path("../../Runtime/dsl.rb", __dir__), stdin_data: requests)
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
    failures = tests.map do |test|
      public_send(test)
      nil
    rescue StandardError, ScriptError => error
      "#{test}: #{error.class}: #{error.message}"
    end.compact
    failures.each { |message| warn message }
    abort "#{failures.length}/#{tests.length} Ruby adapter regressions failed" unless failures.empty?
    puts "#{tests.length} Ruby adapter regressions passed"
  end
end

RubyAdapterRegressions.new.run if $PROGRAM_NAME == __FILE__
