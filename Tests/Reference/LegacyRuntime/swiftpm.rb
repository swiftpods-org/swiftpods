# frozen_string_literal: true

require 'uri'

module SwiftPods
  module SwiftPM
    def self.identity(url)
      File.basename(url.to_s.sub(%r{/+\z}, ''), '.git').downcase
    end

    def self.version(value)
      text = value.to_s
      pattern = /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z/
      match = text.match(pattern)
      valid_prerelease = !match || !match[4] || match[4].split('.').none? { |part| part.match?(/\A0\d+\z/) }
      raise Failure.new('SP-SPM-VERSION', 'dsl', "Expected an explicit three-component SemVer, got #{value.inspect}") unless match && valid_prerelease
      text
    end

    def self.requirement(options)
      keys = options.keys & %i[exact from range branch revision]
      raise Failure.new('SP-SPM-REQUIREMENT', 'dsl', 'Specify exactly one of :exact, :from, :range, :branch or :revision') unless keys.length == 1
      value = options.fetch(keys.first)
      case keys.first
      when :exact then { 'kind' => 'exactVersion', 'version' => version(value) }
      when :from then { 'kind' => 'upToNextMajorVersion', 'minimumVersion' => version(value) }
      when :range
        raise Failure.new('SP-SPM-REQUIREMENT', 'dsl', ':range must be [inclusive_minimum, exclusive_maximum]') unless value.is_a?(Array) && value.length == 2
        minimum, maximum = value.map { |part| version(part) }
        raise Failure.new('SP-SPM-REQUIREMENT', 'dsl', 'Range endpoints must be ordered release versions') if [minimum, maximum].any? { |part| part.include?('-') || part.include?('+') } || (minimum.split('.').map(&:to_i) <=> maximum.split('.').map(&:to_i)) != -1
        { 'kind' => 'versionRange', 'minimumVersion' => minimum, 'maximumVersion' => maximum }
      when :branch
        raise Failure.new('SP-SPM-REQUIREMENT', 'dsl', 'Branch must be a nonempty string') unless value.is_a?(String) && !value.empty?
        { 'kind' => 'branch', 'branch' => value }
      when :revision
        raise Failure.new('SP-SPM-REQUIREMENT', 'dsl', 'Revision must be a full Git commit SHA') unless value.is_a?(String) && value.match?(/\A(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\z/)
        { 'kind' => 'revision', 'revision' => value }
      end
    end

    def self.declarations(podfile)
      podfile.instance_variable_get(:@swiftpods_spm) || []
    end

    def self.check_duplicates(installer)
      declarations = declarations(installer.podfile)
      options = installer.send(:installation_options)
      if !declarations.empty? && (!options.integrate_targets? || options.skip_pods_project_generation?)
        raise Failure.new('SP-SPM-INTEGRATION', 'resolve', 'Native SPM declarations require user-project integration')
      end
      mappings_path = installer.config.installation_root + '.swiftpods/SDKMappings.json'
      mappings = mappings_path.file? ? JSON.parse(mappings_path.read).fetch('mappings') : []
      installer.aggregate_targets.each do |aggregate|
        next unless aggregate.user_project
        declarations_for_target = declarations.select { |entry| entry['target'] == aggregate.target_definition.name }
        aggregate.user_targets.each do |target|
          products = target.package_product_dependencies.map do |product|
            package = product.package
            { 'product' => product.product_name, 'identity' => identity(package.respond_to?(:repositoryURL) ? package.repositoryURL : package&.relative_path) }
          end
          products += declarations_for_target.flat_map { |entry| entry['products'].map { |product| { 'product' => product, 'identity' => identity(entry['url']) } } }
          aggregate.pod_targets.each do |pod|
            modules = pod.specs.map(&:module_name).uniq
            pod.file_accessors.each do |accessor|
              accessor.vendored_frameworks.each do |framework|
                if framework.extname == '.xcframework'
                  info = Xcodeproj::Plist.read_from_path((framework + 'Info.plist').to_s)
                  Array(info['AvailableLibraries']).each do |library|
                    product = library['LibraryPath'].to_s
                    modules << File.basename(product, '.framework') if product.end_with?('.framework')
                  end
                else
                  modules << framework.basename('.framework').to_s
                end
              end
            end
            conflict = products.find do |product|
              modules.include?(product['product']) || mappings.any? { |mapping| mapping['pod'] == pod.pod_name && mapping['package'] == product['identity'] }
            end
            next unless conflict
            raise Failure.new('SP-DUPLICATE-SDK', 'resolve', "Target #{target.name} receives #{pod.pod_name} through CocoaPods and SPM product #{conflict['product']} (#{conflict['identity']}); remove or explicitly remap the overlapping dependency")
          end
        end
      end
    end

    def self.integrate(podfile, targets, root)
      declarations = declarations(podfile)
      state_path = root + '.swiftpods/spm.json'
      previous = state_path.file? ? JSON.parse(state_path.read).fetch('owned', []) : []
      return [] if declarations.empty? && previous.empty?
      touched = []
      owned = []
      resolved = []
      declarations.each do |entry|
        matching = targets.select { |aggregate| aggregate.target_definition.name == entry['target'] && aggregate.user_project }
        raise Failure.new('SP-SPM-TARGET', 'integration', "No integrated user target for SPM declaration #{entry['target']}") if matching.empty?
        matching.each do |aggregate|
          project = aggregate.user_project
          package = project.root_object.package_references.find { |candidate| candidate.respond_to?(:repositoryURL) && candidate.repositoryURL == entry['url'] }
          existing_owner = package && previous.find { |record| record['project'] == project.path.to_s && record['uuid'] == package.uuid && record['kind'] == 'package' }
          if package && package.requirement != entry['requirement']
            unless existing_owner && existing_owner['requirement'] == package.requirement
              raise Failure.new('SP-SPM-CONFLICT', 'integration', "Existing package #{entry['url']} has a different requirement; its external declaration was preserved")
            end
            package.requirement = entry['requirement']
          end
          unless package
            package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
            package.repositoryURL, package.requirement = entry['url'], entry['requirement']
            project.root_object.package_references << package
            existing_owner = true
          end
          owned << { 'project' => project.path.to_s, 'uuid' => package.uuid, 'kind' => 'package', 'requirement' => package.requirement } if existing_owner
          aggregate.user_targets.each do |target|
            entry['products'].each do |name|
              product = target.package_product_dependencies.find { |candidate| candidate.product_name == name && candidate.package == package }
              product_owned = product && previous.any? { |record| record['project'] == project.path.to_s && record['uuid'] == product.uuid }
              unless product
                product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
                product.package, product.product_name = package, name
                target.package_product_dependencies << product
                product_owned = true
              end
              owned << { 'project' => project.path.to_s, 'uuid' => product.uuid, 'kind' => 'product' } if product_owned
              build_file = target.frameworks_build_phase.files.find { |file| file.product_ref == product }
              build_owned = build_file && previous.any? { |record| record['project'] == project.path.to_s && record['uuid'] == build_file.uuid }
              unless build_file
                build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
                build_file.product_ref = product
                target.frameworks_build_phase.files << build_file
                build_owned = true
              end
              owned << { 'project' => project.path.to_s, 'uuid' => build_file.uuid, 'kind' => 'build_file' } if build_owned
            end
          end
          touched << project
          resolved << entry.merge('project' => project.path.to_s)
        end
      end
      previous.reject { |record| owned.any? { |current| current['project'] == record['project'] && current['uuid'] == record['uuid'] } }
              .sort_by { |record| { 'build_file' => 0, 'product' => 1, 'package' => 2 }.fetch(record['kind']) }.each do |record|
        project = targets.map(&:user_project).compact.find { |candidate| candidate.path.to_s == record['project'] }
        next unless project
        object = project.objects_by_uuid[record['uuid']]
        next unless object
        # An externally added product may now use a package we created.
        # Keep that shared package instead of removing the external reference.
        next if record['kind'] == 'package' && project.objects.any? { |candidate| candidate.respond_to?(:package) && candidate.package == object }
        object.remove_from_project
        touched << project
      end
      SwiftPods.emit('spm_state', 'schema_version' => 1, 'owned' => owned.uniq, 'declarations' => resolved.uniq,
                                  'resolver' => 'Xcode/SwiftPM', 'package_resolved' => 'owned by toolchain; not rewritten by the pod resolver')
      touched.uniq
    end
  end

  module SwiftPMDSL
    def spm(name, options = {})
      unless name.is_a?(String) && !name.empty? && options.is_a?(Hash) &&
             (options.keys - %i[git exact from range branch revision products]).empty? &&
             options[:git].is_a?(String) && !options[:git].empty? &&
             options[:products].is_a?(Array) && !options[:products].empty? &&
             options[:products].all? { |product| product.is_a?(String) && !product.empty? }
        raise Failure.new('SP-SPM-DECLARATION', 'dsl', 'spm needs a name, :git, an explicit requirement and nonempty :products')
      end
      raise Failure.new('SP-SPM-TARGET', 'dsl', 'Declare spm inside a concrete target; abstract-target inheritance is not inferred') if current_target_definition.abstract?
      declaration = { 'name' => name, 'url' => options[:git], 'target' => current_target_definition.name,
                      'products' => options[:products].uniq, 'requirement' => SwiftPM.requirement(options) }
      @swiftpods_spm ||= []
      if @swiftpods_spm.any? { |entry| entry['url'] == declaration['url'] && entry['requirement'] != declaration['requirement'] }
        raise Failure.new('SP-SPM-CONFLICT', 'dsl', 'One package cannot have multiple version requirements in this backend')
      end
      @swiftpods_spm << declaration unless @swiftpods_spm.include?(declaration)
    end
  end
  Pod::Podfile::DSL.prepend(SwiftPMDSL)

  module SwiftPMAnalysis
    def resolve_dependencies
      result = super
      SwiftPM.check_duplicates(self)
      result
    end
  end
  Pod::Installer.prepend(SwiftPMAnalysis)

  module SwiftPMIntegration
    def save_projects(projects)
      extra = SwiftPM.integrate(podfile, targets, installation_root)
      super((projects + extra).uniq)
    end
  end
  Pod::Installer::UserProjectIntegrator.prepend(SwiftPMIntegration)
end
