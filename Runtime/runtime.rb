# frozen_string_literal: true

# Shared Ruby API for the manifest adapter and live hook objects.
require "json"
require "pathname"
require "digest"
require "yaml"
require "ostruct"
require "securerandom"

require_relative "support"
require_relative "options"
require_relative "specification"
require_relative "hooks"
require_relative "project"
require_relative "target_inheritance"
require_relative "podfile"
require_relative "helpers"
require_relative "values"
require_relative "models"
require_relative "target_definitions"
require_relative "file_accessor"
require_relative "installer"
require_relative "attributes"
