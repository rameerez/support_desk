# frozen_string_literal: true

module SupportDesk
  # The whole story of a case in one sequence: what was said and what was
  # done, merged by time.
  #
  #   ticket.timeline.each { |entry| … }
  #   ticket.timeline.print          # in `rails c`
  #
  # Entries wrap either a Chats::Message or a SupportDesk::Event, and answer
  # the same three questions — when, who, what.
  class Timeline
    include Enumerable

    # One moment in a case.
    class Entry
      attr_reader :at, :message, :event

      def initialize(at:, message: nil, event: nil)
        @at = at
        @message = message
        @event = event
      end

      def message? = !message.nil?
      def event? = !event.nil?

      # :message, or the event's kind (:assigned, :closed, :note…).
      def kind
        message? ? :message : event.kind.to_sym
      end

      # Who is responsible for this moment: a message's author (the agent
      # who signed it) or sender, or an event's actor.
      def actor
        return event.actor_or_system if event?

        message.try(:author) || message.sender
      end

      def body
        message? ? message.try(:visible_body) : event.note
      end

      def to_s
        "#{at&.iso8601} #{kind} #{body.to_s.truncate(60)}".strip
      end

      def inspect = "#<SupportDesk::Timeline::Entry #{to_s.inspect}>"
    end

    attr_reader :ticket

    def initialize(ticket)
      @ticket = ticket
    end

    def each(&block)
      return to_enum(:each) unless block

      entries.each(&block)
      self
    end

    def entries
      @entries ||= (message_entries + event_entries).sort_by { |entry| [ entry.at || Time.at(0), entry.kind.to_s ] }
    end

    def size = entries.size
    def last = entries.last

    # Print the case to stdout, for consoles and scripts.
    def print(io = $stdout)
      each { |entry| io.puts(entry.to_s) }
      nil
    end

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
  end
end
