# frozen_string_literal: true

module SupportDesk
  # A case — and a case is one conversation.
  #
  #   ticket = alice.ask_support!("El viaje no aparece verificado", about: ride)
  #   ticket.reference        # => "T-AB12CD"
  #   ticket.assign!(to: lucia, by: lucia)
  #   ticket.reply!("Hola, lo estamos revisando", by: lucia)
  #   ticket.close!(by: lucia)
  #
  # == The transitions
  #
  # Every transition takes `by:` (falling back to SupportDesk::Current.actor,
  # raising ActorMissing when there is nobody), runs under the ticket's row
  # lock, writes the ticket, its assignment row and exactly ONE event row in
  # one transaction, and emits its events only once that transaction has
  # committed. Repeating a transition that has already happened returns
  # `self` and writes nothing; a transition that can't happen from here
  # raises SupportDesk::InvalidTransition.
  #
  # == Awaiting, and the clocks
  #
  # `awaiting` says who owes the next word. It is maintained by #register!,
  # which the gem subscribes to chats' `:message_created` — so a message
  # typed in the app, mirrored in by email, or posted by a bot all move the
  # same clock, and nothing has to remember to call anything.
  class Ticket < ApplicationRecord
    self.table_name = "support_desk_tickets"

    STATUSES = %w[open snoozed closed].freeze
    AWAITING_STATES = %w[agent requester none].freeze
    CHANNELS = %i[in_app email intercom api].freeze

    # Crockford base32: no I, L, O or U, so a reference read aloud down a
    # phone line or typed from a screenshot can't come back wrong.
    REFERENCE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    REFERENCE_PREFIX = "T-"
    REFERENCE_LENGTH = 6
    REFERENCE_ATTEMPTS = 10

    acts_as_chat_subject

    belongs_to :desk, class_name: "SupportDesk::Desk", inverse_of: :tickets
    belongs_to :requester, polymorphic: true
    belongs_to :subject, polymorphic: true, optional: true
    belongs_to :assignee, polymorphic: true, optional: true
    belongs_to :conversation, class_name: "Chats::Conversation", optional: true
    belongs_to :closed_by, polymorphic: true, optional: true
    # Who opened the case: the requester when they asked, the agent when the
    # desk wrote first. A record, exactly like `closed_by`. Nullable only for
    # rows written by 0.1, which had no way to open a case as anybody else —
    # the upgrade migration backfills them to their requester and `doctor`
    # reports any that are left.
    belongs_to :opened_by, polymorphic: true, optional: true

    has_many :assignments, class_name: "SupportDesk::Assignment", inverse_of: :ticket, dependent: :destroy
    # :delete_all, not :destroy — an Event is readonly once written, and a
    # readonly record refuses to be destroyed. Deleting a ticket is the one
    # thing that takes its timeline with it, and it needs no callbacks.
    has_many :events, class_name: "SupportDesk::Event", inverse_of: :ticket, dependent: :delete_all
    has_many :messages, through: :conversation, source: :messages

    # Persist only the path. Resolving behavior needs this ticket's desk;
    # an attribute caster has no record context and cannot choose the tree.
    attribute :topic, Topic::Type.new
    attribute :metadata, default: -> { {} }

    def topic
      path = self[:topic]
      return if path.nil?

      desk_config.topics.find(path) || Topic::Unknown.new(path)
    end

    validates :status, inclusion: { in: STATUSES }
    validates :awaiting, inclusion: { in: AWAITING_STATES }
    validates :opened_via, inclusion: { in: CHANNELS }
    validates :reference, presence: true
    validate :opened_by_must_be_a_whole_record

    # --- Scopes ---------------------------------------------------------------

    scope :open, -> { where(status: "open") }
    scope :closed, -> { where(status: "closed") }
    scope :snoozed, -> { where(status: "snoozed") }
    scope :not_closed, -> { where.not(status: "closed") }

    scope :assigned, -> { where.not(assignee_id: nil) }
    scope :unassigned, -> { where(assignee_id: nil) }
    scope :assigned_to, lambda { |agent|
      where(assignee_type: agent.class.polymorphic_name, assignee_id: agent.id)
    }

    scope :awaiting_reply, -> { where(awaiting: "agent") }
    scope :awaiting_requester, -> { where(awaiting: "requester") }

    # The two halves of every case: the requester asked, or the desk wrote
    # first. They partition the table, NULL provenance included — a 0.1 row
    # nobody backfilled reads as "not the requester", which is exactly what
    # `doctor` wants somebody to come and look at.
    #
    # Built lazily, in a method rather than a constant: an Arel comparison
    # evaluated at class definition would consult the schema before
    # `db:migrate` had added the columns it names.
    def self.opened_by_requester_condition # :nodoc:
      arel_table[:opened_by_type].eq(arel_table[:requester_type])
        .and(arel_table[:opened_by_id].eq(arel_table[:requester_id]))
    end

    scope :opened_by_requester, -> { where(opened_by_requester_condition) }
    scope :opened_by_support, -> { where(opened_by_id: nil).or(where.not(opened_by_requester_condition)) }

    # Waiting longer than +duration+ for whoever owes the next word.
    scope :waiting_over, lambda { |duration|
      not_closed.where.not(waiting_since: nil).where(waiting_since: ..duration.ago)
    }
    # Waiting long enough to warn about, but not yet past the promise.
    scope :at_risk, ->(desk_key = nil) { past_sla(:at_risk_after, desk_key: desk_key, but_not: :reply_within) }
    # Past the promise (`config.reply_within`).
    scope :overdue, ->(desk_key = nil) { past_sla(:reply_within, desk_key: desk_key) }

    scope :about, ->(record) { where(subject_type: record.class.polymorphic_name, subject_id: record.id) }
    scope :about_any, ->(klass) { where(subject_type: klass.polymorphic_name) }
    # Includes descendants: `on_topic(:payments)` finds payments/withdrawal.
    scope :on_topic, lambda { |path|
      path = path.to_s
      where(topic: path).or(where(arel_table[:topic].matches("#{path}/%", nil, true)))
    }

    scope :for_desk, ->(key) { where(desk: SupportDesk.desk(key)) }
    scope :opened_via, ->(channel) { where(opened_via: channel.to_s) }
    scope :opened_between, ->(range) { where(opened_at: range) }
    scope :closed_between, ->(range) { where(closed_at: range) }

    scope :most_urgent_first, lambda {
      order(Arel.sql("#{table_name}.priority DESC, " \
                     "COALESCE(#{table_name}.waiting_since, #{table_name}.opened_at) ASC"))
    }
    scope :recent_activity_first, -> { order(updated_at: :desc) }
    scope :oldest_first, -> { order(opened_at: :asc, id: :asc) }
    scope :newest_first, -> { order(opened_at: :desc, id: :desc) }

    # --- Finding & opening ------------------------------------------------------

    class << self
      # Tickets whose wait has passed one of the desk's thresholds.
      #
      # Measured per DESK, not against whichever desk happens to be the
      # default: two desks can promise different things, and a billing desk
      # that answers in an hour must not be judged by a 24 hour promise.
      # Pass a key to ask about one desk, nothing to ask about all of them.
      def past_sla(threshold, desk_key: nil, but_not: nil)
        keys = desk_key ? [ desk_key.to_sym ] : SupportDesk.config.desks.keys
        clauses = keys.filter_map { |key| sla_clause(key, threshold, but_not) }
        return none if clauses.empty?

        awaiting_reply.not_closed.where.not(waiting_since: nil).where(clauses.reduce(:or))
      end

      # The ticket with this reference, case- and prefix-insensitive
      # ("t-ab12cd", "AB12CD" and "T-AB12CD" all find it), or nil.
      def find_by_reference(reference)
        normalized = normalize_reference(reference)
        return nil if normalized.nil?

        find_by(reference: normalized)
      end

      # Same, raising ActiveRecord::RecordNotFound.
      def find_by_reference!(reference)
        find_by_reference(reference) ||
          raise(ActiveRecord::RecordNotFound, "no ticket with reference #{reference.inspect}")
      end

      # The ticket behind a chats conversation, or nil — the hook the
      # `:message_created` subscriber comes in through.
      def for_conversation(conversation)
        return nil if conversation.nil?

        find_by(conversation_id: conversation.id)
      end

      # Open a ticket and post its first message. Usually called as
      # `requester.ask_support!(…)` — or, when the desk writes first, as
      # `agent.open_support_conversation_with!(…)`. This is the seam under
      # both, and the one channels and jobs use.
      #
      # `by:` is whoever is opening it and defaults to the requester; an
      # explicit nil means the same thing. An AGENT there is the desk writing
      # first: the message is the desk's, signed by them, they hold the case
      # from its first committed state, nobody is told "se ocupa de tu
      # consulta", and the requester's asking limits don't apply — those
      # limit asking, not being asked.
      #
      # Returns the existing open ticket when one already covers the same
      # subject (or, for free-form tickets, the same topic) — posting the
      # message into it as an ordinary reply, because somebody just typed it.
      def open!(requester:, message: nil, about: nil, topic: nil, files: [], via: :in_app,
                desk: nil, requester_role: nil, title: nil, metadata: {}, by: nil, request: nil)
        open_or_reply!(requester: requester, message: message, about: about, topic: topic, files: files,
                       via: via, desk: desk, requester_role: requester_role, title: title,
                       metadata: metadata, by: by, request: request)
      end

      # `open!`, plus the console's authorization seam. `authorize_reuse` is
      # called with the case this turned out to be a reply INTO — under its
      # row lock, before any policy side effect — so a host that allows
      # writing to somebody but not answering that particular case refuses
      # before anything is written, and a raise there takes the whole
      # operation with it. Everything else is `open!`; that is the method to
      # call.
      def open_or_reply!(requester:, message: nil, about: nil, topic: nil, files: [], via: :in_app,
                         desk: nil, requester_role: nil, title: nil, metadata: {}, by: nil, request: nil,
                         authorize_reuse: nil) # :nodoc:
        ensure_requester!(requester)
        desk ||= SupportDesk.desk
        opener = by.nil? ? requester : by
        # By persisted identity, never by ambient state: who asked is not
        # something to infer from Current.actor, and an agent passed as their
        # own requester is asking for help, not writing to themselves.
        by_support = !same_actor?(opener, requester)
        ensure_opener!(opener) if by_support

        # The subject is checked BEFORE the topic: "this isn't supportable" is
        # the useful error, and an unsupportable record has no topic to find.
        validate_subject!(about, requester)
        node = resolve_topic!(topic, about, desk, requester, about, by_support: by_support)

        cardinality = cardinality_key_for(requester: requester, subject: about, topic: node)
        existing = existing_for(requester: requester, desk: desk, subject: about, topic: node)
        enforce_asking_limits!(requester, desk) unless existing || by_support

        # ONE savepoint around the WHOLE operation, reuse included. A joined
        # transaction is not enough: a caller who rescues our failure and
        # commits its own would keep the ticket, the seat and the conversation
        # and lose only the message that was supposed to justify them.
        transaction(requires_new: true) do
          next reply_into!(existing, message, files: files, by: opener, by_support: by_support,
                           request: request, authorize_reuse: authorize_reuse) if existing

          created, inserted = insert_ticket!(
            requester: requester, desk: desk, node: node, about: about, via: via, opened_by: opener,
            by_support: by_support, requester_role: requester_role, title: title, metadata: metadata,
            cardinality_key: cardinality, request: request
          )

          # `inserted` is the only thing that knows whether THIS call opened
          # the case. Not the assignment, not the message count, not
          # `previously_new_record?` — the update two lines down resets it.
          if inserted
            post_opening!(created, message, files: files, by: opener, by_support: by_support)
            SupportDesk.emit_after_commit(:ticket_opened, created)
            created
          else
            # Somebody else's INSERT won by a millisecond. Theirs is the case
            # that exists, so this is a reply into it, policy and all.
            reply_into!(created, message, files: files, by: opener, by_support: by_support,
                        request: request, authorize_reuse: authorize_reuse)
          end
        end
      end

      # A human-friendly, unguessable-enough reference: "T-AB12CD".
      def generate_reference
        REFERENCE_PREFIX + Array.new(REFERENCE_LENGTH) { REFERENCE_ALPHABET[SecureRandom.random_number(32)] }.join
      end

      # A reference as it is stored: upper case, prefixed, and with
      # Crockford's lookalikes folded in.
      def normalize_reference(reference) # :nodoc:
        return nil if reference.nil?

        # Crockford's whole point: O reads as 0, I and L read as 1, so a
        # reference read down a phone line or typed off a screenshot still
        # finds its ticket.
        body = reference.to_s.strip.upcase.delete_prefix(REFERENCE_PREFIX).tr("OIL", "011")
        return nil if body.empty?

        REFERENCE_PREFIX + body
      end

      # The value the "one open ticket about this" index is built on: the
      # subject when there is one, the topic when there isn't, and a unique
      # value when the supportable said `one_open_ticket: false`.
      def cardinality_key_for(requester:, subject:, topic:) # :nodoc:
        if subject
          return "free:#{SecureRandom.uuid}" unless subject.class.one_open_support_ticket?

          "subject:#{SupportDesk.actor_key(subject)}"
        else
          "topic:#{topic.path}"
        end
      end

      # New submissions reuse an open case, including a reopened history.
      # Reopening itself never merges or discards a different conversation.
      def existing_for(requester:, desk:, subject:, topic:)
        return if subject && !subject.class.one_open_support_ticket?

        scope = not_closed.where(requester: requester, desk: desk, subject: subject)
        scope = scope.where(topic: topic.to_s) unless subject
        scope.newest_first.first
      end

      # The record on the requester side of every operation: saved, declared
      # with `has_support_tickets`, and eligible RIGHT NOW.
      #
      # Eligibility is re-read rather than taken from the record in hand: the
      # instance a caller is holding may have been loaded before the account
      # was closed, and "not yours" and "not eligible" must look the same from
      # outside. (It does not lock the host's closure transaction — see
      # #requester_unavailable?.)
      def ensure_requester!(record) # :nodoc:
        unless record.respond_to?(:support_requester?)
          raise NotARequester, "#{describe_record(record)} can't ask for support or be written to — " \
                               "declare `has_support_tickets` on #{record.class}"
        end
        unless record.persisted?
          raise NotARequester, "an unsaved #{record.class} can't ask for support — save it first"
        end

        current = record.class.find_by(id: record.id)
        return if current&.support_requester?

        raise NotARequester, "#{record.class}##{record.id} can't ask for support or be written to right now " \
                             "(`has_support_tickets if:` says no, or the record is gone)"
      end

      # Whether two actors are the same record. Not `==`: either side can be
      # nil, a Symbol or an unsaved record, and all of those must answer "no"
      # rather than raise or match on a nil id. STI subclasses compare by
      # their base name, because that is the identity the polymorphic columns
      # store — and two rows in one table can't share an id anyway.
      def same_actor?(one, other) # :nodoc:
        return false if one.nil? || other.nil? || one.is_a?(Symbol) || other.is_a?(Symbol)
        return false unless one.respond_to?(:persisted?) && other.respond_to?(:persisted?)
        return false unless one.persisted? && other.persisted?

        one.class.polymorphic_name == other.class.polymorphic_name && one.id.to_s == other.id.to_s
      end

      private

      # Who may speak for the desk: a saved, currently eligible agent.
      # Automation (`by: :system`) is refused by name rather than by
      # NoMethodError three frames in — it is deferred work, not a typo (see
      # docs/12-open-questions.md Q17).
      def ensure_opener!(opener)
        if opener.is_a?(Symbol)
          raise NotAnAgent, "can't open a ticket as #{opener.inspect} — a case is opened by somebody who can " \
                            "answer it, and automation openers aren't supported yet; pass an agent record"
        end
        unless opener.respond_to?(:persisted?) && opener.persisted?
          raise NotAnAgent, "can't open a ticket as an unsaved #{opener.class} — save the agent first"
        end
        return if opener.respond_to?(:support_agent?) && opener.support_agent?

        raise NotAnAgent, "#{describe_record(opener)} is not a support agent — declare " \
                          "`acts_as_support_agent` on #{opener.class}"
      end

      def describe_record(record)
        return record.inspect if record.nil? || record.is_a?(Symbol)

        "#{record.class}##{record.id}"
      end

      # "on this desk, and waiting longer than its own threshold" — with an
      # upper bound when the caller wants the band between two thresholds
      # (at risk, but not yet breached).
      def sla_clause(key, threshold, but_not)
        config = SupportDesk.config.desk(key)
        duration = config.public_send(threshold)
        return nil if duration.nil?

        clause = arel_table[:desk_id].in(Desk.where(key: key.to_s).select(:id).arel)
                                     .and(arel_table[:waiting_since].lteq(duration.ago))
        ceiling = but_not && config.public_send(but_not)
        ceiling ? clause.and(arel_table[:waiting_since].gt(ceiling.ago)) : clause
      end

      def resolve_topic!(topic, about, desk, requester, subject, by_support: false)
        node = locate_topic!(topic, about, desk)
        # An agent may file onto any topic in the tree, including ones no
        # requester is offered (`only:`) — the same latitude `change_topic!`
        # has, and the reason it exists: the desk knows what this is about.
        # The tree's other rule stands for everybody: a topic that needs
        # something to be about still needs it.
        if !by_support && !node.visible_for?(requester)
          raise NotAllowed, "#{requester.class}##{requester.id} may not open a ticket under topic " \
                            "#{node.path.inspect} (its only: condition says no)"
        end

        if node.subject_required? && subject.nil?
          raise NotAllowed, "topic #{node.path.inspect} needs something to be about — pass about:"
        end

        node
      end

      def locate_topic!(topic, about, desk)
        tree = desk.config.topics

        if topic
          tree.find(topic.to_s) ||
            raise(UnknownTopic, "no topic #{topic.inspect} on desk #{desk.key} " \
                                "(known: #{tree.map(&:path).sort.join(", ")})")
        elsif about
          path = about.respond_to?(:support_topic) ? about.support_topic : nil
          tree.find(path.to_s) ||
            raise(UnknownTopic, "#{about.class} is supportable under topic #{path.inspect}, which isn't in " \
                                "desk #{desk.key}'s topic tree")
        else
          tree.free_form_leaf ||
            raise(UnknownTopic, "desk #{desk.key} has no free-form topic to open a subject-less ticket under. " \
                                "Add `other` to its topics block, or pass topic:")
        end
      end

      def validate_subject!(about, requester)
        return if about.nil?

        unless about.respond_to?(:supportable?) && about.supportable?
          raise NotSupportable, "#{about.class} isn't supportable — add `supportable topic: :something` to it"
        end

        return if about.supportable_by?(requester)

        raise NotAllowed, "#{requester.class}##{requester.id} may not open a ticket about " \
                          "#{about.class}##{about.id}"
      end

      def open_ticket_for(requester:, desk:, cardinality_key:)
        not_closed.find_by(requester: requester, desk: desk, cardinality_key: cardinality_key)
      end

      # The two walls a requester can hit, and only they can: both count the
      # cases this person ASKED for. Five conversations the desk started must
      # never be what stops somebody asking their first question.
      def enforce_asking_limits!(requester, desk)
        enforce_rate_limit!(requester, desk)
        enforce_open_ticket_cap!(requester, desk)
      end

      def enforce_rate_limit!(requester, desk)
        limit = desk.config.open_rate_limit
        return if limit.nil?

        window = Time.current - limit[:within].to_i
        recent = opened_by_requester.where(requester: requester, desk: desk).where(opened_at: window..).count
        return if recent < limit[:to]

        raise RateLimited, "#{requester.class}##{requester.id} has opened #{recent} tickets in the last " \
                           "#{limit[:within].inspect} (limit #{limit[:to]})"
      end

      # The wall from 10 §Abuse. Checked before the insert and NOT under a
      # lock, so it is advisory by design: two requests racing about two
      # different things can both pass it and leave a requester one over.
      # The alternative is locking the host's own requester row on every
      # open, which trades a real contention risk for an imaginary
      # correctness one — nobody is harmed by a sixth open ticket.
      def enforce_open_ticket_cap!(requester, desk)
        cap = desk.config.max_open_tickets
        return if cap.nil?

        current = not_closed.opened_by_requester.where(requester: requester, desk: desk).count
        return if current < cap

        raise TooManyOpenTickets, "#{requester.class}##{requester.id} already has #{current} open tickets " \
                                  "(max_open_tickets is #{cap})"
      end

      # Create the ticket, its conversation and its `opened` event in one
      # transaction. A collision on the cardinality index means somebody
      # else opened the same ticket a millisecond ago — we hand back theirs.
      #
      # Returns [ticket, inserted?] so the caller can tell "I opened this"
      # from "I found this": they are the same ticket, and a very different
      # thing to announce.
      def insert_ticket!(requester:, desk:, node:, about:, via:, requester_role:, title:, metadata:,
                         cardinality_key:, opened_by:, by_support: false, request: nil)
        attempts = 0
        begin
          attempts += 1
          # A unique-index loser must roll back a savepoint before querying
          # the winner; PostgreSQL forbids reads in an aborted transaction.
          ticket, opened = transaction(requires_new: true) do
            ticket = create!(
              desk: desk, requester: requester, requester_role: requester_role, subject: about,
              topic: node, title: title.presence, reference: unique_reference, status: "open",
              awaiting: "agent", priority: node.priority, opened_via: via.to_s, opened_by: opened_by,
              opened_at: Time.current, cardinality_key: cardinality_key, metadata: metadata
            )
            # The pair is symmetric; the host's `can_message?` policy is not.
            # A conversation the DESK opens has to be asked about in that
            # direction, or a host that lets support write to anyone and
            # strangers write to nobody would refuse its own outreach.
            conversation = if by_support
              Chats::Conversation.direct_between!(desk, requester, about: ticket)
            else
              Chats::Conversation.direct_between!(requester, desk, about: ticket)
            end
            ticket.update!(conversation_id: conversation.id, waiting_since: ticket.opened_at)
            # The agent who wrote first holds the case from its first
            # committed state — silently. No `assign!`, so no "Lucía se ocupa
            # de tu consulta" in a thread the requester never started, and no
            # :ticket_assigned to page a team about their own message.
            if by_support
              Assignment.open!(ticket: ticket, agent: opened_by, by: opened_by, reason: :opened)
              ticket.update!(assignee: opened_by)
            end
            # Through the same writer every other transition uses (`send`
            # because it is private and we are the class, not the record),
            # so opening a ticket reaches `ticket_transitioned` too.
            opened = ticket.send(:record_transition!, :opened, actor: opened_by) do
              { "topic" => node.path, "via" => via.to_s,
                "assignee" => (SupportDesk.actor_key(opened_by) if by_support) }
            end
            [ ticket, opened ]
          end
          ticket.send(:publish_transition, opened, :opened, opened_by, request)
          [ ticket, true ]
        rescue ActiveRecord::RecordNotUnique
          existing = open_ticket_for(requester: requester, desk: desk, cardinality_key: cardinality_key)
          return [ existing, false ] if existing
          raise if attempts >= 2

          retry
        end
      end

      def unique_reference
        REFERENCE_ATTEMPTS.times do
          reference = generate_reference
          return reference unless exists?(reference: reference)
        end

        raise Error, "couldn't generate a free ticket reference in #{REFERENCE_ATTEMPTS} attempts"
      end

      # The first words of a brand new case, inside the transaction that
      # created it: the desk's opening line, the actual message, and the
      # clocks — folded in on THIS instance, so the row that commits is
      # already true and the caller needs no reload. chats' after-commit
      # subscriber then finds the message already registered and does
      # nothing.
      def post_opening!(ticket, message, files:, by:, by_support:)
        notice = post_opening_line!(ticket)

        posted = if by_support
          # Never the inbound "no message, hand the ticket back" shortcut: a
          # desk that writes first with nothing to say is a chats validation
          # error, and this whole transaction goes with it.
          ticket.post_agent_message!(message, files: files, by: by)
        elsif message.present? || files.present?
          ticket.post_requester_message!(message, files: files)
        end

        ticket.send(:record_registration!, posted) if posted
        pin_opening_line!(ticket, notice, posted)
        ticket
      end

      def post_opening_line!(ticket)
        line = ticket.desk_config.opening_line_for(ticket)
        return nil if line.blank?

        ticket.conversation.post_system_message!(line)
      end

      # chats orders a transcript by (created_at, id), and inserting one row
      # after another does NOT guarantee two different timestamps: frozen
      # time in a test, a coarse column, a clock that doesn't move between
      # two very fast inserts. Where ids are UUIDs there is then nothing
      # useful to break the tie with, and the notice can sort BELOW the
      # message it introduces.
      #
      # So the notice is pinned one database tick before that message, inside
      # the same transaction, using the timestamp the message actually got.
      # Only this new notice moves, never anybody's real message, and the
      # human message still owns the conversation's last-message pointer, so
      # nothing has to be recomputed afterwards.
      def pin_opening_line!(ticket, notice, posted)
        return if notice.nil?

        anchor = posted&.created_at || ticket.opened_at
        notice.update_columns(created_at: anchor - ordering_tick)
      end

      # One tick of the messages table's own timestamp column: the smallest
      # difference this database will still store.
      def ordering_tick
        precision = Chats::Message.columns_hash["created_at"]&.precision || 6
        (10**-precision).seconds
      end

      # Reuse is a reply, never a second opening. Both ways in — the case the
      # pre-check found and the one this call lost the insert race to — come
      # through here, so an existing case is answered under its row lock,
      # under the desk's reply policy, with the console's authorization hook
      # running before any of it.
      def reply_into!(ticket, message, files:, by:, by_support:, request:, authorize_reuse:)
        if by_support
          ticket.send(:reply_under_lock!, message, by: by, files: files, request: request,
                                                   authorize: authorize_reuse)
        else
          ticket.with_lock(requires_new: true) do
            authorize_reuse&.call(ticket)
            # A requester opening the same case again with nothing to say is
            # the old API's "hand it back": supported, and it writes nothing.
            next if message.blank? && files.blank?

            posted = ticket.post_requester_message!(message, files: files)
            ticket.send(:record_registration!, posted)
          end
        end

        ticket
      end
    end

    # --- Readers ----------------------------------------------------------------

    # What this ticket is called: its own title when a channel gave it one,
    # else the subject's label, else the topic's.
    def label
      title.presence || subject&.support_label || topic&.label || reference
    end

    # chats' context line for the conversation behind the ticket.
    def chat_subject_label = label

    # Whether chats should refuse new messages in this conversation: because
    # there is nobody to write to any more, or because the case is closed on
    # a desk configured `closed_tickets: :locked` (the default lets a
    # requester's reply reopen it instead).
    #
    # The first reason is a WRITE rule, not a screen rule: the transcript
    # stays readable, the case stays in the queue, and nothing is deleted —
    # only new messages stop. `open!` alone could not do this, because the
    # account can be closed long after the case was opened.
    def chat_locked?
      requester_unavailable? || (closed? && desk_config.closed_tickets == :locked)
    end

    # The reasons in the same order the refusal takes them, so the notice
    # under a composer and the error behind it never tell different stories.
    def chat_locked_notice
      return I18n.t("support_desk.thread.unavailable_notice") if requester_unavailable?

      I18n.t("support_desk.thread.closed_notice")
    end

    # Whether the person this case belongs to can be written to at all right
    # now: their record is gone, or `has_support_tickets if:` says no (a
    # closed account, a ban).
    #
    # Read FRESH from the database on purpose — the requester this instance
    # is holding may have been loaded before they closed their account, and a
    # cached association is not evidence about now. It still doesn't
    # serialize against the host's own closure transaction: an account closed
    # between this read and the write gets one more message in.
    def requester_unavailable?
      return true if requester_type.blank? || requester_id.blank?

      current = requester_type.safe_constantize&.find_by(id: requester_id)
      return true if current.nil?
      # A requester class that never declared the macro (an import, a legacy
      # row) has no opinion to honour, so it isn't "unavailable".
      return false unless current.respond_to?(:support_requester?)

      !current.support_requester?
    end

    def open? = status == "open"
    def closed? = status == "closed"
    def snoozed? = status == "snoozed"
    def assigned? = assignee_id.present?
    def unassigned? = !assigned?
    def reopened? = reopen_count.to_i.positive?

    # Who started this conversation. Read from the stored identity rather
    # than the association, so neither predicate loads a record to answer —
    # and so a case whose opener has since been deleted still answers.
    def opened_by_requester?
      opened_by_id.present? && opened_by_type == requester_type && opened_by_id.to_s == requester_id.to_s
    end

    # The other half: the desk wrote first. A 0.1 row with no provenance at
    # all reads as this one, which is why `doctor` asks somebody to look at
    # those rather than letting them pass as automation.
    def opened_by_support? = !opened_by_requester?

    # True when the desk owes the next word.
    def awaiting_reply? = awaiting == "agent"
    def awaiting_requester? = awaiting == "requester"

    def about?(record)
      return false if record.nil?

      subject_type == record.class.polymorphic_name && subject_id.to_s == record.id.to_s
    end

    def assigned_to?(agent)
      return false if agent.nil? || agent.is_a?(Symbol) || unassigned?

      assignee_type == agent.class.polymorphic_name && assignee_id.to_s == agent.id.to_s
    end

    # How long the current wait has been going on, or nil when nobody owes
    # anything.
    def waiting_for
      return nil if waiting_since.nil?

      ActiveSupport::Duration.build((Time.current - waiting_since).to_i)
    end

    # Waiting long enough to warn about, short of the promise.
    def at_risk?
      return false unless awaiting_reply? && waiting_for && desk_config.at_risk_after

      waiting_for >= desk_config.at_risk_after && !overdue?
    end

    # Past `config.reply_within`.
    def overdue?
      return false unless awaiting_reply? && waiting_for && desk_config.reply_within

      waiting_for >= desk_config.reply_within
    end

    # How long the requester waited for a first human answer. Nil for a case
    # the desk opened: nobody was waiting for it, and "how long from our own
    # first word to our own first word" is not a service level. Metrics (0.4)
    # is where that case gets a number, measured from the requester's first
    # message.
    def time_to_first_reply
      return nil if opened_by_support?
      return nil if first_agent_reply_at.nil? || opened_at.nil?

      ActiveSupport::Duration.build((first_agent_reply_at - opened_at).to_i)
    end

    # How long the case stayed open.
    def time_to_close
      return nil if closed_at.nil? || opened_at.nil?

      ActiveSupport::Duration.build((closed_at - opened_at).to_i)
    end

    # Which channel this ticket was opened through, as a Symbol.
    def opened_via
      super&.to_sym
    end

    # Every channel the case can be answered through. 0.1 ships in-app
    # only; the email channel adds to this list in 0.2.
    def channels = [ opened_via ].compact

    # "in app · email" — the channels, in the reader's language.
    def channels_summary
      channels.map { |channel| I18n.t("support_desk.channels.#{channel}") }.join(" · ")
    end

    # The internal notes agents left, newest last.
    def notes = events.notes.chronological

    # This desk's slice of the configuration — the thresholds and policies
    # that decide what this ticket's predicates mean.
    def desk_config
      desk&.config || SupportDesk.config.default_desk
    end

    # --- Transitions ------------------------------------------------------------

    # Answer the requester. The message is sent BY the desk and AUTHORED by
    # the agent, so the requester sees one counterpart with a signature and
    # the console knows who wrote it.
    #
    # Honours `config.reply_policy`: under :anyone an unheld ticket is taken
    # by whoever answers first and a drop-in on somebody else's ticket is
    # recorded; under :take_over the drop-in takes it; under :assignee_only
    # it raises SupportDesk::NotAllowed. Returns the Chats::Message.
    def reply!(body = nil, by: nil, files: [], request: nil)
      actor = resolve_actor(by)
      ensure_agent!(actor)

      reply_under_lock!(body, by: actor, files: files, request: request)
    end

    # An internal note: in the timeline and the console, never in the
    # conversation, never mirrored to any channel. Returns the Event.
    def note!(body, by: nil, request: nil)
      actor = resolve_actor(by)
      ensure_agent!(actor)
      raise ArgumentError, "a note needs something to say" if body.blank?

      event = write_transition!(:note, actor: actor, request: request) { { "note" => body.to_s } }
      SupportDesk.emit_after_commit(:note_added, self, event) if event
      event
    end

    # Give the ticket to an agent. `assign!(to: lucia, by: lucia)` is
    # somebody taking it; `assign!(to: pedro, by: admin)` is somebody being
    # handed it. Repeating an assignment to the current holder does nothing.
    def assign!(to:, by: nil, reason: nil, note: nil, request: nil)
      actor = resolve_actor(by)
      ensure_agent!(actor)
      ensure_assignable!(to)

      reason ||= to == actor ? :taken : :assigned
      assignment = nil

      event = write_transition!(:assigned, actor: actor, request: request) do
        raise InvalidTransition, "can't assign a closed ticket — reopen it first" if closed?
        next false if assigned_to?(to)

        assignment = Assignment.open!(ticket: self, agent: to, by: actor, reason: reason, note: note)
        update!(assignee: to)
        { "assignee" => SupportDesk.actor_key(to), "reason" => reason.to_s }
      end
      return self unless event

      announce_assignment!(to, first: assignments.count <= 1)
      SupportDesk.emit_after_commit(:ticket_assigned, self, assignment)
      self
    end

    # `assign!` said by the person holding the ticket — with a note for
    # whoever picks it up. Hand-off notes are always internal.
    def hand_off!(to:, note: nil, by: nil, request: nil)
      actor = resolve_actor(by)
      ensure_agent!(actor)
      ensure_assignable!(to)
      from = nil
      assignment = nil
      event = write_transition!(:handed_off, actor: actor, request: request) do
        unless assigned_to?(actor)
          raise NotTheAssignee, "#{describe_actor(actor)} doesn't hold ticket #{reference} " \
                                "(#{assignee ? describe_actor(assignee) : "nobody"} does) — use assign! to override"
        end
        raise InvalidTransition, "can't hand off a closed ticket" if closed?
        next false if assigned_to?(to)

        from = assignee
        assignment = Assignment.open!(ticket: self, agent: to, by: actor, reason: :handed_off, note: note,
                                      release_reason: :handed_off)
        update!(assignee: to)
        { "from" => SupportDesk.actor_key(from), "to" => SupportDesk.actor_key(to), "note" => note }
      end
      return self unless event

      announce_assignment!(to, first: false)
      SupportDesk.emit_after_commit(:ticket_handed_off, self, assignment, from: from, note: note)
      self
    end

    # Put the ticket back in the unassigned pile.
    def release!(by: nil, reason: :released, request: nil)
      actor = resolve_actor(by)
      ensure_agent!(actor)
      from = nil
      event = write_transition!(:released, actor: actor, request: request) do
        raise InvalidTransition, "can't release a closed ticket" if closed?
        next false if unassigned?

        from = assignee
        assignments.open.each { |assignment| assignment.release!(reason: reason) }
        update!(assignee: nil)
        { "from" => SupportDesk.actor_key(from), "reason" => reason.to_s }
      end
      return self unless event

      SupportDesk.emit_after_commit(:ticket_released, self, from: from, reason: reason.to_sym)
      self
    end

    # Close the case. Closing a closed ticket is a no-op, not an error.
    def close!(by: nil, request: nil)
      actor = resolve_actor(by)
      ensure_agent!(actor)

      event = write_transition!(:closed, actor: actor, request: request) do
        next false if closed?

        assignments.open.each { |assignment| assignment.release!(reason: :closed) }
        update!(status: "closed", closed_at: Time.current, closed_by: record_actor(actor),
                awaiting: "none", waiting_since: nil)
        {}
      end
      return self unless event

      SupportDesk.emit_after_commit(:ticket_closed, self, by: actor)
      self
    end

    # Bring a closed case back. Also what a requester's reply does on a desk
    # configured `closed_tickets: :reopen_on_reply` (the default).
    #
    # A reopened case goes back to whoever handled it, when they can still
    # take it: they already know the story. When they can't, it returns to
    # the pool.
    def reopen!(by: nil, request: nil)
      actor = resolve_actor(by)

      event = write_transition!(:reopened, actor: actor, request: request) do
        next false unless closed?

        # Order matters: waiting_since is DERIVED from awaiting, so awaiting
        # has to be the reopened value before it is read. Computing both in
        # one update! hash reads the closed ticket's "none" and stores nil —
        # a reopened case that no SLA scope can see.
        assign_attributes(status: "open", closed_at: nil, closed_by: nil,
                          reopen_count: reopen_count.to_i + 1, awaiting: awaiting_from_clocks,
                          cardinality_key: "reopened:#{id}")
        self.waiting_since = waiting_since_from_clocks
        save!
        restore_assignment!(by: actor)
        { "reopen_count" => reopen_count }
      end
      return self unless event

      SupportDesk.emit_after_commit(:ticket_reopened, self, by: actor)
      self
    end

    # Refile the case. Misfiling is normal — the wizard can only offer the
    # tree, and people describe problems in their own words.
    def change_topic!(to:, by: nil, request: nil)
      actor = resolve_actor(by)
      # Agents may file onto any topic in the tree, including ones no
      # requester is offered (`only:`); requesters may not file at all.
      ensure_agent!(actor)
      node = desk_config.topics.find(to.to_s) ||
             raise(UnknownTopic, "no topic #{to.inspect} on desk #{desk.key}")

      from = topic
      event = write_transition!(:topic_changed, actor: actor, request: request) do
        next false if topic == node

        update!(topic: node, priority: [ priority.to_i, node.priority ].max,
                cardinality_key: recomputed_cardinality_key(subject: subject, topic: node))
        { "from" => from&.path, "to" => node.path }
      end
      return self unless event

      SupportDesk.emit_after_commit(:ticket_topic_changed, self, from: from, to: node, by: actor)
      self
    end

    # Point a free-form ticket at the record it turned out to be about.
    def attach_subject!(record, by: nil, request: nil)
      actor = resolve_actor(by)
      ensure_agent!(actor)
      unless record.respond_to?(:supportable?) && record.supportable?
        raise NotSupportable, "#{record.class} isn't supportable — add `supportable topic: :something` to it"
      end

      event = write_transition!(:subject_attached, actor: actor, request: request) do
        next false if about?(record)

        update!(subject: record,
                cardinality_key: recomputed_cardinality_key(subject: record, topic: topic))
        { "subject" => SupportDesk.actor_key(record) }
      end
      return self unless event

      SupportDesk.emit_after_commit(:subject_attached, self, record, by: actor)
      self
    end

    # --- Message registration -----------------------------------------------------

    # Fold a chats message into the case: who owes the next word, the SLA
    # clocks, and a reopen when a requester writes into a closed ticket.
    #
    # Idempotent on the message id, so a redelivered event never
    # double-counts, and safe to call by hand after importing a transcript.
    def register!(message)
      return self if registered?(message)
      # System messages move nothing, however they arrive. chats never
      # delivers them here (Chats::Message#notify_host returns early for
      # them), so this guards direct calls and replayed imports — including
      # the opening line, which is posted inside the opening transaction and
      # must never be mistaken for somebody's first word.
      return self if role_of(message) == :system

      with_lock(requires_new: true) { record_registration!(message) }
      self
    end

    # --- Presenters ---------------------------------------------------------------

    # Everything an agent needs to see next to the transcript.
    def context_card = ContextCard.new(self)

    # One line for a list row, a Telegram message, a Slack block.
    def summary = Summary.new(self)

    # Messages and events merged by time — the unified activity view.
    def timeline = Timeline.new(self)

    # Who held this ticket, in order.
    def assignment_history = assignments.chronological

    # Exactly the verbs +agent+ may use on this case right now, filtered by
    # policy, status and duty.
    #
    # == This is authorization, not decoration
    #
    # It reads like a list of buttons and it is one, but `SupportDesk
    # ::Console` also REFUSES any verb this method doesn't return — a
    # console that renders one set of affordances and accepts a wider one
    # has a UI that lies, and two agents working the same queue hit that
    # every day: the second presses a button the first already made
    # impossible. So treat this as a security boundary:
    #
    # * Narrowing it takes a verb away from every console, silently. The
    #   button disappears AND the endpoint starts refusing.
    # * Widening it hands one out. Nothing else re-checks; the transitions
    #   raise for their own reasons, but "may this agent press this" is
    #   answered here and nowhere else.
    # * It must agree with `may_reply?` and with what the transitions
    #   actually allow. Where they disagree, an agent sees a button that
    #   only ever errors, or no button for something they may do.
    #
    # `test/console/console_offered_actions_test.rb` writes the expected set
    # down state by state and checks it twice — against this method, and
    # against what the console accepts over HTTP — so a change here fails a
    # test instead of quietly moving the boundary.
    def actions_for(agent)
      return [] unless agent.respond_to?(:support_agent?) && agent.support_agent?
      # Off duty is a real answer: the console can still show the case, and
      # an agent passing by can still leave a note, but nothing that speaks
      # to the requester is offered to somebody who isn't working.
      return [ :note ] if agent.respond_to?(:on_duty?) && !agent.on_duty?

      actions = [ :note ]
      if closed?
        actions << :reopen
      else
        # Nobody to write to is not the same as nothing to do: the transcript,
        # the notes and closing the case are all still here, and only the
        # thing that would speak to the requester is taken away.
        actions << :reply if may_reply?(agent) && !requester_unavailable?
        actions << :assign
        actions << :hand_off if assigned_to?(agent)
        actions << :release if assigned?
        actions << :change_topic
        actions << :close
      end
      actions
    end

    # Whether +agent+ may answer right now under this desk's reply policy.
    def may_reply?(agent)
      return false unless agent.respond_to?(:support_agent?) && agent.support_agent?
      return true unless desk_config.reply_policy == :assignee_only

      assigned_to?(agent)
    end

    # Who should hear about activity on this ticket: whoever holds it, or
    # the whole on-duty pool while it's unheld. The gem computes it; the
    # host delivers it.
    def agents_to_notify
      return [ assignee ].compact if assigned?

      desk.on_duty_agents.to_a
    end

    # Generic on purpose: a lock screen shouldn't spell out what somebody's
    # support case is about.
    def notification_title
      I18n.t("support_desk.notifications.title", desk: desk.name)
    end

    # Case detail for an authenticated feed. Do not use for push previews.
    def notification_body = label

    # A GDPR-friendly dump of the case as the requester experienced it:
    # their transcript and the status changes they saw, never internal
    # notes or hand-off reasoning.
    def export
      {
        reference: reference,
        label: label,
        topic: topic&.path,
        topic_label: topic&.full_label,
        subject: subject&.support_label,
        status: status,
        channels: channels.map(&:to_s),
        opened_at: opened_at,
        closed_at: closed_at,
        messages: export_messages,
        events: events.requester_visible.chronological.map do |event|
          { kind: event.kind, at: event.created_at }
        end
      }
    end

    # --- Internals -----------------------------------------------------------------

    # Post a message as the requester — what `ask_support!` says first, and
    # what an inbound channel replays.
    def post_requester_message!(body, files: []) # :nodoc:
      requester.message!(conversation, body, files: files)
    end

    # Post a message as the DESK, signed by the agent who wrote it — every
    # answer, and the desk's first word when it writes first. One place knows
    # "the desk sends, the human signs".
    def post_agent_message!(body, files: [], by:) # :nodoc:
      desk.message!(conversation, body, files: files, author: by)
    end

    def inspect
      "#<SupportDesk::Ticket #{reference} #{topic&.path} #{label.to_s.inspect} #{status}" \
        "#{" → #{describe_actor(assignee)}" if assigned?}#{waiting_description}>"
    end

    private

    def waiting_description
      return "" unless waiting_for

      state = awaiting_reply? ? "awaiting reply" : "awaiting requester"
      " (#{state} #{ActiveSupport::Duration.build(waiting_for.to_i).inspect})"
    end

    # --- Actors -------------------------------------------------------------------

    def resolve_actor(by)
      actor = by || Current.actor
      return actor if actor

      raise ActorMissing, "no actor: pass by: (an agent, a requester, or :system) or set " \
                          "SupportDesk::Current.actor"
    end

    def record_actor(actor) = actor.is_a?(Symbol) ? nil : actor

    # The ACTOR of a transition may be `:system` (a job, a sweep); the agent
    # a ticket is handed TO may not — somebody has to be able to answer it.
    def ensure_assignable!(agent)
      if agent.nil? || agent.is_a?(Symbol)
        raise NotAnAgent, "can't assign a ticket to #{agent.inspect} — pass an agent record"
      end

      ensure_agent!(agent)
    end

    def ensure_agent!(actor)
      return if actor.is_a?(Symbol)
      return if actor.respond_to?(:support_agent?) && actor.support_agent?

      raise NotAnAgent, "#{describe_actor(actor)} is not a support agent — declare " \
                        "`acts_as_support_agent` on #{actor.class}"
    end

    def describe_actor(actor)
      return actor.to_s if actor.nil? || actor.is_a?(Symbol)

      actor.try(:support_agent_name) || "#{actor.class}##{actor.id}"
    end

    # --- Transition plumbing -------------------------------------------------------

    # The two reasons a case takes no more messages, in the order the notice
    # under the composer gives them: there is nobody to write to, and only
    # then the closed-and-locked case.
    def ensure_writable!
      if requester_unavailable?
        raise Locked, "ticket #{reference} can't be written to: #{requester_type}##{requester_id} is no " \
                      "longer an eligible support requester. The case stays readable."
      end
      return unless chat_locked?

      raise Locked, "ticket #{reference} is closed and this desk locks closed tickets — reopen it first"
    end

    # Everything `reply!` does, under ONE lock and ONE savepoint: check that
    # the conversation still takes messages, apply the desk's reply policy,
    # post, and fold the message into the clocks before anything commits.
    #
    # The savepoint is not belt and braces: taking the ticket and announcing
    # it are part of answering, so a reply that raises (an empty body, a
    # locked conversation, a host policy) must not leave the agent holding a
    # case they never answered — not even when the caller rescues the raise
    # and commits its own transaction.
    #
    # `authorize:` is the console's hook (see Ticket.open_or_reply!): it runs
    # under this lock, before any policy side effect, and a raise there rolls
    # the whole thing back.
    def reply_under_lock!(body, by:, files:, request:, authorize: nil)
      with_lock(requires_new: true) do
        authorize&.call(self)
        ensure_writable!
        apply_reply_policy!(by, request: request)
        posted = post_agent_message!(body, files: files, by: by)
        record_registration!(posted)
        posted
      end
    end

    def apply_reply_policy!(actor, request: nil)
      # A closed case has no seat to take: an agent adding one last word
      # posts it and the case stays closed. (A REQUESTER writing is what
      # reopens it — see #register!.)
      return if closed?

      policy = desk_config.reply_policy

      if unassigned?
        if policy == :assignee_only
          raise NotAllowed, "ticket #{reference} is unassigned and this desk only lets the assignee reply — " \
                            "take it first"
        end

        assign!(to: actor, by: actor, request: request)
      elsif !assigned_to?(actor)
        case policy
        when :assignee_only
          raise NotAllowed, "ticket #{reference} is held by #{describe_actor(assignee)} and this desk only " \
                            "lets the assignee reply"
        when :take_over
          assign!(to: actor, by: actor, reason: :drop_in_takeover, request: request)
        else
          write_transition!(:drop_in, actor: actor, request: request) do
            { "assignee" => SupportDesk.actor_key(assignee) }
          end
        end
      end
    end

    # Run a transition under the row lock: yield, write exactly one event
    # row, and (once everything has committed) broadcast and emit. The block
    # returns the event payload, or false when there is nothing to do.
    def write_transition!(kind, actor:, request: nil, &block)
      event = nil
      with_lock { event = record_transition!(kind, actor: actor, &block) }
      publish_transition(event, kind, actor, request) if event
      event
    end

    # The half that writes, for callers who ALREADY hold the row (the
    # reopen inside #register!) or who are still inside the transaction that
    # created the ticket (the `opened` event). Returns the Event, or nil
    # when the block says there was nothing to do.
    def record_transition!(kind, actor:) # :nodoc:
      payload = yield
      return nil if payload == false || payload.nil?

      Event.record!(ticket: self, kind: kind, actor: actor, payload: payload.compact)
    end

    # The half that tells the world, once the write is durable. Every
    # transition goes through here — `ticket_transitioned` is the audit-log
    # hook, so a transition that skipped it would be a hole in the host's
    # audit trail, not a missing nicety.
    def publish_transition(event, kind, actor, request) # :nodoc:
      return nil if event.nil?

      broadcast_change
      SupportDesk.emit_after_commit(:ticket_transitioned, self, kind.to_sym, by: actor,
                                                                            request: request || Current.request,
                                                                            payload: event.payload)
      event
    end

    def announce_assignment!(agent, first:)
      mode = desk_config.announce_assignments
      return if mode == :never
      return if mode == :first_only && !first
      return unless agent.respond_to?(:support_agent_name)

      key = first ? "support_desk.system.assigned" : "support_desk.system.reassigned"
      conversation&.post_system_message!(I18n.t(key, agent: agent.support_agent_name))
    end

    # --- Registration plumbing ------------------------------------------------------

    # The half that writes, for callers who ALREADY hold the row: `reply!`
    # under its lock, and `Ticket.open!` while it still owns the uncommitted
    # row it just created. That is what keeps ONE method in charge of the
    # clocks — the opening message is folded in on the same instance, before
    # commit, so the row that lands is already true and nothing has to
    # reload.
    #
    # Everything is re-checked here rather than in the caller, because the
    # caller is not always the lock holder it thinks it is.
    def record_registration!(message) # :nodoc:
      return self if role_of(message) == :system
      # Re-check under the lock: the same message can reach us twice (a
      # redelivered event, a hand-written replay), and an SLA clock that
      # moves twice for one message is a lie.
      return self if registered?(message)

      role = role_of(message)
      opening = opening_message?
      reopened = false
      reopen_event = nil

      attributes = { last_registered_message_id: message.id }
      case role
      when :requester
        attributes[:last_requester_message_at] = message.created_at
        if closed? && message.created_at > closed_at && desk_config.closed_tickets == :reopen_on_reply
          attributes.merge!(status: "open", closed_at: nil, closed_by: nil,
                            reopen_count: reopen_count.to_i + 1, cardinality_key: "reopened:#{id}")
          reopened = true
        end
      when :agent
        attributes[:last_agent_message_at] = message.created_at
        # A first REPLY answers something. An agent message with no earlier
        # requester message is the desk opening the conversation, or a word
        # into an empty case — neither is a reply, and a requester clock that
        # is LATER (an out-of-order replay) is not evidence of one either.
        if first_agent_reply_at.nil? && last_requester_message_at.present? &&
           last_requester_message_at <= message.created_at
          attributes[:first_agent_reply_at] = message.created_at
        end
        # A closed case owes nobody anything. An agent adding one last
        # word keeps the clocks honest without putting the case back in a
        # queue that `close!` just took it out of.
      end

      assign_attributes(attributes)
      self.awaiting = closed? ? "none" : awaiting_from_clocks
      self.waiting_since = waiting_since_from_clocks
      save!

      if reopened
        restore_assignment!(by: :system)
        reopen_event = record_transition!(:reopened, actor: requester) { { "via" => "requester_reply" } }
      end

      publish_transition(reopen_event, :reopened, requester, nil) if reopen_event
      announce_registration(message, role: role, opening: opening, reopened: reopened)
      self
    end

    # Whether this message is already folded in. The last-id check catches
    # the common redelivery; the clock check catches the rest, because a
    # REPLAY can arrive in any order and an older message must never rewind
    # `awaiting`, restart an SLA clock, or reopen a case that was closed
    # after it.
    #
    # The comparison is `<=`, so a message whose timestamp already sits on
    # the clock counts as folded in: idempotency is the documented promise,
    # and the cost of the rare tie is one clock that doesn't advance until
    # the next message.
    def registered?(message)
      return true if last_registered_message_id.present? && last_registered_message_id.to_s == message.id.to_s

      clock = case role_of(message)
      when :requester then last_requester_message_at
      when :agent then last_agent_message_at
      end

      clock.present? && message.created_at <= clock
    end

    def opening_message?
      last_registered_message_id.blank? && last_requester_message_at.nil? && last_agent_message_at.nil?
    end

    # Who sent this message, in the only terms the case cares about.
    def role_of(message)
      return :system if message.respond_to?(:system?) && message.system?
      return :agent if same_record?(message.sender_type, message.sender_id, desk)
      return :requester if same_record?(message.sender_type, message.sender_id, requester)

      :system
    end

    def same_record?(type, id, record)
      return false if record.nil? || type.nil?

      type == record.class.polymorphic_name && id.to_s == record.id.to_s
    end

    # Provenance is a record or it is nothing: half a polymorphic pair points
    # at a class with no row, or a row with no class, and every predicate and
    # scope over it would have to guess. (Legacy rows have NEITHER, which is
    # a shape we can read and `doctor` can report.)
    def opened_by_must_be_a_whole_record
      return if opened_by_type.nil? == opened_by_id.nil?

      errors.add(:opened_by, "needs both a type and an id, or neither")
    end

    # What "one open ticket about this" means for this ticket, recomputed
    # because the case now says it is about something else. Refusing a
    # collision here is the point: silently keeping the old key leaves the
    # thing it used to be about blocked, and the thing it IS about free for
    # a second ticket.
    def recomputed_cardinality_key(subject:, topic:)
      key = self.class.cardinality_key_for(requester: requester, subject: subject, topic: topic)
      conflict = self.class.not_closed.where(requester: requester, desk: desk, cardinality_key: key)
                     .where.not(id: id).first
      if conflict
        raise InvalidTransition,
              "#{requester.class}##{requester.id} already has an open ticket about that " \
              "(#{conflict.reference}) — close or merge it first"
      end

      key
    end

    # Reopening restores the last holder's seat (reason "reopened") when
    # they can still answer, so `assignee` and the open assignment row never
    # disagree on a live ticket. A closed ticket keeps its assignee as the
    # record of who dealt with it, with no open row — that pair is the one
    # shape `doctor` expects to see.
    def restore_assignment!(by:)
      return if unassigned?

      if assignee.respond_to?(:support_agent?) && assignee.support_agent?
        Assignment.open!(ticket: self, agent: assignee, by: by, reason: :reopened)
      else
        update!(assignee: nil)
      end
    end

    def awaiting_from_clocks
      return "agent" if last_requester_message_at && (last_agent_message_at.nil? ||
                        last_requester_message_at > last_agent_message_at)
      return "requester" if last_agent_message_at

      "agent"
    end

    def waiting_since_from_clocks
      case awaiting
      when "agent" then last_requester_message_at || opened_at
      when "requester" then last_agent_message_at
      end
    end

    def announce_registration(message, role:, opening:, reopened:)
      broadcast_change

      SupportDesk.emit_after_commit(:ticket_reopened, self, by: requester) if reopened

      case role
      when :requester
        SupportDesk.emit_after_commit(:requester_replied, self, message) unless opening
      when :agent
        # The desk's OWN first word announces nothing: it is the start of a
        # conversation the requester never asked for, not an answer to one,
        # and `:ticket_opened` has already said it. An agent's first message
        # into an old empty case the REQUESTER opened is a reply, which is
        # why this asks who opened the case and not just whether the clocks
        # are empty.
        SupportDesk.emit_after_commit(:agent_replied, self, message) unless opening && opened_by_support?
      end
    end

    # --- Realtime --------------------------------------------------------------------

    # Turbo 8 refreshes for the two console surfaces: the ticket page and
    # the queue. Requester-side realtime is chats'.
    def broadcast_change
      return unless respond_to?(:broadcast_refresh_later_to)

      ActiveRecord.after_all_transactions_commit do
        broadcast_refresh_later_to(self, :console)
        broadcast_refresh_later_to(desk, :queue)
      end
    rescue StandardError => e
      SupportDesk.logger&.warn("[support_desk] broadcast failed for ticket #{id}: #{e.class}: #{e.message}")
    end

    def export_messages
      return [] if conversation.nil?

      conversation.messages.visible.oldest_first.map do |message|
        {
          at: message.created_at,
          from: role_of(message) == :requester ? "you" : "support",
          body: message.visible_body,
          attachments: message.try(:files)&.map { |file| file.try(:filename).to_s } || []
        }
      end
    end
  end
end
