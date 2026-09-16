# frozen_string_literal: true

source "https://rubygems.org"

# Runtime dependencies are specified in support_desk.gemspec
gemspec

# The kernel gem, developed in lockstep with this one. Swap for the released
# `gem "chats", "~> 0.2"` once 0.2.0 is on rubygems.
gem "chats", path: "../chats"

# Build & release tools
gem "rake", "~> 13.0"

group :development do
  gem "appraisal"

  # Code quality. Both are gates (see the Rakefile): `rake ci` runs the
  # suite, the linter and the security scanner, which is what a PR has to
  # pass.
  gem "brakeman", "~> 8.0", require: false
  gem "rubocop-rails-omakase", require: false
end

group :test do
  gem "minitest", "~> 6.0"
  # Minitest 6 extracted minitest/mock into its own gem.
  gem "minitest-mock"
  gem "simplecov", require: false

  # Rails frameworks the dummy app boots that are NOT runtime dependencies of
  # the gem itself. support_desk needs activerecord/activesupport/railties;
  # ActionCable (chats' Turbo Streams transport), ActiveStorage (message
  # attachments), ActiveJob and ActionMailer are pieces the HOST app provides,
  # so they belong in the test bundle, not the gemspec.
  gem "actioncable"
  gem "actionmailer"
  gem "activejob"
  gem "activestorage"

  # Database adapters (for multi-database testing)
  gem "pg"
  gem "sqlite3"

  # Dummy Rails app
  gem "importmap-rails"
  gem "propshaft"
  gem "puma"
  gem "stimulus-rails"

  # Fix RDoc version conflict (Ruby 3.4+ ships with 7.0.3)
  gem "rdoc", ">= 7.0"

  # json 3.0 dropped `JSON.parse(source, options_hash)`, which is exactly how
  # ActiveSupport::JSON.decode calls it — every JSON column in the dummy app
  # raises ArgumentError on read. Pin until Rails ships a json 3 compatible
  # decoder.
  gem "json", "~> 2.7"
end
