# frozen_string_literal: true

require "rails/generators/base"

module SupportDesk
  module Generators
    # `rails generate support_desk:views` — eject the requester-facing
    # templates into the HOST app so they can be restyled. This is the Devise
    # move (`rails g devise:views`), and it works for the same boring Rails
    # reason: the host app's `app/views` sits AHEAD of any engine's view paths
    # in the lookup chain, so a file copied to e.g.
    # `app/views/support_desk/tickets/index.html.erb` SHADOWS the gem's
    # bundled default automatically — no config, no registration. Delete your
    # copy and the gem's default comes back. Upgrade the gem and your ejected
    # copies are untouched (re-run only if you WANT the new defaults).
    #
    # `source_root` points at the engine's own `app/views`, so `directory`
    # copies the exact templates the engine renders.
    class ViewsGenerator < Rails::Generators::Base
      source_root File.expand_path("../../../app/views", __dir__)

      desc "Copy support_desk's requester-facing views into your app so you can restyle them."

      # Which groups to eject. `tickets` is every requester screen (the list,
      # the wizard's three frames, the rows and the doors); `slots` is the
      # row this engine contributes to chats' inbox.
      class_option :views,
                   type: :array,
                   default: %w[tickets slots],
                   desc: "Which view groups to copy (tickets, slots)"

      def copy_views
        directory "support_desk/tickets", "app/views/support_desk/tickets" if include?("tickets")
        directory "chats/slots", "app/views/chats/slots" if include?("slots")
      end

      def show_styling_tip
        say "\n🎨 Views copied. They render with the gem's bundled support_desk.css (and chats.css"
        say "   for the rows) by default; restyle freely — if your app uses Tailwind, classes you"
        say "   add here are picked up by your build automatically (the files now live in app/views)."
      end

      private

      def include?(group)
        options[:views].map(&:to_s).include?(group)
      end
    end
  end
end
