# frozen_string_literal: true

require "rails/generators/base"
require "rails/generators/active_record"

module SupportDesk
  module Generators
    # `rails generate support_desk:upgrade` — copy the migrations a version
    # bump needs into an EXISTING install. Nothing else: the initializer, the
    # views, the console and the routes you already own stay untouched.
    #
    # Currently writes the 0.2.0 migration (who opened the case), which is the
    # SAME template a fresh install runs — one file owns those columns, so a
    # fresh install and an upgraded one end up with the same schema and the
    # same rollback. Running this twice writes nothing the second time: the
    # migration already sitting in db/migrate is identical, and Rails skips it.
    class UpgradeGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)
      desc "Add the migrations a support_desk version bump needs (0.2.0: opened_by)"

      # Rails' migration numbering, borrowed from ActiveRecord's generators.
      def self.next_migration_number(dir)
        ActiveRecord::Generators::Base.next_migration_number(dir)
      end

      def create_opened_by_migration
        migration_template "add_opened_by_to_support_desk_tickets.rb.erb",
                           File.join(db_migrate_path, "add_opened_by_to_support_desk_tickets.rb")
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
        say "  4. See the CHANGELOG for the full list.\n", :green
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::STRING.to_f}]"
      end
    end
  end
end
