# frozen_string_literal: true

module SupportDesk
  # The whole story of a case in one sequence: what was said and what was
  # done, merged by time.
  #
  #   ticket.timeline.each { |entry| … }
  #   ticket.timeline.print          # in `rails c`
  #
  # Entries wrap a Chats::Message, a SupportDesk::Event or a decided
  # SupportDesk::Draft, and answer the same three questions — when, who,
  # what.
  #
  # A draft is here because it is the only part of the story with no message
  # and no event of its own to carry it: the event says a proposal was sent
  # or discarded, and the row is what the proposal actually SAID. A pending
  # one is not history yet, so it stays out — it is on the screen above,
  # waiting for somebody.
  class Timeline
    include Enumerable

    # One moment in a case.
    class Entry
      attr_reader :at, :message, :event, :draft

      # One moment: a message, an event or a decided proposal, and when it
      # happened.
      def initialize(at:, message: nil, event: nil, draft: nil)
        @at = at
        @message = message
        @event = event
        @draft = draft
      end

      # Which of the three this moment is.
      def message? = !message.nil?
      def event? = !event.nil?
      def draft? = !draft.nil?

      # :message, :draft, or the event's kind (:assigned, :closed, :note…).
      def kind
        return :message if message?
        return :draft if draft?

        event.kind.to_sym
      end

      # Who is responsible for this moment: a message's author (the agent
      # who signed it) or sender, an event's actor, or — for a proposal —
      # the person who decided about it, falling back to the machine that
      # wrote it when nobody did.
      def actor
        return draft.reviewed_by || draft.author if draft?
        return event.actor_or_system if event?

        message.try(:author) || message.sender
      end

      # What was said, what a note said, or what a proposal proposed. Nil
      # for the rest.
      def body
        return draft.final_body if draft?

        message? ? message.try(:visible_body) : event.note
      end

      # Time, kind and the first line of what was said — printable.
      def to_s
        "#{at&.iso8601} #{kind} #{body.to_s.truncate(60)}".strip
      end

      # The entry, in one line.
      def inspect = "#<SupportDesk::Timeline::Entry #{to_s.inspect}>"
    end

    attr_reader :ticket

    # The timeline of one ticket.
    def initialize(ticket)
      @ticket = ticket
    end

    # Every moment, oldest first. Enumerable, so map/select/find work.
    def each(&block)
      return to_enum(:each) unless block

      entries.each(&block)
      self
    end

    # Every moment, oldest first.
    def entries
      @entries ||= (message_entries + event_entries + draft_entries)
                   .sort_by { |entry| [ entry.at || Time.at(0), entry.kind.to_s ] }
    end

    # How many moments the case has had, and the latest one.
    def size = entries.size
    def last = entries.last

    # Print the case to stdout, for consoles and scripts.
    def print(io = $stdout)
      each { |entry| io.puts(entry.to_s) }
      nil
    end

    # Which ticket, and how much has happened to it.
    def inspect = "#<SupportDesk::Timeline #{ticket.reference} #{size} entries>"

    private

    def message_entries
      return [] if ticket.conversation.nil?

      ticket.conversation.messages.visible.oldest_first.map do |message|
        Entry.new(at: message.created_at, message: message)
      end
    end

    def event_entries
      ticket.events.chronological.map { |event| Entry.new(at: event.created_at, event: event) }
    end

    # Proposals somebody decided about — sent, discarded, or overtaken.
    # One query, and on the overwhelming majority of desks it returns
    # nothing at all, because nothing has ever proposed anything.
    def draft_entries
      ticket.drafts.where.not(status: "pending").chronological.includes(:author, :reviewed_by).map do |draft|
        Entry.new(at: draft.created_at, draft: draft)
      end
    end
  end
end
