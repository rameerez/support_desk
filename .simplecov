# frozen_string_literal: true

# SimpleCov configuration (auto-loaded by `require "simplecov"`); the suite
# calls SimpleCov.start from test_helper.rb. Coherent with the rest of the
# gem ecosystem (chats, moderate, usage_credits, …).
SimpleCov.configure do
  formatter SimpleCov::Formatter::SimpleFormatter

  skip "/test/"

  # Generators run via `rails generate support_desk:install` in a real host.
  # The generator classes ARE exercised by Rails::Generators::TestCase, but
  # the migration template itself is never loaded as Ruby here (the dummy
  # migrates a copy of it instead).
  skip "/lib/generators/"
  skip "/lib/support_desk/version.rb"

  cover "lib/**/*.rb"

  enable_coverage :branch

  # Thresholds sit just under the current floor so the gate catches a real
  # regression without failing on the existing baseline; raise as it grows.
  minimum_coverage line: 85, branch: 60
end
