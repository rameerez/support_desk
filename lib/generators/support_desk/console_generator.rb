# frozen_string_literal: true

require "rails/generators/base"

module SupportDesk
  module Generators
    # `rails generate support_desk:console madmin` — the agent console as
    # files in YOUR app: a controller that includes the two console
    # concerns, a madmin resource so the nav and search know tickets exist,
    # and the whole view set.
    #
    # The views are copied straight out of `SupportDesk::ConsoleEngine` —
    # the same templates the mounted console renders, not a second set that
    # can drift from it. They reference nothing private: queue tabs come
    # from `queue.tabs`, rows from the ticket's own predicates, buttons from
    # `actions_for`, paths from the console concern's
    # `console_ticket_path` (which reads THIS controller's route, so the
    # files work under any namespace). Edit them freely.
    #
    # Idempotent: existing files are left alone unless you pass `--force`.
    class ConsoleGenerator < Rails::Generators::Base
      # Where the ConsoleEngine keeps the views both consoles render. One
      # source of truth, copied — never a symlink or a second copy to
      # maintain.
      VIEWS_ROOT = File.expand_path("../../../app/views/support_desk/console/tickets", __dir__)

      source_root File.expand_path("templates/console", __dir__)

      desc "Generate a support console (controller, admin resource and views) in your app"

      argument :target, type: :string, default: "madmin",
               desc: "The admin namespace to generate into (madmin)"

      def self.source_paths
        [ source_root, VIEWS_ROOT ]
      end

      def copy_controller
        template "controller.rb.erb", "app/controllers/#{target}/support_tickets_controller.rb", **file_options
      end

      # Only madmin has a resource concept; other targets get the controller
      # and the views, and wire their own nav.
      def copy_admin_resource
        return unless madmin?

        template "resource.rb.erb", "app/madmin/resources/support_ticket_resource.rb", **file_options
      end

      def copy_views
        Dir.children(VIEWS_ROOT).sort.each do |view|
          copy_file view, "#{views_path}/#{view}", **file_options
        end
      end

      def display_post_install_message
        say "\n🎫 A support console has been generated in app/controllers/#{target}/ and #{views_path}/.", :green
        say "\nTo finish:"

        say "  1. One route line:"
        say "       # config/routes.rb"
        say "       namespace :#{target} do"
        say "         resources :support_tickets, only: %i[index show], concerns: :support_console"
        say "       end"

        say "  2. A badge in your admin nav:"
        say "       <%= render \"#{target}/support_tickets/nav_badge\", agent: current_user %>"
        say "       # links to #{target}_support_tickets_path"

        say "  3. Check who may open it:"
        say "       config.current_agent_method = :current_user   # who is answering"
        say "       config.visible_desks_for    = ->(agent) { … } # which desks they may work"
        say "       config.authorize_console    = ->(agent, ticket, action) { … }"

        say "\n  The views are Tailwind and all copy comes from your locales, so restyle"
        say "  and retranslate freely — nothing in the gem reads them back."
        say "\nYour team has a queue. 🚀\n", :green
      end

      private

      # The module the generated controller lives in ("madmin" → "Madmin").
      def module_name = target.camelize

      def views_path = "app/views/#{target}/support_tickets"

      def madmin? = target == "madmin"

      # Idempotent by default: a second run leaves your edits alone. `--force`
      # (Thor's own flag) is how you take the new defaults after an upgrade.
      def file_options = options[:force] ? {} : { skip: true }
    end
  end
end
