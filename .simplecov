# frozen_string_literal: true

# SimpleCov configuration (auto-loaded by `require "simplecov"`); the suite
# calls SimpleCov.start from test_helper.rb, so this file stays
# configuration-only. Coherent with the rest of the gem ecosystem (chats,
# wallets, moderate, usage_credits, …).
SimpleCov.configure do
  # SimpleFormatter for terminal-only output (no HTML generation)
  formatter SimpleCov::Formatter::SimpleFormatter

  # Don't count code that ISN'T unit-testable by this suite and would only
  # distort the numbers:
  #   - the test suite itself;
  #   - generators + their templates: they run via `rails generate
  #     support_desk:install` in a real host. The generator classes ARE
  #     exercised by Rails::Generators::TestCase, but the migration template
  #     itself is never loaded as Ruby here (the dummy migrates a copy of it);
  #   - version.rb: a single constant, nothing to cover.
  if respond_to?(:skip)
    # SimpleCov 1.x vocabulary.
    skip "/test/"
    skip "/lib/generators/"
    skip "/lib/support_desk/version.rb"
    cover "lib/**/*.rb"
  else
    # Fallback vocabulary for SimpleCov 0.22.
    add_filter "/test/"
    add_filter "/lib/generators/"
    add_filter "/lib/support_desk/version.rb"
    track_files "lib/**/*.rb"
  end

  enable_coverage :branch

  # Thresholds sit just under the current floor so the gate catches a real
  # regression without failing on the existing baseline; raise as it grows.
  minimum_coverage line: 94, branch: 74

  # Disambiguate parallel test runs
  command_name "Job #{ENV["TEST_ENV_NUMBER"]}" if ENV["TEST_ENV_NUMBER"]
end

# Print coverage summary to terminal after tests complete
SimpleCov.at_exit do
  SimpleCov.result.format!
  puts "\n#{"=" * 60}"
  puts "COVERAGE SUMMARY"
  puts "=" * 60
  puts "Line Coverage:   #{SimpleCov.result.covered_percent.round(2)}%"
  branch_coverage = SimpleCov.result.coverage_statistics[:branch]&.percent&.round(2) || "N/A"
  puts "Branch Coverage: #{branch_coverage}%"
  puts "=" * 60
end
