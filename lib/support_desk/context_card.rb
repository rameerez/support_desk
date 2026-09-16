# frozen_string_literal: true

module SupportDesk
  # Everything an agent needs next to the transcript, as plain Ruby: what
  # the case is about, what state that thing is in, who is asking, and
  # where to go to do something about it.
  #
  #   card = ticket.context_card
  #   card.title          # "Viaje Sevilla → Granada · 20 sep"
  #   card.status         # "Completado"
  #   card.pairs          # { "Conductor" => "Lucía G.", "Plazas" => 3 }
  #   card.subject_url    # "/madmin/rides/…"
  #   card.requester_name # "Alice"
  #
  # No view dependency at all — render it in ERB, a JSON API, or a Telegram
  # message.
  class ContextCard
    attr_reader :ticket

    # The card for one ticket.
    def initialize(ticket)
      @ticket = ticket
    end

    # What the case is about, and what to call it.
    def subject = ticket.subject

    # What to put at the top of the card.
    def title = ticket.label

    # The subject's own status pill, when it has one.
    def status = subject&.support_status

    # Key/value pairs the host chose to show agents.
    def pairs
      subject&.support_context || {}
    end

    # Where to open the subject in the host's admin, or nil.
    def subject_url = subject&.support_url

    # The topic, and the whole branch spelled out.
    def topic = ticket.topic

    # The whole branch spelled out ("Billing › Invoice").
    def topic_label = ticket.topic&.full_label

    # Who is asking, as the console should show them.
    def requester = ticket.requester

    # The requester as the console should show them: a display name, and
    # an avatar if the host has one.
    def requester_name
      Chats.display_name_for(requester)
    end

    # Anything image_tag accepts, or nil.
    def requester_avatar
      Chats.avatar_for(requester)
    end

    # When this requester joined — context for "is this a new user?".
    def requester_since = requester.try(:created_at)

    # How many open cases this requester has right now, this one included.
    def requester_open_tickets
      Ticket.not_closed.where(requester: requester).count
    end

    # The same card as a Hash, for a JSON console.
    def to_h
      {
        title: title,
        status: status,
        topic: topic&.path,
        topic_label: topic_label,
        pairs: pairs,
        subject_url: subject_url,
        requester: {
          name: requester_name,
          since: requester_since,
          open_tickets: requester_open_tickets
        }
      }
    end

    # The card, in one line.
    def inspect = "#<SupportDesk::ContextCard #{title.inspect}>"
  end
end
