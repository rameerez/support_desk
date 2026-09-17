# frozen_string_literal: true

module SupportDesk
  # One line about a ticket, for places that only have one line: a list row,
  # a Slack message, the daily Telegram digest, `rails c`.
  #
  #   ticket.summary.to_s
  #   # => "T-AB12CD · Viaje Sevilla → Granada · Alice · esperando respuesta (12 min)"
  class Summary
    attr_reader :ticket

    # The one-line summary of a ticket.
    def initialize(ticket)
      @ticket = ticket
    end

    # The pieces, for hosts that want to lay them out themselves.
    def reference = ticket.reference
    def label = ticket.label

    # Who is asking, and who is answering (nil while nobody is).
    def requester_name
      Chats.display_name_for(ticket.requester)
    end

    # Who is answering, or nil while nobody is.
    def assignee_name
      ticket.assignee&.support_agent_name
    end

    # "esperando respuesta" / "esperando al cliente" / "cerrado".
    def state
      return I18n.t("support_desk.summary.closed") if ticket.closed?
      return I18n.t("support_desk.summary.awaiting_reply") if ticket.awaiting_reply?
      return I18n.t("support_desk.summary.awaiting_requester") if ticket.awaiting_requester?

      I18n.t("support_desk.summary.open")
    end

    # How long the current wait has been going on, as words ("12 minutes").
    def waiting
      duration = ticket.waiting_for
      return nil if duration.nil?

      # Through the same helper the wizard uses for its promise line, so
      # this speaks the reader's language. Duration#inspect is English
      # whatever the locale, which left one untranslatable string in an
      # otherwise Spanish console.
      SupportDesk.humanize_duration(duration)
    end

    # The whole line.
    def to_s
      parts = [ reference, label, requester_name, state ]
      parts << "(#{waiting})" if waiting
      parts.compact.join(" · ")
    end

    # The same line, in pieces.
    def to_h
      {
        reference: reference, label: label, requester: requester_name, assignee: assignee_name,
        state: state, waiting: waiting
      }
    end

    # The summary, in one line.
    def inspect = "#<SupportDesk::Summary #{to_s.inspect}>"
  end
end
