# frozen_string_literal: true

module SupportDesk
  # The conversation as something other than HTML: one flat, ordered list of
  # turns, each one saying who spoke, what they said and when.
  #
  #   ticket.transcript.to_text
  #   # [2026-09-18 10:02] Alice: No me han pagado
  #   # [2026-09-18 10:03] Rose: Lo estoy mirando ahora mismo
  #   # [2026-09-18 10:07] Lucía: Ya está resuelto [justificante.pdf]
  #
  #   ticket.transcript(limit: 20).last(5)
  #   ticket.transcript.since(message)
  #
  # It exists for the harness that has to hand a conversation to a model
  # without reading chats' tables, and for anything else that wants the
  # transcript as data: an export, a summary job, a console that renders
  # JSON. `Brief` embeds it.
  #
  # == Four roles, not three
  #
  # `Ticket#role_of` answers +:requester+, +:agent+ or +:system+, because
  # that is what the CLOCKS care about — whose turn it is does not change
  # depending on whether a person or a machine wrote the desk's last word.
  # A reader does care, so this is a SEPARATE serializer with its own
  # vocabulary: +:requester+, +:human+, +:assistant+, +:system+. Neither
  # one is derived from the other, and `role_of` is deliberately left
  # alone — the day a third kind of author appears, only this file moves.
  #
  # == Names survive renames
  #
  # An assistant's name is read from the message's own provenance stamp
  # first (`metadata["support_desk"]["assistant"]`, the KEY), resolved
  # through the configuration when she is still declared, and only then
  # falls back to the `display_name` the message was written with. So a
  # transcript reads "Rose" while Rose is configured, keeps saying what the
  # customer was actually shown for an assistant nobody declares any more,
  # and never invents a name for a message written under a nameless
  # disclosure mode.
  #
  # == Deleted messages are turns too
  #
  # A tombstone renders as `support_desk.transcript.deleted` with no
  # attachments, rather than vanishing: a model that cannot see that
  # something was said and withdrawn will answer as if it never was, and a
  # gap in a numbered transcript is worse than a marked one.
  class Transcript
    include Enumerable

    # One line of the conversation. A value: built once, then only read.
    #
    # * +role+        — :requester | :human | :assistant | :system
    # * +name+        — who to print; the desk's name for system lines
    # * +body+        — what was said, or the tombstone copy
    # * +at+          — when (a Time)
    # * +attachments+ — filenames, as Strings
    # * +assisted+    — a human sent it, a machine proposed it
    # * +message+     — the Chats::Message itself, for anything else
    Turn = Struct.new(:role, :name, :body, :at, :attachments, :assisted, :message, keyword_init: true) do
      def requester? = role == :requester
      def human? = role == :human
      def assistant? = role == :assistant
      def system? = role == :system

      # Whether a person sent a machine's words. Provenance, not authorship:
      # the message is the human's (see SupportDesk::Draft).
      def assisted? = !!assisted

      # "[2026-09-18 10:02] Alice: No me han pagado [justificante.pdf]"
      #
      # UTC, to the minute, always: a transcript that a model reads is
      # compared against itself line by line, and a stamp that moves with
      # the reader's zone or carries seconds is noise in a diff.
      def to_line
        said = [ body.to_s.strip.presence, *attachments.map { |file| "[#{file}]" } ].compact
        "[#{at&.utc&.strftime("%Y-%m-%d %H:%M")}] #{name}: #{said.join(" ")}"
      end

      alias_method :to_s, :to_line

      def to_h
        { role: role, name: name, body: body, at: at, attachments: attachments, assisted: assisted }
      end
    end

    attr_reader :ticket, :limit

    # The transcript of +ticket+. `limit:` keeps the LAST n turns — the end
    # of a conversation is the part that is still being answered.
    def initialize(ticket, limit: nil)
      @ticket = ticket
      @limit = limit&.to_i
    end

    # Every turn, oldest first.
    def each(&block)
      turns.each(&block)
    end

    def to_a = turns.dup

    def size = turns.size

    alias_method :length, :size

    # The last +count+ turns, oldest first.
    def last(count = 1)
      turns.last(count)
    end

    # Everything said after +message+ — "what has happened since the one I
    # answered". A message this transcript doesn't hold (older than `limit:`,
    # from another case, deleted outright) yields the whole window rather
    # than nothing: the caller has seen none of it, and an empty answer would
    # read as "nothing happened".
    def since(message)
      return to_a if message.nil?

      index = turns.index { |turn| turn.message&.id.to_s == message.id.to_s }
      return to_a if index.nil?

      turns[(index + 1)..] || []
    end

    # The whole thing as one block of text, for a prompt or a log line.
    def to_text
      turns.map(&:to_line).join("\n")
    end

    alias_method :to_s, :to_text

    # The transcript as data. `truncated` is the honest half of `limit:`:
    # a reader that is seeing the last 50 of 300 turns has to know it.
    def to_h
      {
        size: total,
        truncated: total > turns.size,
        turns: turns.map(&:to_h)
      }
    end

    def inspect
      "#<SupportDesk::Transcript #{ticket.reference} #{turns.size} turn(s)>"
    end

    private

    # Built once per instance: a transcript is a snapshot of a conversation
    # at the moment somebody asked for it, and a second read that disagreed
    # with the first would make `since` and `last` answer about two
    # different conversations.
    def turns
      @turns ||= messages.map { |message| turn_for(message) }
    end

    def messages
      return [] if ticket.conversation.nil?

      scope = ticket.conversation.messages.oldest_first
      all = scope.to_a
      @total = all.size
      limit ? all.last(limit) : all
    end

    def total
      turns # force the read, which is what counts
      @total.to_i
    end

    def turn_for(message)
      role = role_for(message)
      tombstone = message.respond_to?(:deleted?) && message.deleted?

      Turn.new(
        role: role,
        name: name_for(role, message),
        body: tombstone ? I18n.t("support_desk.transcript.deleted") : message.body,
        at: message.created_at,
        attachments: tombstone ? [] : attachment_names(message),
        assisted: assisted?(message),
        message: message
      )
    end

    # System first (a disclosure notice is a system line, whatever wrote
    # it), then the machine, then the two kinds of person.
    def role_for(message)
      return :system if message.respond_to?(:system?) && message.system?
      return :assistant if ticket.assistant_message?(message)

      case ticket.send(:role_of, message)
      when :requester then :requester
      when :agent then :human
      else :system
      end
    end

    def name_for(role, message)
      case role
      when :requester then Chats.display_name_for(ticket.requester)
      when :assistant then assistant_name(message)
      when :human then message.author.try(:support_agent_name) || ticket.desk&.name
      else ticket.desk&.name
      end
    end

    # The key the message was stamped with, resolved to the name that key
    # has NOW — and the stored display name when nothing declares her any
    # more. A message written by the record rather than by `speak!` (an
    # import, a host that posts its own) has neither, so the record answers.
    def assistant_name(message)
      stamp = provenance(message)
      key = stamp["assistant"]
      if key.present? && SupportDesk.config.assistant?(key)
        return SupportDesk.config.assistant(key).name
      end

      stamp["display_name"].presence || message.author.try(:name) || ticket.desk&.name
    end

    def assisted?(message)
      provenance(message)["drafted_by"].present?
    end

    def provenance(message)
      stamp = message.try(:metadata)
      return {} unless stamp.is_a?(Hash)

      nested = stamp["support_desk"]
      nested.is_a?(Hash) ? nested : {}
    end

    def attachment_names(message)
      message.try(:files)&.map { |file| file.try(:filename).to_s } || []
    end
  end
end
