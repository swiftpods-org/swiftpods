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
        update_sources: '--update-sources', allow_external_file_lists: '--allow-external-file-lists'
      }.freeze

      def self.run(params)
        podfile = File.expand_path(params[:podfile])
        podfile = File.join(podfile, 'Podfile') if File.directory?(podfile)
        UI.user_error!("Podfile not found: #{podfile}") unless File.file?(podfile)
        UI.user_error!('SwiftPods requires a file named Podfile') unless File.basename(podfile) == 'Podfile'

        directory = File.dirname(podfile)
        arguments = ['install', '--project-directory', directory]
        FLAGS.each { |key, flag| arguments << flag if params[key] }

        if params[:executable]
          executable = params[:executable]
          executable = File.expand_path(executable) if executable.include?(File::SEPARATOR)
          sh(executable, *arguments)
          dependencies(executable, directory)
        else
          executable = Fastlane::Swiftpods::Executable.new
          run_pinned(executable, arguments, offline: params[:offline], emit_stdout: true)
          dependencies(executable, directory)
        end
      end

      # Reads the Podfile from the catalogs the install just cached.
      def self.dependencies(executable, directory)
        arguments = ['check', '--project-directory', directory, '--offline', '--json']
        if executable.is_a?(String)
          output, errors, status = Open3.capture3(executable, *arguments)
          UI.user_error!("swiftpods check failed (#{status.exitstatus}): #{errors.strip}") unless status.success?
        else
          output = run_pinned(executable, arguments, offline: true, emit_stdout: false)
        end
        Fastlane::Swiftpods::Dependencies.new(JSON.parse(output))
      end

      def self.run_pinned(executable, arguments, offline:, emit_stdout:)
        output, errors, status = executable.run(arguments, offline: offline)
        UI.message(output.rstrip) if emit_stdout && !output.empty?
        UI.important(errors.rstrip) unless errors.empty?
        unless status.success?
          detail = errors.empty? ? output : errors
          UI.user_error!("swiftpods #{arguments.first} failed (#{status.exitstatus}): #{detail.strip}")
        end
        output
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(
            key: :podfile, env_name: 'SWIFTPODS_PODFILE', description: 'Path to the Podfile or its directory',
            type: String, default_value: 'Podfile'
          ),
          FastlaneCore::ConfigItem.new(
            key: :executable, env_name: 'SWIFTPODS_EXECUTABLE',
            description: 'Explicitly trusted SwiftPods executable to use instead of the pinned release',
            type: String, optional: true
          ),
          option(:deployment, 'Require Package.resolved and any catalog-backed SwiftPods.lock to satisfy the Podfile'),
          option(:resolve, 'Resolve packages with Xcode afterwards and check the result'),
          option(:adopt, 'Manage package references that were added without SwiftPods'),
          option(:offline, 'Use verified cached binary archives, catalogs and pinned CLI only'),
          option(:update_sources, 'Fetch the latest catalogs first (deployment remains frozen)'),
          option(:allow_external_file_lists, 'Trust script file lists outside the Podfile directory')
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
