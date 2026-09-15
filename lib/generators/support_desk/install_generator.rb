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

      def self.next_migration_number(dir)
        ActiveRecord::Generators::Base.next_migration_number(dir)
      end

      def create_migration_file
        migration_template "create_support_desk_tables.rb.erb",
                           File.join(db_migrate_path, "create_support_desk_tables.rb")
      end

      def create_initializer
        template "initializer.rb", "config/initializers/support_desk.rb"
      end

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

        say "\n  Email (0.2): when the channel lands, route inbound mail with"
        say "  # app/mailboxes/application_mailbox.rb"
        say "  #   routing(/^support@/i => :support_desk)"

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
