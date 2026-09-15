# frozen_string_literal: true

require_relative "boot"

# Pull in ONLY the Rails frameworks the gem's test suite exercises:
#   - active_record     : the support_desk + chats models, and the dummy host
#   - active_job        : the broadcast jobs and the host's own fan-out
#   - active_storage    : message attachments (chats)
#   - action_controller : the engine's controllers
#   - action_view       : the engine's views and broadcast partials
#   - action_cable      : the Turbo Streams transport every broadcast rides on
#   - action_mailer     : hosts commonly email from an event subscriber
require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_view/railtie"
require "action_mailer/railtie"
require "action_cable/engine"

require "propshaft"
require "turbo-rails"
require "importmap-rails"
require "stimulus-rails"

require "chats"
require "support_desk"

module Dummy
  # The minimal host application the engine mounts into: a User who asks for
  # help and answers it, an Order and an Invoice to ask about.
  class Application < Rails::Application
    # Pin the app root to this dummy directory, not whatever Rails guesses
    # by walking up for a Gemfile from the gem root.
    config.root = File.expand_path("..", __dir__)

    # Anchor to the gemspec's Rails floor: the dummy must boot identically on
    # every Rails in the Appraisal matrix.
    config.load_defaults 7.2

    # Eager load in test so the whole gem loads up front: autoload problems
    # become a boot failure instead of a mysterious mid-test error.
    config.eager_load = true

    config.consider_all_requests_local = true
    config.action_controller.perform_caching = false
    config.active_support.deprecation = :stderr

    # CI drives the test DB with migrations, not schema.rb, precisely because
    # a dumped schema.rb carries adapter-specific quirks that fail to load on
    # the next database in the matrix.
    config.active_record.dump_schema_after_migration = false

    config.active_job.queue_adapter = :test
    config.action_mailer.delivery_method = :test
    config.active_storage.service = :test

    # A real cache store so Queue#badge actually caches (and expires).
    config.cache_store = :memory_store

    config.action_controller.allow_forgery_protection = false
    config.action_mailer.default_url_options = { host: "example.com" }

    config.secret_key_base = "support_desk_dummy_secret_key_base_for_tests_only"
  end
end
