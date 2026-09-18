# frozen_string_literal: true

require "rails/generators/base"
require "rails/generators/active_record"

module SupportDesk
  module Generators
    # `rails generate support_desk:install` — copies the adaptive migration
    # (uuid or bigint keys, adapter-aware JSON columns, PostgreSQL partial
    # unique indexes) and the annotated initializer, then prints the three
    # model lines and one route line that finish the install.
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)
      desc "Install support_desk's migration and initializer"

      # Rails' migration numbering, borrowed from ActiveRecord's generators.
      def self.next_migration_number(dir)
        ActiveRecord::Generators::Base.next_migration_number(dir)
      end

      # The schema: four tables, adaptive keys, partial indexes where the
      # adapter has them.
      def create_migration_file
        migration_template "create_support_desk_tables.rb.erb",
                           File.join(db_migrate_path, "create_support_desk_tables.rb")
      end

      # Who opened each case. A SEPARATE migration, copied from the same
      # template `support_desk:upgrade` hands an existing install, so one
      # file owns those two columns and their index wherever they came from
      # — and a fresh install's `down` removes exactly what its `up` added.
      def create_opened_by_migration
        migration_template "add_opened_by_to_support_desk_tickets.rb.erb",
                           File.join(db_migrate_path, "add_opened_by_to_support_desk_tickets.rb")
      end

      # The assistants (0.3). The SAME file `support_desk:upgrade` copies,
      # for the same reason: one migration owns those tables and columns
      # wherever they came from.
      def create_assistants_migration
        migration_template "add_assistants_to_support_desk.rb.erb",
                           File.join(db_migrate_path, "add_assistants_to_support_desk.rb")
      end

      # The annotated initializer — every setting the gem has, with what it
      # means and what it defaults to.
      def create_initializer
        template "initializer.rb", "config/initializers/support_desk.rb"
      end

      # The three model lines and one route line that finish the install.
      def display_post_install_message
        say "\n🎫 The `support_desk` gem has been installed.", :green
        say "\nTo complete the setup:"

        say "  1. Run 'rails db:migrate' to create the support_desk tables."
        say "     ⚠️  You must run migrations before starting your app!", :yellow

        say "  2. Three model lines — who asks, what they ask about, who answers:"
        say "       class User < ApplicationRecord"
        say "         acts_as_messager                  # chats"
        say "         has_support_tickets"
        say "         acts_as_support_agent if: :admin?"
        say "       end"
        say ""
        say "       class Ride < ApplicationRecord"
        say "         supportable topic: :ride"
        say "       end"

        say "  3. One route line:"
        say "       # config/routes.rb"
        say "       mount SupportDesk::Engine => \"/support\""

        say "  4. Tell the desk who it is, in config/initializers/support_desk.rb:"
        say "       config.name = \"Soporte\""
        say "       config.agents { User.admin }"
        say "       config.topics { topic :ride, about: Ride; other }"

        say "\n  Locales: es and en ship with the gem. To translate your topic labels,"
        say "  add support_desk.topics.<path>.label keys to your own locale files."

        say "\n  The requester's screens render with bundled styles. To restyle them,"
        say "  'rails g support_desk:views' copies them into your app, where they"
        say "  shadow the gem's copies (delete yours and the default comes back)."

        say "\n  Email (0.2): when the channel lands, route inbound mail with"
        say "  # app/mailboxes/application_mailbox.rb"
        say "  #   routing(/^support@/i => :support_desk)"

        say "\n  Already installed and bumping the version? 'rails g support_desk:upgrade' copies"
        say "  only the migrations the new version needs (0.2.0: who opened the case), and"
        say "  nothing you own. Follow the CHANGELOG's drained cutover: migrate, pause"
        say "  support traffic, drain old web/workers, backfill, then serve only 0.2."

        say "\nCheck your work any time with SupportDesk.doctor.print"
        say "You now have support tickets that are real conversations. 🚀\n", :green
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::STRING.to_f}]"
      end
    end
  end
end
