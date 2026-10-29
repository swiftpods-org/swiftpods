require 'fastlane/action'
require 'json'
require 'open3'
require_relative '../helper/dependencies'
require_relative '../helper/executable'

module Fastlane
  module Actions
    class SwiftpodsAction < Action
      FLAGS = {
        deployment: '--deployment', resolve: '--resolve', adopt: '--adopt', offline: '--offline',
        update_sources: '--update-sources'
      }.freeze

      def self.run(params)
        podfile = File.expand_path(params[:podfile])
        podfile = File.join(podfile, 'Podfile') if File.directory?(podfile)
        UI.user_error!("Podfile not found: #{podfile}") unless File.file?(podfile)
        UI.user_error!('SwiftPods requires a file named Podfile') unless File.basename(podfile) == 'Podfile'

        executable = params[:executable]
        executable ||= Fastlane::Swiftpods::Executable.new.resolve(offline: params[:offline])
        executable = File.expand_path(executable) if executable.include?(File::SEPARATOR)
        command = [executable, 'install', '--project-directory', File.dirname(podfile)]
        FLAGS.each { |key, flag| command << flag if params[key] }
        sh(*command)
        dependencies(executable, File.dirname(podfile))
      end

      # Reads the Podfile from the catalogs the install just cached.
      def self.dependencies(executable, directory)
        output, errors, status = Open3.capture3(executable, 'check', '--project-directory', directory, '--offline', '--json')
        UI.user_error!("swiftpods check failed: #{errors.strip}") unless status.success?
        Fastlane::Swiftpods::Dependencies.new(JSON.parse(output))
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(
            key: :podfile, env_name: 'SWIFTPODS_PODFILE', description: 'Path to the Podfile or its directory',
            type: String, default_value: 'Podfile'
          ),
          FastlaneCore::ConfigItem.new(
            key: :executable, env_name: 'SWIFTPODS_EXECUTABLE',
            description: 'SwiftPods executable to use instead of the pinned release', type: String, optional: true
          ),
          option(:deployment, 'Require a committed Package.resolved that satisfies the Podfile'),
          option(:resolve, 'Resolve packages with Xcode afterwards and check the result'),
          option(:adopt, 'Manage package references that were added without SwiftPods'),
          option(:offline, 'Use cached binary archives and catalogs only'),
          option(:update_sources, 'Fetch the latest catalogs first')
        ]
      end

      def self.option(key, description)
        FastlaneCore::ConfigItem.new(key: key, description: description, is_string: false, default_value: false)
      end

      def self.description
        'Runs swiftpods install for the project'
      end

      def self.return_value
        'The packages and binary SDKs the Podfile declares; include?(name) tells whether any target gets one'
      end

      def self.authors
        ['SwiftPods']
      end

      def self.is_supported?(platform)
        [:ios, :mac].include?(platform)
      end

      def self.category
        :building
      end

      def self.example_code
        [
          'swiftpods(podfile: "./Podfile")',
          'swiftpods(podfile: "src/MyApp/Podfile", deployment: true)',
          'dependencies = swiftpods(podfile: "src/MyApp/Podfile")
          setup_ad_review if dependencies.include?("AppLovinSDK")'
        ]
      end
    end
  end
end
