# frozen_string_literal: true

# SimpleCov must be loaded before any application code (its configuration is
# auto-loaded from the .simplecov file).
require "simplecov"
SimpleCov.start

ENV["RAILS_ENV"] = "test"

require File.expand_path("dummy/config/environment.rb", __dir__)
ActiveRecord::Migrator.migrations_paths = [ File.expand_path("dummy/db/migrate", __dir__) ]

# Auto-migrate so a plain `bundle exec rake test` works on a fresh checkout.
ActiveRecord::MigrationContext.new(ActiveRecord::Migrator.migrations_paths).migrate

require "rails/test_help"
require "minitest/mock"
require "support_desk/test_helper"

Minitest.backtrace_filter = Minitest::BacktraceFilter.new

module ActiveSupport
  class TestCase
    include ActiveJob::TestHelper
    include SupportDesk::TestHelper

    setup do
      # The badge is cached per agent for 30s in a process-wide memory
      # store; ids repeat across examples, so a stale entry would leak.
      Rails.cache.clear

      # Start every example from a known configuration so policies, topics
      # and subscribers never leak between tests — and re-register the dummy
      # host classes the reset wiped (registries are global state too).
      Chats.reset!
      Chats.configure { |config| config.messager_class = "User" }
      Chats.register_messager(User)

      SupportDesk.reset!
      configure_support_desk!
      SupportDesk.subscribe_to_chats!
    end

    teardown do
      SupportDesk.reset!
      Chats.reset!
    end

    # The dummy host's own wiring (config/initializers/support_desk.rb),
    # re-applied after the reset above.
    def configure_support_desk!
      SupportDesk.configure do |config|
        config.requester_class = "User"
        config.name = "Soporte"
        config.agents { User.where(admin: true) }

        config.topics do
          topic :order, about: Order
          topic :billing do
            topic :invoice, about: Invoice
          end
          topic :account, only: ->(requester) { requester.onboarded? }
          other
        end
      end
    end

    # Whether this adapter enforces the partial unique indexes — everything
    # but MySQL — so a test can tell "the database refused it" from "only
    # the model would have".
    def partial_indexes?
      !ActiveRecord::Base.connection.adapter_name.match?(/mysql/i)
    end

    # Tests that assert the DATABASE refuses something call this first. It
    # fails rather than skips: the suite's own legs (SQLite, PostgreSQL)
    # both have partial indexes, so reaching this on them is a real problem.
    def skip_unless_partial_indexes
      assert partial_indexes?,
             "this adapter has no partial indexes, so the cardinality guarantee is model-only here"
    end

    # --- Data helpers -----------------------------------------------------------

    def create_user(name: "User #{SecureRandom.hex(3)}", **attributes)
      User.create!(name: name, **attributes)
    end

    # An eligible agent (the dummy's `if: :admin?`).
    def create_agent(name: "Agent #{SecureRandom.hex(3)}", **attributes)
      create_user(name: name, admin: true, **attributes)
    end

    def create_order(user:, number: "SO#{SecureRandom.hex(2).upcase}", **attributes)
      Order.create!(user: user, number: number, **attributes)
    end

    def create_invoice(user:, number: "INV#{SecureRandom.hex(2).upcase}", **attributes)
      Invoice.create!(user: user, number: number, **attributes)
    end

    # A ticket with its opening message already folded in — the canonical
    # fixture.
    #
    # Nothing to fold by hand: since Rails 5 the test transaction is
    # non-joinable, so `after_commit` callbacks DO run inside it, which
    # means chats' `:message_created` subscriber has already called
    # `register!` by the time this returns. (Measured, not assumed — see
    # "the opening message leaves the desk owing the next word".)
    def ticket_for(requester, about: nil, topic: nil, message: "Necesito ayuda")
      requester.ask_support!(message, about: about, topic: topic)
    end
  end
end

module ActionDispatch
  class IntegrationTest
    # Act as +user+ for subsequent requests (see the dummy SessionsController).
    def login_as(user)
      post "/test_login", params: { user_id: user.id }
      assert_response :no_content
    end
  end
end
