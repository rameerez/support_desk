# frozen_string_literal: true

require "rails/generators/base"
require "rails/generators/active_record"

module SupportDesk
  module Generators
    # `rails generate support_desk:upgrade` — copy the migrations a version
    # bump needs into an EXISTING install. Nothing else: the initializer, the
    # views, the console and the routes you already own stay untouched.
    #
    # Install and upgrade use the same templates for opened_by, assistants,
    # and message receipts. See the README for the drained receipt cutover;
    # old writers do not know how to record message identities.
    class UpgradeGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)
      desc "Add the migrations a support_desk version bump needs (opened_by, assistants, message registration receipts)"

      # Rails' migration numbering, borrowed from ActiveRecord's generators.
      def self.next_migration_number(dir)
        ActiveRecord::Generators::Base.next_migration_number(dir)
      end

      def create_opened_by_migration
        migration_template "add_opened_by_to_support_desk_tickets.rb.erb",
                           File.join(db_migrate_path, "add_opened_by_to_support_desk_tickets.rb")
      end

      def create_assistants_migration
        migration_template "add_assistants_to_support_desk.rb.erb",
                           File.join(db_migrate_path, "add_assistants_to_support_desk.rb")
      end

      def create_message_registrations_migration
        migration_template "create_support_desk_message_registrations.rb.erb",
                           File.join(db_migrate_path, "create_support_desk_message_registrations.rb")
      end


      def display_post_upgrade_message
        say "\n🎫 support_desk upgrade migrations copied.", :green
        say "\n  1. Run 'rails db:migrate'. It adds `opened_by` and points every existing"
        say "     case at its requester — 0.1 had no other way to open one."
        say "  2. New in 0.2.0:"
        say "       lucia.open_support_conversation_with!(alice, \"Vimos que…\")   # the desk writes first"
        say "       ticket.opened_by / opened_by_support? / opened_by_requester?"
        say "       config.opening_line / config.opening_line_from_support / config.find_requester"
        say "       has_support_tickets if: :kept?                                 # who may be written to"
        say "  3. Migrate BEFORE 0.2 serves traffic. Pause support writes; stop and drain"
        say "     ALL old web requests and workers. This is NOT a rolling deployment."
        say "     Keep traffic paused, run 'rake support_desk:backfill_opened_by' under 0.2,"
        say "     verify no NULL openers remain, then start only 0.2 and resume traffic."
        say "  4. New in 0.3.0 — assistants. The migration is ADDITIVE and rolling-safe:"
        say "     add `config.assistant` only once every process is on 0.3.0. Then"
        say "       rails g support_desk:assistant Rose --disclosure signature"
        say "     writes the harness and prints the stanza, the subscription and the two"
        say "     scheduled tasks. It never edits your initializer."
        say "  5. 0.3.2 receipts require a drained cutover: pause support writes and stop"
        say "     old web/jobs, migrate, then start only the new version. Review historical"
        say "     suspect callbacks before resuming; old clocks cannot prove delivery."
        say "     Do not roll code back to a writer that cannot record receipts."
        say "  6. See the CHANGELOG for the full list.\n", :green
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::STRING.to_f}]"
      end
    end
  end
end
