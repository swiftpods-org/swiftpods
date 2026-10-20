require 'fastlane/action'

module Fastlane
  module Actions
    class SwiftpodsAction < Action
      def self.run(params)
        podfile = File.expand_path(params[:podfile])
        podfile = File.join(podfile, 'Podfile') if File.directory?(podfile)
        UI.user_error!("Podfile not found: #{podfile}") unless File.file?(podfile)
        UI.user_error!('SwiftPods requires a file named Podfile') unless File.basename(podfile) == 'Podfile'

        executable = params[:executable]
        executable = File.expand_path(executable) if executable.include?(File::SEPARATOR)
        command = [executable, 'install']
        command << '--clean-install' if params[:clean_install]
        command << '--repo-update' if params[:repo_update]
        command << '--deployment' if params[:deployment]
        command << '--offline' if params[:offline]

        Dir.chdir(File.dirname(podfile)) do
          sh(*command)
        end
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(
            key: :podfile,
            env_name: 'SWIFTPODS_PODFILE',
            description: 'Path to the Podfile or its directory',
            type: String,
            default_value: 'Podfile'
          ),
          FastlaneCore::ConfigItem.new(
            key: :executable,
            env_name: 'SWIFTPODS_EXECUTABLE',
            description: 'SwiftPods executable path or command name',
            type: String,
            default_value: 'swiftpods'
          ),
          FastlaneCore::ConfigItem.new(
            key: :clean_install,
            description: 'Perform a clean dependency installation',
            is_string: false,
            default_value: false
          ),
          FastlaneCore::ConfigItem.new(
            key: :repo_update,
            description: 'Refresh dependency metadata before installation',
            is_string: false,
            default_value: false
          ),
          FastlaneCore::ConfigItem.new(
            key: :deployment,
            description: 'Install without changing the dependency lock',
            is_string: false,
            default_value: false
          ),
          FastlaneCore::ConfigItem.new(
            key: :offline,
            description: 'Install using cached dependencies only',
            is_string: false,
            default_value: false
          )
        ]
      end

      def self.description
        'Runs swiftpods install for the project'
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
        ['swiftpods(podfile: "./Podfile", clean_install: true, repo_update: true)']
      end
    end
  end
end
