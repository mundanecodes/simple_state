# frozen_string_literal: true

require_relative "lib/lite_state/version"

Gem::Specification.new do |spec|
  spec.name = "lite_state"
  spec.version = LiteState::VERSION
  spec.authors = ["charles chuck"]
  spec.email = ["chalcchuck@gmail.com"]

  spec.summary = "A lightweight state machine for ActiveRecord models with guards, timestamps, and event instrumentation"
  spec.description = <<~DESC
    LiteState is a minimal yet powerful state machine for ActiveRecord models. It provides:
    - Clean DSL for defining state transitions
    - Guard conditions to prevent invalid transitions
    - Automatic timestamp tracking
    - ActiveSupport::Notifications for monitoring state changes
    - Transaction safety
    - Enum validation
  DESC
  spec.homepage = "https://github.com/mundanecodes/lite_state"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/mundanecodes/lite_state"
  spec.metadata["bug_tracker_uri"] = "https://github.com/mundanecodes/lite_state/issues"
  spec.metadata["documentation_uri"] = "https://rubydoc.info/gems/lite_state"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.each_line("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ .git .github Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Runtime dependencies
  spec.add_dependency "activesupport", ">= 7.1"
  spec.add_dependency "activerecord", ">= 7.1"

  # Development dependencies
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "standard", ">= 1.35.1"
  spec.add_development_dependency "sqlite3", ">= 2.1"
end
