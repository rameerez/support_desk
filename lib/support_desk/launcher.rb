# frozen_string_literal: true

module SupportDesk
  # The "Need help?" launcher (`support_launcher`): an item of chats' tray
  # (chats >= 0.7.0), beside the messaging dock's bar or in a corner of its
  # own, whose panel is this engine's own pages in a frame.
  #
  # This module is the launcher's two names and its live badge:
  #
  #   FRAME     the panel's turbo frame. A request that carries it
  #             (`Turbo-Frame: support_desk_panel`) is answered with the
  #             panel's templates (SupportDesk::TicketsController).
  #   BADGE_ID  the badge the requester's `[requester, :support_desk]`
  #             stream replaces.
  #
  # The badge is `requester.unread_support_count`: unread messages across
  # their own cases, against chats' read horizon, with no listing scope. It
  # never touches the Messages badge, which counts `messager.chats` (the
  # host's inbox_scope applied). It moves wherever chats says an unread count
  # may have moved (`Chats.on(:unread_changed)`: every message, the case's
  # own notices included, and a read), for a conversation that is a case's.
  module Launcher
    FRAME = "support_desk_panel"
    BADGE_ID = "support_desk_launcher_badge"
    BADGE_PARTIAL = "support_desk/launcher/badge"

    class << self
      # Whether +request+ is the panel's: its frame asked for it. Then the
      # requester's screens answer with the panel's templates, every link
      # stays inside it, and a new case opens in it.
      def panel_request?(request)
        request&.headers&.[]("Turbo-Frame") == FRAME
      end

      # chats' `:unread_changed`, filtered to support: a case's conversation
      # (its subject is the ticket, no query needed) and a seat that asks
      # for help (a requester; a desk or an agent's console has no launcher).
      def unread_changed(messager, conversation)
        return unless conversation&.subject_type == SupportDesk::Ticket.polymorphic_name
        return unless messager.respond_to?(:unread_support_count)

        broadcast_badge_of(messager)
      end

      # Replace +requester+'s launcher badge, wherever it is on screen: one
      # job, which counts when it renders (nothing is counted in the request
      # that wrote the message). A missed one heals on the launcher's
      # catch-up (GET tickets/badge).
      #
      # It runs whether or not this host renders a launcher: there is no
      # telling, from a job, whether anybody is listening, and a switch for it
      # would let a launcher's badge silently never move. Support is
      # human-paced, so this is one small job per message in a case.
      def broadcast_badge_of(requester)
        Turbo::StreamsChannel.broadcast_replace_later_to(
          requester, :support_desk,
          target: BADGE_ID,
          partial: BADGE_PARTIAL,
          locals: { requester: requester }
        )
      end
    end
  end
end
