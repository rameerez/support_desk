# frozen_string_literal: true

module SupportDesk
  # A reply the assistant proposes and a human sends — or doesn't.
  #
  #   draft = ticket.pending_draft
  #   draft.send!(by: lucia, seen_turn: ticket.assistant_turn)          # verbatim
  #   draft.send!(by: lucia, seen_turn: …, body: "Casi: …")             # edited
  #   draft.reject!(by: lucia, reason: "no es eso")
  #
  # == Who wrote it
  #
  # A sent draft is a message from the HUMAN who sent it (12 #20): they read
  # it, they own it, and the requester sees their signature. What the machine
  # contributed is provenance — `support_desk.drafted_by`, `draft_id` and
  # `edited` in the message's metadata, and this row, which keeps the
  # original body even when the sent one was edited.
  #
  # == Staleness is not a warning, it is the contract
  #
  # `proposed_turn` is the ticket's turn when the draft was written.
  # `seen_turn` is the turn the reviewer was LOOKING at. Sending compares
  # `seen_turn` against the case's turn right now, under its row lock — so a
  # draft approved from a page that predates the customer's next message is
  # refused (SupportDesk::StaleTurn) rather than sent into a conversation
  # that has moved on. There is no "send anyway" flag: re-read the case and
  # submit again with the current turn.
  class Draft < ApplicationRecord
    self.table_name = "support_desk_drafts"

    # pending → sent | rejected (a human decided), or superseded (a newer
    # proposal, a takeover, a pause) | expired (the case closed).
    STATUSES = %w[pending sent rejected superseded expired].freeze

    # Enough for any honest answer, and a ceiling on what a model can stuff
    # into a JSON column.
    MAX_SOURCES = 20
    MAX_SOURCE_TITLE = 500
    MAX_SOURCE_URL = 2048

    belongs_to :ticket, class_name: "SupportDesk::Ticket", inverse_of: :drafts
    belongs_to :author, polymorphic: true
    belongs_to :reviewed_by, polymorphic: true, optional: true
    belongs_to :sent_message, class_name: "Chats::Message", optional: true

    # Attachments ride on ActiveStorage when the host has it installed —
    # the same condition chats' own messages use.
    has_many_attached :files if defined?(ActiveStorage)

    # Ruby-side defaults so both are always usable even on MySQL, where a
    # JSON column can't carry a DB default.
    attribute :sources, default: -> { [] }
    attribute :metadata, default: -> { {} }

    validates :status, inclusion: { in: STATUSES }
    validates :proposed_turn, presence: true
    validates :confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },
                           allow_nil: true
    validate :body_or_files_present
    validate :sources_well_formed

    scope :pending, -> { where(status: "pending") }
    scope :sent, -> { where(status: "sent") }
    scope :rejected, -> { where(status: "rejected") }
    scope :superseded, -> { where(status: "superseded") }
    scope :expired, -> { where(status: "expired") }
    # What a human actually decided about — the denominator every acceptance
    # number in the README is measured against.
    scope :reviewed, -> { where(status: %w[sent rejected]) }
    scope :verbatim, -> { sent.where(sent_body: nil) }
    scope :edited, -> { sent.where.not(sent_body: nil) }
    scope :by, ->(author) { where(author_type: author.class.polymorphic_name, author_id: author.id) }
    scope :chronological, -> { order(:created_at, :id) }
    scope :newest_first, -> { order(created_at: :desc, id: :desc) }

    def pending? = status == "pending"
    def sent? = status == "sent"
    def rejected? = status == "rejected"
    def superseded? = status == "superseded"
    def expired? = status == "expired"

    # Whether the case has changed since this was proposed — a customer
    # message, a human note, a takeover, anything. The turn is the whole
    # answer: it moves for every one of them.
    def stale?
      pending? && proposed_turn.to_s != ticket.assistant_turn
    end

    # Whether the human rewrote it before sending.
    def edited? = sent? && sent_body.present?

    # What the requester got (or would get): the edit when there was one.
    def final_body = sent_body.presence || body

    # The declared confidence as a whole percentage, or nil.
    def confidence_percent
      return nil if confidence.nil?

      (confidence.to_f * 100).round
    end

    # Who proposed it, as the stable key event payloads and metadata use.
    def author_key = SupportDesk.actor_key(author)

    # Whether this draft has attachments to carry to the message.
    def files_attached? # :nodoc:
      respond_to?(:files) && files.attached?
    end

    # --- The two decisions --------------------------------------------------------

    # Send it: the message is the HUMAN's, the proposal is provenance.
    # `seen_turn` is the case's turn as the reviewer's page rendered it, and
    # a mismatch is a refusal — see the class comment. `body:` replaces the
    # text (an edit); nil sends it verbatim. Returns the Chats::Message.
    def send!(by:, seen_turn:, body: nil, request: nil)
      human = ticket.send(:resolve_actor, by)
      if human.is_a?(Symbol) || SupportDesk.ai_actor?(human)
        raise NotAllowed,
              "an assistant can't approve her own draft — a person sends it, and it is signed by them"
      end
      ticket.send(:ensure_agent!, human)
      raise ArgumentError, "seen_turn: is required — send the turn the page was rendered with" if seen_turn.blank?
      if !body.nil? && body.to_s.strip.empty? && !files_attached?
        raise ArgumentError, "an edited draft can't be blank — reject it instead"
      end

      # The repair commits on its own, so a message whose registration
      # callback was lost is folded in for good even when the approval this
      # call was making is then refused as stale (R3).
      ticket.reconcile_and_commit!

      message = nil
      ticket.with_lock(requires_new: true) do
        reload
        # Ticket, then conversation: an in-flight customer message holds the
        # conversation row, so `seen_turn` cannot be compared against a case
        # whose next question is one commit away (R1).
        ticket.send(:lock_conversation!)
        ticket.send(:reconcile_unregistered_messages!)
        raise InvalidTransition, "draft #{id} is #{status}, not pending" unless pending?
        unless seen_turn.to_s == ticket.assistant_turn
          raise StaleTurn,
                "the case changed since you read it (#{seen_turn} → #{ticket.assistant_turn}); read it again"
        end

        final = body.nil? ? self.body : body
        edited = final != self.body
        # BEFORE anything moves: `stale?` reads `pending?`, and the update
        # below is what stops it being true.
        was_stale = stale?

        message = ticket.reply!(
          final, by: human, files: (files_attached? ? files.blobs : []), request: request,
          metadata: { "support_desk" => { "drafted_by" => author_key, "draft_id" => id.to_s, "edited" => edited } }
        )
        update!(status: "sent", reviewed_by: human, reviewed_at: Time.current, sent_message: message,
                sent_body: (final if edited))
        ticket.send(:reset_draft_associations!)
        ticket.send(:write_transition!, :draft_sent, actor: human, request: request) do
          { "draft" => id.to_s, "assistant" => author_key, "edited" => edited,
            "was_stale" => was_stale, "message" => message.id.to_s }
        end
      end

      SupportDesk.emit_after_commit(:draft_sent, ticket, self, message, by: human)
      message
    end

    # Throw it away, with a reason worth reading later: the rejection reasons
    # are what tell a host whether an assistant is ready for a higher level.
    def reject!(by:, reason: nil, request: nil)
      human = ticket.send(:resolve_actor, by)
      if human.is_a?(Symbol) || SupportDesk.ai_actor?(human)
        raise NotAllowed, "an assistant can't review her own draft"
      end
      ticket.send(:ensure_agent!, human)

      ticket.with_lock(requires_new: true) do
        reload
        raise InvalidTransition, "draft #{id} is #{status}, not pending" unless pending?

        update!(status: "rejected", reviewed_by: human, reviewed_at: Time.current,
                rejection_reason: reason.presence&.to_s)
        ticket.send(:reset_draft_associations!)
        ticket.send(:write_transition!, :draft_rejected, actor: human, request: request) do
          { "draft" => id.to_s, "assistant" => author_key, "reason" => reason.presence&.to_s }
        end
      end

      SupportDesk.emit_after_commit(:draft_rejected, ticket, self, by: human, reason: reason)
      self
    end

    # A newer proposal, a human reply, a takeover or a pause replaced it.
    # Idempotent, and writes no event: nobody decided anything.
    def supersede! # :nodoc:
      return self unless pending?

      update!(status: "superseded")
      self
    end

    # The case closed under it.
    def expire! # :nodoc:
      return self unless pending?

      update!(status: "expired")
      self
    end

    # The draft, in one line.
    def inspect
      "#<SupportDesk::Draft #{id} #{status} ticket=#{ticket_id} #{author_key}>"
    end

    private

    # A model wrote these, so the shape is whatever came back. `to_h` is the
    # generous reading (a list of pairs, a hash-like object) and it RAISES on
    # anything else — `["title", "x"]` is a TypeError, not a hash — so the
    # coercion answers nil and the validation below says what it wanted,
    # instead of taking the save down with an exception nobody can act on.
    def coerce_source(entry)
      return entry.stringify_keys if entry.is_a?(Hash)
      return nil if entry.is_a?(String) || !entry.respond_to?(:to_h)

      entry.to_h.stringify_keys
    rescue TypeError, ArgumentError
      nil
    end

    def body_or_files_present
      return if body.present? || files_attached?

      errors.add(:body, "can't be blank without an attachment")
    end

    # A model wrote these. They render as links in a console, so they are
    # checked like anything a stranger typed: a list, of pairs, with http(s)
    # URLs and nothing longer than a page can show.
    def sources_well_formed
      value = sources
      return if value.blank?

      unless value.is_a?(Array)
        errors.add(:sources, "must be a list of { title:, url: } entries")
        return
      end
      if value.size > MAX_SOURCES
        errors.add(:sources, "can't have more than #{MAX_SOURCES} entries (got #{value.size})")
        return
      end

      value.each do |original|
        entry = coerce_source(original)
        unless entry.is_a?(Hash)
          errors.add(:sources, "entries must be { title:, url: } hashes, got #{original.class}")
          next
        end

        title = entry["title"]
        url = entry["url"]
        errors.add(:sources, "every entry needs a title") if title.blank?
        errors.add(:sources, "a title can't be longer than #{MAX_SOURCE_TITLE} characters") if
          title.to_s.length > MAX_SOURCE_TITLE
        next if url.blank?

        errors.add(:sources, "a url can't be longer than #{MAX_SOURCE_URL} characters") if
          url.to_s.length > MAX_SOURCE_URL
        errors.add(:sources, "url #{url.inspect} must be http(s)") unless url.to_s.match?(%r{\Ahttps?://}i)
      end
    end
  end
end
