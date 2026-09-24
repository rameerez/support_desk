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
    has_many :message_registrations, class_name: "SupportDesk::MessageRegistration", dependent: :delete_all
    has_many :messages, through: :conversation, source: :messages

    # The assistant surface — the turn, the policy gates, her two verbs and
    # the two exits — in its own file. The GATES inside the verbs below stay
    # here, next to the verbs they guard: a reader looking at `close!` has to
    # see what stops a machine closing a case.
    include Assistance

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
      identity = arel_table[:opened_by_type].eq(arel_table[:requester_type])
                       .and(arel_table[:opened_by_id].eq(arel_table[:requester_id]))
      # Only 0.1 writes a NULL pair: automation openers are not supported.
      # Keep those inbound cases correct while the catch-up backfill runs.
      legacy = arel_table[:opened_by_type].eq(nil).and(arel_table[:opened_by_id].eq(nil))
      identity.or(legacy)
    end

    scope :opened_by_requester, -> { where(opened_by_requester_condition) }
    scope :opened_by_support, -> { where.not(opened_by_requester_condition) }

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
        ensure_opener!(opener, desk) if by_support

        # The subject is checked BEFORE the topic: "this isn't supportable" is
        # the useful error, and an unsupportable record has no topic to find.
        validate_subject!(about, requester)
        node = resolve_topic!(topic, about, desk, requester, about, by_support: by_support)
        # The topic is what caps her, so the cap is checked once it is known.
        ensure_assistant_may_open!(opener, requester, desk, node) if by_support && SupportDesk.ai_actor?(opener)

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

        current = record.class.uncached { record.class.find_by(id: record.id) }
        return if current&.support_requester?

        raise NotARequester, "#{record.class}##{record.id} can't ask for support or be written to right now " \
                             "(`has_support_tickets if:` says no, or the record is gone)"
      end

      # A loaded instance may predate revocation or deletion. Check the row,
      # just as requester eligibility does; this does not serialize revocation.
      #
      # Returns the FRESH record, so a caller that goes on to read a runtime
      # flag off it (the assistant's `active?`, which the policy reads) is
      # reading the row and not the copy it was handed (R9).
      def ensure_agent_record!(record) # :nodoc:
        if record.respond_to?(:persisted?) && record.persisted? && record.respond_to?(:support_agent?)
          current = record.class.uncached { record.class.find_by(id: record.id) }
          return current if current&.support_agent?
        end

        raise NotAnAgent, "#{record.class} is not a currently eligible, persisted support agent — " \
                         "declare `acts_as_support_agent` and check its if: condition"
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
      def ensure_opener!(opener, desk)
        if opener.is_a?(Symbol)
          raise NotAnAgent, "can't open a ticket as #{opener.inspect} — a case is opened by somebody who can " \
                            "answer it, and automation openers aren't supported yet; pass an agent record"
        end
        unless opener.respond_to?(:persisted?) && opener.persisted?
          raise NotAnAgent, "can't open a ticket as an unsaved #{opener.class} — save the agent first"
        end
        ensure_agent_record!(opener)
        return unless SupportDesk.ai_actor?(opener)

        # Writing to somebody who never wrote to you is the one thing an
        # assistant does that nobody asked for, so it takes its own
        # permission on top of everything else.
        unless opener.is_a?(SupportDesk::Assistant) && same_actor?(opener, desk.assistant)
          raise NotAnAssistant,
                "only desk #{desk.key}'s own assistant can open a case, and only when she may"
        end
        unless opener.may_open_conversations?
          raise AssistantNotAllowed.new(nil, verb: :open,
                                             message: "#{opener.key} may not open conversations — set " \
                                                      "`may_open_conversations = true` if that is the intent")
        end
        return if AssistantPolicy::RANK.fetch(opener.autonomy) >= AssistantPolicy::RANK.fetch(:reply)

        raise AssistantNotAllowed.new(nil, verb: :open,
                                           message: "#{opener.key} works at #{opener.autonomy}: opening a " \
                                                    "case means speaking first, which takes :reply")
      end

      # The topic's cap and the host's `cap` block, asked of the case this is
      # ABOUT to be. Her per-case budget is not checked here: a brand new
      # case has spent none of it, so the only way it could refuse is
      # `max_turns 0`, and the policy below covers her level anyway.
      def ensure_assistant_may_open!(opener, requester, desk, node)
        candidate = new(desk: desk, requester: requester, topic: node)
        policy = AssistantPolicy.for(candidate, opener)
        return if policy.may_reply?

        raise AssistantNotAllowed.new(policy, verb: :open)
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
        notices = [ post_opening_line!(ticket) ]

        posted = if by_support && SupportDesk.ai_actor?(by)
          notices << ticket.send(:post_disclosure_notice!, by) if by.notice?
          ticket.send(:post_assistant_opening!, message, files: files, assistant: by)
        elsif by_support
          # Never the inbound "no message, hand the ticket back" shortcut: a
          # desk that writes first with nothing to say is a chats validation
          # error, and this whole transaction goes with it.
          ticket.post_agent_message!(message, files: files, by: by)
        elsif message.present? || files.present?
          ticket.post_requester_message!(message, files: files)
        end

        ticket.send(:record_registration!, posted) if posted
        ticket.send(:stamp_assistant_action!) if by_support && SupportDesk.ai_actor?(by)
        pin_opening_lines!(ticket, notices, posted)
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
      def pin_opening_lines!(ticket, notices, posted)
        notices = Array(notices).compact
        return if notices.empty?

        anchor = posted&.created_at || ticket.opened_at
        # Backwards, one tick each, so the last line written sits closest to
        # the message and the first one opens the thread.
        notices.reverse.each_with_index do |notice, index|
          notice.update_columns(created_at: anchor - (ordering_tick * (index + 1)))
        end
        # When there IS a first message it owns the conversation's
        # last-message pointer and nothing needs repairing. When there isn't,
        # the notice is that pointer, and chats denormalised its timestamp
        # before we moved it — so the inbox would sort this conversation by a
        # moment its only message doesn't have.
        ticket.conversation.recompute_last_message! if posted.nil?
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
          # Only this private outreach path supplies the current turn internally.
          # Public replies must present the token their harness observed.
          ticket.send(:reply_under_lock!, message, by: by, files: files, request: request,
                                                   authorize: authorize_reuse, outreach: true)
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

      model = requester_type.safe_constantize
      current = model&.uncached { model.find_by(id: requester_id) }
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
      return true if opened_by_id.nil? && opened_by_type.nil?

      opened_by_id.present? && opened_by_type == requester_type && opened_by_id.to_s == requester_id.to_s
    end

    # NULL provenance is a legacy requester, never an automation opener.
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
    #
    # `by:` the assistant needs `turn:` and her policy's permission — see
    # SupportDesk::Ticket::Assistance. `metadata:` rides on the message
    # (provenance for a draft a human sent; hosts nest their own under
    # "host").
    def reply!(body = nil, by: nil, files: [], request: nil, metadata: {}, turn: nil)
      actor = resolve_actor(by)
      ensure_agent!(actor)
      reconcile_and_commit! if SupportDesk.ai_actor?(actor)

      reply_under_lock!(body, by: actor, files: files, request: request, metadata: metadata, turn: turn)
    end

    # An internal note: in the timeline and the console, never in the
    # conversation, never mirrored to any channel. Returns the Event.
    def note!(body, by: nil, request: nil, turn: nil)
      actor = resolve_actor(by)
      ensure_agent!(actor)
      machine = SupportDesk.ai_actor?(actor)
      raise ArgumentError, "a note needs something to say" if body.blank?

      assistant = nil
      event = write_transition!(:note, actor: actor, request: request) do
        if machine
          # Under the lock, from the row: a kill switch that commits while
          # this call waits for the case is a kill switch that stops it (R9).
          assistant = resolve_assistant!(actor)
          ensure_current_turn!(turn)
          policy = assistant_policy(assistant)
          raise AssistantNotAllowed.new(policy, verb: :note) unless policy.may_observe?
        end
        { "note" => body.to_s }
      end
      stamp_assistant_action! if assistant && event
      SupportDesk.emit_after_commit(:note_added, self, event) if event
      event
    end

    # Give the ticket to an agent. `assign!(to: lucia, by: lucia)` is
    # somebody taking it; `assign!(to: pedro, by: admin)` is somebody being
    # handed it. Repeating an assignment to the current holder does nothing.
    def assign!(to:, by: nil, reason: nil, note: nil, request: nil, turn: nil)
      actor = resolve_actor(by)
      ensure_agent!(actor)
      ensure_assignable!(to)

      reason ||= to == actor ? :taken : :assigned
      # A PERSON giving the case back to the assistant is the one action that
      # lifts the three human-side flags — and it says so out loud, in the
      # payload, because nothing else may clear them (I9).
      handing_back = SupportDesk.ai_actor?(to) && !SupportDesk.ai_actor?(actor)
      assignment = nil

      event = write_transition!(:assigned, actor: actor, request: request) do
        raise InvalidTransition, "can't assign a closed ticket — reopen it first" if closed?
        # Every mutable question about a seat is asked HERE, under the row
        # lock, from the reloaded row: who holds the case, what her policy
        # says, which turn she is on. Asked before the lock (0.3.0) they
        # were answers about a case that has since moved, and a stale
        # instance could take a seat a person had already been given (R2).
        ensure_assistant_may_assign!(actor, to, turn: turn)
        ensure_assistant_may_hold!(to)
        next false if assigned_to?(to)

        assignment = Assignment.open!(ticket: self, agent: to, by: actor, reason: reason, note: note)
        attributes = { assignee: to }
        if handing_back
          attributes.merge!(human_required_at: nil, human_required_reason: nil, assistant_paused_at: nil,
                            assistant_paused_reason: nil, assistant_cap: nil)
        end
        update!(attributes)
        { "assignee" => SupportDesk.actor_key(to), "reason" => reason.to_s,
          "handed_back" => (true if handing_back) }.compact
      end
      return self unless event

      announce_assignment!(to, first: assignments.count <= 1)
      SupportDesk.emit_after_commit(:ticket_assigned, self, assignment)
      emit_assistant_turn if handing_back && awaiting_reply?
      self
    end

    # `assign!` said by the person holding the ticket — with a note for
    # whoever picks it up. Hand-off notes are always internal.
    def hand_off!(to:, note: nil, by: nil, request: nil)
      actor = resolve_actor(by)
      ensure_agent!(actor)
      if SupportDesk.ai_actor?(actor)
        # She does not choose who picks a case up. `escalate!` is her way
        # out: it asks for a person rather than naming one.
        raise AssistantNotAllowed.new(assistant_policy(resolve_assistant!(actor)), verb: :hand_off)
      end
      ensure_assignable!(to)
      handing_back = SupportDesk.ai_actor?(to)
      from = nil
      assignment = nil
      event = write_transition!(:handed_off, actor: actor, request: request) do
        unless assigned_to?(actor)
          raise NotTheAssignee, "#{describe_actor(actor)} doesn't hold ticket #{reference} " \
                                "(#{assignee ? describe_actor(assignee) : "nobody"} does) — use assign! to override"
        end
        raise InvalidTransition, "can't hand off a closed ticket" if closed?
        ensure_assistant_may_hold!(to)
        next false if assigned_to?(to)

        from = assignee
        assignment = Assignment.open!(ticket: self, agent: to, by: actor, reason: :handed_off, note: note,
                                      release_reason: :handed_off)
        attributes = { assignee: to }
        if handing_back
          attributes.merge!(human_required_at: nil, human_required_reason: nil, assistant_paused_at: nil,
                            assistant_paused_reason: nil, assistant_cap: nil)
        end
        update!(attributes)
        { "from" => SupportDesk.actor_key(from), "to" => SupportDesk.actor_key(to), "note" => note,
          "handed_back" => (true if handing_back) }
      end
      return self unless event

      announce_assignment!(to, first: false)
      SupportDesk.emit_after_commit(:ticket_handed_off, self, assignment, from: from, note: note)
      emit_assistant_turn if handing_back && awaiting_reply?
      self
    end

    # Put the ticket back in the unassigned pile.
    def release!(by: nil, reason: :released, request: nil, turn: nil)
      actor = resolve_actor(by)
      ensure_agent!(actor)
      from = nil
      event = write_transition!(:released, actor: actor, request: request) do
        raise InvalidTransition, "can't release a closed ticket" if closed?
        assistant = (resolve_assistant!(actor) if SupportDesk.ai_actor?(actor))
        if assistant
          # Giving a seat back is an action like any other, so it holds the
          # turn it read: a run that finished after the case moved on must
          # not release the seat a newer one took (R2).
          ensure_current_turn!(turn)
          policy = assistant_policy(assistant)
          raise AssistantNotAllowed.new(policy, verb: :release) unless policy.may_observe?
          # Her own seat, and only hers: putting a PERSON's case back in the
          # pile is not something a machine gets to decide.
          raise AssistantNotAllowed.new(policy, verb: :release) unless assigned_to?(assistant)
        end
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
    def close!(by: nil, request: nil, turn: nil)
      actor = resolve_actor(by)
      ensure_agent!(actor)
      machine = SupportDesk.ai_actor?(actor)
      reconcile_and_commit! if machine

      event = write_transition!(:closed, actor: actor, request: request) do
        if machine
          # Resolved under the lock, so the kill switch is read after the
          # wait rather than before it (R9).
          assistant = resolve_assistant!(actor)
          lock_conversation!
          reconcile_unregistered_messages!
          ensure_current_turn!(turn)
          policy = assistant_policy(assistant)
          # Four conditions, and every one of them is somebody else's word:
          # her level allows it, she is the one holding the case, the
          # customer has the last word (so nothing is waiting for an answer)
          # and nobody has asked for a person.
          raise AssistantNotAllowed.new(policy, verb: :close) unless policy.may_close?
          raise AssistantNotAllowed.new(policy, verb: :close) unless assigned_to?(assistant)
          raise AssistantNotAllowed.new(policy, verb: :close) unless awaiting_requester?
          raise AssistantNotAllowed.new(policy, verb: :close) if human_required?
        end
        next false if closed?

        expired = expire_pending_drafts!
        assignments.open.each { |assignment| assignment.release!(reason: :closed) }
        update!(status: "closed", closed_at: Time.current, closed_by: record_actor(actor),
                awaiting: "none", waiting_since: nil)
        { "expired_drafts" => (expired if expired.positive?) }
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
      if SupportDesk.ai_actor?(actor)
        raise AssistantNotAllowed.new(assistant_policy(resolve_assistant!(actor)), verb: :reopen)
      end

      event = write_transition!(:reopened, actor: actor, request: request) do
        next false unless closed?

        # Read BEFORE the update clears it: whether the case we are bringing
        # back is one the assistant closed is the whole question behind the
        # cap below, and `closed_by` is where it is written down.
        closed_by_assistant = closed_by_type == SupportDesk::Assistant.polymorphic_name
        # Order matters: waiting_since is DERIVED from awaiting, so awaiting
        # has to be the reopened value before it is read. Computing both in
        # one update! hash reads the closed ticket's "none" and stores nil —
        # a reopened case that no SLA scope can see.
        assign_attributes(status: "open", closed_at: nil, closed_by: nil,
                          reopen_count: reopen_count.to_i + 1, awaiting: awaiting_from_clocks,
                          cardinality_key: "reopened:#{id}")
        self.waiting_since = waiting_since_from_clocks
        save!
        capped = restore_assignment!(by: actor, closed_by_assistant: closed_by_assistant)
        { "reopen_count" => reopen_count, "assistant_capped" => (true if capped) }.compact
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
      # Triage is where authority comes from — a topic decides the cap she
      # works under, so refiling her own case would be widening her own
      # policy (I10). 0.3 refuses it outright.
      if SupportDesk.ai_actor?(actor)
        raise AssistantNotAllowed.new(assistant_policy(resolve_assistant!(actor)), verb: :triage)
      end
      node = desk_config.topics.find(to.to_s) ||
             raise(UnknownTopic, "no topic #{to.inspect} on desk #{desk.key}")

      from = topic
      event = write_transition!(:topic_changed, actor: actor, request: request) do
        next false if topic == node

        update!(topic: node, priority: [ priority.to_i, node.priority ].max,
                cardinality_key: recomputed_cardinality_key(subject: subject, topic: node))
        # A refile onto a capped topic is a refile onto a case she may no
        # longer answer, so her seat goes with it — in the same transition,
        # so the queue never shows a machine holding a case it can't work.
        released = release_assistant_if_unfit!
        { "from" => from&.path, "to" => node.path, "assistant_released" => (true if released) }
      end
      return self unless event

      SupportDesk.emit_after_commit(:ticket_topic_changed, self, from: from, to: node, by: actor)
      self
    end

    # Point a free-form ticket at the record it turned out to be about.
    def attach_subject!(record, by: nil, request: nil)
      actor = resolve_actor(by)
      ensure_agent!(actor)
      # Same reason as `change_topic!`: what a case is ABOUT decides what may
      # be done on it, so a machine does not get to say.
      if SupportDesk.ai_actor?(actor)
        raise AssistantNotAllowed.new(assistant_policy(resolve_assistant!(actor)), verb: :triage)
      end
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
      # A machine's verbs are its policy's, filtered by the same state. Same
      # boundary, different vocabulary — see #assistant_actions_for.
      return assistant_actions_for(agent) if SupportDesk.ai_actor?(agent)
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
        if pending_draft
          actions << :send_draft if may_reply?(agent) && !requester_unavailable?
          actions << :reject_draft
        end
        actions << (assistant_paused? ? :resume_assistant : :pause_assistant) if assistant
      end
      actions
    end

    # Whether +agent+ may answer right now under this desk's reply policy.
    def may_reply?(agent)
      return false unless agent.respond_to?(:support_agent?) && agent.support_agent?
      # A case a machine is holding is a case any person may answer,
      # whatever the desk says about assignees: `:assignee_only` exists so
      # two people don't answer at once, and she is not one (I8).
      return true if held_by_assistant? && !SupportDesk.ai_actor?(agent)
      return true unless desk_config.reply_policy == :assignee_only

      assigned_to?(agent)
    end

    # Who should hear about activity on this ticket: whoever holds it, or
    # the whole on-duty pool while it's unheld. The gem computes it; the
    # host delivers it.
    def agents_to_notify
      # A case the assistant holds is a case no person has seen, so the pool
      # hears about it: notifying a machine is notifying nobody.
      return [ assignee ].compact if assigned? && !held_by_assistant?

      desk.on_duty_agents.to_a.reject { |agent| SupportDesk.ai_actor?(agent) }
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
    # `metadata:` is the provenance a message carries: who drafted it, what
    # policy allowed it, what the machine declared about it. Posted through
    # `messages.create!` rather than `desk.message!` for one reason only —
    # chats' sugar takes no metadata, and the validations are the same.
    def post_agent_message!(body, files: [], by:, metadata: {}) # :nodoc:
      attributes = { sender: desk, body: body, author: by }
      attributes[:files] = files if files.present?
      attributes[:metadata] = metadata if metadata.present?
      conversation.messages.create!(**attributes)
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

    # "Could she hold this case once the human-side flags were lifted?" —
    # the hand-back question, so the very flags a hand-back exists to clear
    # are not what refuses it. Her autonomy, the topic and the host's cap
    # block still decide.
    #
    # Asked UNDER THE LOCK (R2): a cap that lands while a take waits for the
    # row is the cap that applies to it.
    def ensure_assistant_may_hold!(agent)
      return unless SupportDesk.ai_actor?(agent)

      policy = assistant_policy(agent, hand_back: true)
      raise AssistantNotAllowed.new(policy, verb: :take) unless policy.may_hold?
    end

    # An assistant may take a case, and that is all: only herself, only when
    # nobody holds it, only at a level that may answer, and only holding the
    # turn she read. Called under the row lock, from the reloaded row.
    def ensure_assistant_may_assign!(actor, to, turn:)
      return unless SupportDesk.ai_actor?(actor)

      assistant = resolve_assistant!(actor)
      ensure_current_turn!(turn)
      policy = assistant_policy(assistant)
      unless self.class.same_actor?(actor, to)
        raise AssistantNotAllowed.new(policy, verb: :assign,
                                              message: "#{assistant.key} may not give #{reference} to " \
                                                       "anybody — an assistant can only take a case herself")
      end
      raise AssistantNotAllowed.new(policy, verb: :take) unless unassigned?
      raise AssistantNotAllowed.new(policy, verb: :take) unless policy.may_hold?
    end

    def ensure_agent!(actor)
      return if actor.is_a?(Symbol)
      # An AI-kind actor that is not a SupportDesk::Assistant is refused on
      # every write, by it or to it (I2). A host model declared `kind: :ai`
      # is a machine the gem knows nothing about, and treating it as a human
      # agent — which is what 0.2 did — hands it every human's authority.
      if SupportDesk.ai_actor?(actor) && !actor.is_a?(SupportDesk::Assistant)
        raise NotAnAssistant,
              "#{describe_actor(actor)} is declared `acts_as_support_agent kind: :ai` but isn't this gem's " \
              "assistant — configure one with `config.assistant` and act as SupportDesk.assistant(key)"
      end

      self.class.ensure_agent_record!(actor)
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
    def reply_under_lock!(body, by:, files:, request:, authorize: nil, metadata: {}, turn: nil, outreach: false)
      with_lock(requires_new: true) do
        authorize&.call(self)
        next assistant_reply_under_lock!(body, assistant: by, files: files, request: request,
                                               metadata: metadata, turn: turn, outreach: outreach) if SupportDesk.ai_actor?(by)

        # Fold committed inputs before a human answer too. A delayed callback
        # must not later turn an already-answered question back into work.
        lock_conversation!
        reconcile_unregistered_messages!
        ensure_writable!
        apply_reply_policy!(by, request: request)
        posted = post_agent_message!(body, files: files, by: by, metadata: metadata)
        # A person answering makes every machine proposal on this case out of
        # date — including one they are about to send, which is why the draft
        # being sent says so and is left alone.
        supersede_pending_drafts!(except: metadata.dig("support_desk", "draft_id"))
        record_registration!(posted)
        posted
      end
    end

    # `reply!` by the assistant: her full rules, under the lock the caller
    # already holds. Everything here is also what `respond!` runs — this is
    # the path for a host that decided to answer rather than ask policy.
    def assistant_reply_under_lock!(body, assistant:, files:, request:, metadata:, turn:, outreach: false)
      assistant = resolve_assistant!(assistant)
      # Private outreach supplies a token only after acquiring both locks;
      # public replies compare the caller's actual observed token.
      lock_conversation!
      reconcile_unregistered_messages!
      turn = assistant_turn if outreach
      ensure_current_turn!(turn)
      ensure_writable!

      policy = assistant_policy(assistant)
      raise AssistantNotAllowed.new(policy, verb: :reply) unless policy.may_reply?
      raise AssistantNotAllowed.new(policy, verb: :not_your_turn) unless awaiting_reply?

      left = assistant_turns_left
      raise AssistantNotAllowed.new(policy, verb: :max_turns) if left&.zero?

      speak!(body, assistant, policy: policy, turn: turn, files: files, confidence: nil, sources: [],
                              metadata: metadata, request: request)
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

        # This private path already validated the reply while holding the lock.
        # Seat-taking consumes the real current token, not a public sentinel.
        assign!(to: actor, by: actor, request: request, turn: assistant_turn)
      elsif !assigned_to?(actor)
        # Humans outrank assistants, under EVERY reply policy (I8). A person
        # answering a case a machine is holding takes it over: there is
        # nothing to ask about "who owns this" when one of the two can't
        # want it, and leaving her seated would keep her answering next.
        if held_by_assistant? && !SupportDesk.ai_actor?(actor)
          return assign!(to: actor, by: actor, reason: :drop_in_takeover, request: request, turn: assistant_turn)
        end
        # Belt: the `held_by_human` floor already turned this into a draft,
        # so an assistant reaching here is a bug, not a policy question.
        raise AssistantNotAllowed.new(assistant_policy(actor), verb: :reply) if SupportDesk.ai_actor?(actor)

        case policy
        when :assignee_only
          raise NotAllowed, "ticket #{reference} is held by #{describe_actor(assignee)} and this desk only " \
                            "lets the assignee reply"
        when :take_over
          assign!(to: actor, by: actor, reason: :drop_in_takeover, request: request, turn: assistant_turn)
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

      event = Event.record!(ticket: self, kind: kind, actor: actor, payload: payload.compact)
      # A real transition changed the case, so it moves the turn — a
      # no-op one wrote no event and moves nothing.
      bump_assistant_revision!
      event
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
      # "Rose se ocupa de tu consulta" is a promise about a person. Her
      # disclosure line is her announcement, and it is the only one.
      return if SupportDesk.ai_actor?(agent)

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
      unless message.persisted? && message.conversation_id == conversation_id
        raise ArgumentError, "message must belong to this ticket's conversation"
      end
      # Re-check under the lock: the same message can reach us twice (a
      # redelivered event, a hand-written replay), and an SLA clock that
      # moves twice for one message is a lie.
      return self if registered?(message)

      message_registrations.create!(message_id: message.id)
      role = role_of(message)
      opening = opening_message?
      reopened = false
      reopen_event = nil

      attributes = { last_registered_message_id: message.id }
      closed_by_assistant = false
      case role
      when :requester
        attributes[:last_requester_message_at] = [ last_requester_message_at, message.created_at ].compact.max
        # The pointer the turn's reconciliation reads: which requester
        # message the clocks are standing on, by id and not only by time.
        attributes[:last_requester_message_id] = message.id if after_requester_watermark?(message)
        if closed? && message.created_at > closed_at && desk_config.closed_tickets == :reopen_on_reply
          # Read before the merge below clears it — see #reopen!.
          closed_by_assistant = closed_by_type == SupportDesk::Assistant.polymorphic_name
          attributes.merge!(status: "open", closed_at: nil, closed_by: nil,
                            reopen_count: reopen_count.to_i + 1, cardinality_key: "reopened:#{id}")
          reopened = true
        end
      when :agent
        attributes[:last_agent_message_at] = [ last_agent_message_at, message.created_at ].compact.max
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
      self.awaiting = if closed?
        "none"
      elsif role == :requester
        "agent"
      else
        awaiting_from_clocks
      end
      self.waiting_since = waiting_since_from_clocks
      save!
      # Every registered message moves the case on, so every one of them
      # moves the turn: an assistant holding the turn she read a second ago
      # is holding a case that has not changed since (I4).
      bump_assistant_revision!

      if reopened
        capped = restore_assignment!(by: :system, closed_by_assistant: closed_by_assistant)
        reopen_event = record_transition!(:reopened, actor: requester) do
          { "via" => "requester_reply", "assistant_capped" => (true if capped) }.compact
        end
      end

      # After the bump, and after any reopen: the hook decides about a case
      # in the state this message left it in.
      evaluate_hand_off_phrase!(message) if role == :requester && !closed?

      publish_transition(reopen_event, :reopened, requester, nil) if reopen_event
      announce_registration(message, role: role, opening: opening, reopened: reopened)
      self
    end

    # Receipt identity, not transcript order, decides whether a callback is a
    # replay. A later commit may have an earlier timestamp or a smaller UUID.
    def registered?(message)
      message_registrations.exists?(message_id: message.id)
    end

    # Advance the requester clock pointer only in transcript order. Receipt
    # identity decides registration separately, so late arrivals cannot rewind
    # clocks or be discarded as replays.
    def after_requester_watermark?(message)
      watermark = last_requester_message_at
      return true if watermark.blank?
      return true if message.created_at > watermark
      return false if message.created_at < watermark
      # A tie with no pointer to break it (a 0.2 row whose backfill found
      # nothing) is new: the alternative silently drops it.
      return true if last_requester_message_id.blank?

      compare_message_ids(message.id, last_requester_message_id).positive?
    end

    # Order two chats message ids the way the DATABASE orders that column,
    # because the reconciliation query compares them in SQL and this one
    # compares them in Ruby. Integers compare numerically (10 is after 9);
    # anything else — a uuid, a ULID — compares as a string, which is how
    # every adapter orders those columns too.
    def compare_message_ids(one, other)
      if one.is_a?(Integer) && other.is_a?(Integer)
        one <=> other
      elsif integerish?(one) && integerish?(other)
        one.to_i <=> other.to_i
      else
        one.to_s <=> other.to_s
      end
    end

    def integerish?(value) = value.to_s.match?(/\A-?\d+\z/)

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
    def restore_assignment!(by:, closed_by_assistant: false)
      return false if unassigned?

      # A case the assistant closed and the customer reopened is a case she
      # got wrong (12 #21). It comes back to PEOPLE — unassigned, and capped
      # at :draft on this case for good, whatever her level is elsewhere. An
      # explicit hand-back is the only thing that lifts it, and the cap can
      # only tighten: an existing :observe stays :observe.
      if closed_by_assistant
        cap = [ assistant_cap&.to_sym, :draft ].compact.min_by { |level| AssistantPolicy::RANK.fetch(level) }
        update!(assignee: nil, assistant_cap: cap.to_s)
        return true
      end

      if assignee.respond_to?(:support_agent?) && assignee.support_agent?
        Assignment.open!(ticket: self, agent: assignee, by: by, reason: :reopened)
      else
        update!(assignee: nil)
      end
      false
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
        # The opening message included: a case that starts with a question
        # is a case with something to answer, and the harness should hear
        # about it the same way it hears about every later message.
        emit_assistant_turn(message)
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
          # "assistant" in every disclosure mode, silent ones included: what
          # a customer was told is a product decision, what an export says a
          # machine wrote is not.
          from: export_from(message),
          body: message.visible_body,
          attachments: message.try(:files)&.map { |file| file.try(:filename).to_s } || []
        }
      end
    end

    def export_from(message)
      return "you" if role_of(message) == :requester
      return "assistant" if assistant_message?(message)

      "support"
    end
  end
end
