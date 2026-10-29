module Fastlane
  module Swiftpods
    # What a Podfile declares, as `swiftpods check --json` reads it.
    class Dependencies
      attr_reader :packages, :binaries

      def initialize(manifest)
        @packages = manifest.fetch('packages').map { |package| package.fetch('name') }
        @binaries = manifest.fetch('binaries').map { |binary| binary.fetch('name') }
      end

      # Whether any target gets the package or binary SDK `name`; catalog names ignore case.
      def include?(name)
        (packages + binaries).any? { |declared| declared.casecmp?(name) }
      end
    end
  end
end
