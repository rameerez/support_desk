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
    CHANNELS = %w[in_app email intercom api].freeze

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

    has_many :assignments, class_name: "SupportDesk::Assignment", inverse_of: :ticket, dependent: :destroy
    # :delete_all, not :destroy — an Event is readonly once written, and a
    # readonly record refuses to be destroyed. Deleting a ticket is the one
    # thing that takes its timeline with it, and it needs no callbacks.
    has_many :events, class_name: "SupportDesk::Event", inverse_of: :ticket, dependent: :delete_all
    has_many :messages, through: :conversation, source: :messages

    # `ticket.topic` is a Topic, never a String — the tree is the thing that
    # carries behaviour, so the column casts both ways.
    attribute :topic, Topic::Type.new
    attribute :metadata, default: -> { {} }

    validates :status, inclusion: { in: STATUSES }
    validates :awaiting, inclusion: { in: AWAITING_STATES }
    validates :opened_via, inclusion: { in: CHANNELS }
    validates :reference, presence: true

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

    # Waiting longer than +duration+ for whoever owes the next word.
    scope :waiting_over, lambda { |duration|
      not_closed.where.not(waiting_since: nil).where(waiting_since: ..duration.ago)
    }
    # Waiting long enough to warn about, but not yet past the promise.
    scope :at_risk, lambda { |desk_key = :default|
      config = SupportDesk.config.desk(desk_key)
      relation = awaiting_reply.waiting_over(config.at_risk_after)
      config.reply_within ? relation.where.not(waiting_since: ..config.reply_within.ago) : relation
    }
    # Past the promise (`config.reply_within`).
    scope :overdue, lambda { |desk_key = :default|
      awaiting_reply.waiting_over(SupportDesk.config.desk(desk_key).reply_within)
    }

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
      # `requester.ask_support!(…)`; this is the seam channels and jobs use.
      #
      # Returns the existing open ticket when one already covers the same
      # subject (or, for free-form tickets, the same topic) — posting the
      # message into it, because somebody just typed it.
      def open!(requester:, message: nil, about: nil, topic: nil, files: [], via: :in_app,
                desk: nil, requester_role: nil, title: nil, metadata: {})
        desk ||= SupportDesk.desk
        # The subject is checked BEFORE the topic: "this isn't supportable" is
        # the useful error, and an unsupportable record has no topic to find.
        validate_subject!(about, requester)
        node = resolve_topic!(topic, about, desk)

        cardinality = cardinality_key_for(requester: requester, subject: about, topic: node)
        existing = open_ticket_for(requester: requester, desk: desk, cardinality_key: cardinality)
        return post_opening_message(existing, message, files) if existing

        enforce_rate_limit!(requester, desk)
        enforce_open_ticket_cap!(requester, desk)

        ticket = insert_ticket!(
          requester: requester, desk: desk, node: node, about: about, via: via,
          requester_role: requester_role, title: title, metadata: metadata, cardinality_key: cardinality
        )

        post_opening_message(ticket, message, files)
        SupportDesk.emit_after_commit(:ticket_opened, ticket)
        ticket
      end

      # A human-friendly, unguessable-enough reference: "T-AB12CD".
      def generate_reference
        REFERENCE_PREFIX + Array.new(REFERENCE_LENGTH) { REFERENCE_ALPHABET[SecureRandom.random_number(32)] }.join
      end

      def normalize_reference(reference) # :nodoc:
        return nil if reference.nil?

        body = reference.to_s.strip.upcase.delete_prefix(REFERENCE_PREFIX)
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

      private

      def resolve_topic!(topic, about, desk)
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

      def enforce_rate_limit!(requester, desk)
        limit = desk.config.open_rate_limit
        return if limit.nil?

        window = Time.current - limit[:within].to_i
        recent = where(requester: requester, desk: desk).where(opened_at: window..).count
        return if recent < limit[:to]

        raise RateLimited, "#{requester.class}##{requester.id} has opened #{recent} tickets in the last " \
                           "#{limit[:within].inspect} (limit #{limit[:to]})"
      end

      def enforce_open_ticket_cap!(requester, desk)
        cap = desk.config.max_open_tickets
        return if cap.nil?

        current = not_closed.where(requester: requester, desk: desk).count
        return if current < cap

        raise TooManyOpenTickets, "#{requester.class}##{requester.id} already has #{current} open tickets " \
                                  "(max_open_tickets is #{cap})"
      end

      # Create the ticket, its conversation and its `opened` event in one
      # transaction. A collision on the cardinality index means somebody
      # else opened the same ticket a millisecond ago — we hand back theirs.
      def insert_ticket!(requester:, desk:, node:, about:, via:, requester_role:, title:, metadata:,
                         cardinality_key:)
        attempts = 0
        begin
          attempts += 1
          transaction do
            ticket = create!(
              desk: desk, requester: requester, requester_role: requester_role, subject: about,
              topic: node, title: title.presence, reference: unique_reference, status: "open",
              awaiting: "agent", priority: node.priority, opened_via: via.to_s,
              opened_at: Time.current, cardinality_key: cardinality_key, metadata: metadata
            )
            conversation = Chats::Conversation.direct_between!(requester, desk, about: ticket)
            ticket.update!(conversation_id: conversation.id, waiting_since: ticket.opened_at)
            Event.record!(ticket: ticket, kind: "opened", actor: requester,
                          payload: { "topic" => node.path, "via" => via.to_s })
            ticket
          end
        rescue ActiveRecord::RecordNotUnique
          existing = open_ticket_for(requester: requester, desk: desk, cardinality_key: cardinality_key)
          return existing if existing
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

      def post_opening_message(ticket, message, files)
        ticket.post_requester_message!(message, files: files) if message.present? || files.present?
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

    # Whether chats should refuse new messages in this conversation. Only
    # true for closed tickets on a desk configured `closed_tickets:
    # :locked` — the default lets a requester's reply reopen the case.
    def chat_locked?
      closed? && desk_config.closed_tickets == :locked
    end

    def chat_locked_notice
      I18n.t("support_desk.thread.closed_notice")
    end

    def open? = status == "open"
    def closed? = status == "closed"
    def snoozed? = status == "snoozed"
    def assigned? = assignee_id.present?
    def unassigned? = !assigned?
    def reopened? = reopen_count.to_i.positive?

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

    # How long the requester waited for a first human answer.
    def time_to_first_reply
      return nil if first_agent_reply_at.nil? || opened_at.nil?

      ActiveSupport::Duration.build((first_agent_reply_at - opened_at).to_i)
    end

    # How long the case stayed open.
    def time_to_close
      return nil if closed_at.nil? || opened_at.nil?

      ActiveSupport::Duration.build((closed_at - opened_at).to_i)
    end

    # Which channel this ticket was opened through, as a Symbol.
    def opened_via_channel = opened_via&.to_sym

    # Every channel the case can be answered through. 0.1 ships in-app
    # only; the email channel adds to this list in 0.2.
    def channels = [ opened_via_channel ].compact

    def channels_summary
      channels.map { |channel| I18n.t("support_desk.channels.#{channel}", default: channel.to_s) }.join(" · ")
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
      ensure_writable!

      apply_reply_policy!(actor, request: request)
      desk.message!(conversation, body, files: files, author: actor)
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
      ensure_agent!(to)
      raise InvalidTransition, "can't assign a closed ticket — reopen it first" if closed?

      reason ||= to == actor ? :taken : :assigned
      assignment = nil

      event = write_transition!(:assigned, actor: actor, request: request) do
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
      unless assigned_to?(actor)
        raise NotTheAssignee, "#{describe_actor(actor)} doesn't hold ticket #{reference} " \
                              "(#{assignee ? describe_actor(assignee) : "nobody"} does) — use assign! to override"
      end
      ensure_agent!(to)
      raise InvalidTransition, "can't hand off a closed ticket" if closed?

      from = assignee
      assignment = nil
      event = write_transition!(:handed_off, actor: actor, request: request) do
        next false if assigned_to?(to)

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
      raise InvalidTransition, "can't release a closed ticket" if closed?

      from = assignee
      event = write_transition!(:released, actor: actor, request: request) do
        next false if unassigned?

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

        update!(status: "open", closed_at: nil, closed_by: nil, reopen_count: reopen_count.to_i + 1,
                awaiting: awaiting_from_clocks, waiting_since: waiting_since_from_clocks)
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
      node = desk_config.topics.find(to.to_s) ||
             raise(UnknownTopic, "no topic #{to.inspect} on desk #{desk.key}")

      from = topic
      event = write_transition!(:topic_changed, actor: actor, request: request) do
        next false if topic == node

        update!(topic: node, priority: [ priority.to_i, node.priority ].max)
        { "from" => from&.path, "to" => node.path }
      end
      return self unless event

      SupportDesk.emit_after_commit(:ticket_topic_changed, self, from: from, to: node, by: actor)
      self
    end

    # Point a free-form ticket at the record it turned out to be about.
    def attach_subject!(record, by: nil, request: nil)
      actor = resolve_actor(by)
      unless record.respond_to?(:supportable?) && record.supportable?
        raise NotSupportable, "#{record.class} isn't supportable — add `supportable topic: :something` to it"
      end

      event = write_transition!(:subject_attached, actor: actor, request: request) do
        next false if about?(record)

        update!(subject: record)
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

      role = nil
      opening = false
      reopened = false
      applied = false

      with_lock do
        # Re-check under the lock: the same message can reach us twice (a
        # redelivered event, a hand-written replay), and an SLA clock that
        # moves twice for one message is a lie.
        next if registered?(message)

        role = role_of(message)
        opening = opening_message?
        applied = true

        attributes = { last_registered_message_id: message.id }
        case role
        when :requester
          attributes[:awaiting] = "agent"
          attributes[:last_requester_message_at] = message.created_at
          if closed? && desk_config.closed_tickets == :reopen_on_reply
            attributes.merge!(status: "open", closed_at: nil, closed_by: nil,
                              reopen_count: reopen_count.to_i + 1)
            reopened = true
          end
        when :agent
          attributes[:awaiting] = "requester"
          attributes[:last_agent_message_at] = message.created_at
          attributes[:first_agent_reply_at] = message.created_at if first_agent_reply_at.nil?
        end

        assign_attributes(attributes)
        self.waiting_since = waiting_since_from_clocks
        save!

        if reopened
          restore_assignment!(by: :system)
          Event.record!(ticket: self, kind: "reopened", actor: requester,
                        payload: { "via" => "requester_reply" })
        end
      end

      announce_registration(message, role: role, opening: opening, reopened: reopened) if applied
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

    # Exactly the buttons a console should render for +agent+, filtered by
    # policy, status and duty.
    def actions_for(agent)
      return [] unless agent.respond_to?(:support_agent?) && agent.support_agent?

      actions = [ :note ]
      if closed?
        actions << :reopen
      else
        actions << :reply if may_reply?(agent)
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

    # The detail, for the body — visible after unlock.
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

    def ensure_writable!
      return unless chat_locked?

      raise InvalidTransition, "ticket #{reference} is closed and this desk locks closed tickets — reopen it first"
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
    def write_transition!(kind, actor:, request: nil)
      event = nil

      with_lock do
        payload = yield
        next if payload == false || payload.nil?

        event = Event.record!(ticket: self, kind: kind, actor: actor, payload: payload.compact)
      end

      if event
        broadcast_change
        SupportDesk.emit_after_commit(:ticket_transitioned, self, kind.to_sym, by: actor,
                                                                              request: request || Current.request,
                                                                              payload: event.payload)
      end
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

    def registered?(message)
      last_registered_message_id.present? && last_registered_message_id.to_s == message.id.to_s
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
        SupportDesk.emit_after_commit(:agent_replied, self, message)
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
