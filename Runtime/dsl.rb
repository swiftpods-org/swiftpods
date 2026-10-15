# frozen_string_literal: true

# Executable protocol entry point. Domain APIs are independently loadable.
require_relative "runtime"
require_relative "session"

SwiftPods::Session.new.run
