# frozen_string_literal: true

module SupportDesk
  class Ticket
    # Everything a case knows about its assistant: the turn, the policy
    # gates, the two verbs that are hers alone (`respond!`, `draft!`), the
    # two exits (`escalate!`, `request_human!`) and the human override
    # (`pause_assistant!`).
    #
    # == The turn
    #
    # `assistant_revision` is an integer bumped by every registered message
    # and every transition. `assistant_turn` is that integer, spelled as an
    # opaque string, and EVERY assistant action requires it and consumes it:
    #
    #   turn = ticket.assistant_turn          # "t7-r12"
    #   ticket.respond!(answer, by: rose, turn: turn)
    #
    # A model takes seconds to answer, and a customer can write again while
    # it does. The turn is what makes that safe: the action is compared
    # against the case's current revision under its row lock, and a late,
    # retried or redelivered one raises SupportDesk::StaleTurn and writes
    # nothing. It is also why there are no idempotency keys, claim rows or
    # leases in this gem — one integer under the lock already answers "is
    # this still the case you read?".
    #
    # == Gate the action, never the evidence
    #
    # Policy decides what she may PRODUCE. It never decides what a person can
    # see: the transcript, the case, the queue and the door to a human are
    # the same whatever the level, and a refusal is always a named reason on
    # a record (an `assistant_withheld` event, a policy in a draft's
    # metadata), never silence.
    module Assistance
      extend ActiveSupport::Concern

      included do
        has_many :drafts, class_name: "SupportDesk::Draft", inverse_of: :ticket, dependent: :destroy
        has_one :pending_draft, -> { pending }, class_name: "SupportDesk::Draft", inverse_of: :ticket

        # --- Scopes -------------------------------------------------------------

        scope :held_by_assistants, lambda {
          where(assignee_type: SupportDesk::Assistant.polymorphic_name)
        }
        scope :held_by_humans, lambda {
          assigned.where.not(assignee_type: SupportDesk::Assistant.polymorphic_name)
        }
        # The tab that exists so a case a machine could not finish is never
        # the one nobody looks at.
        scope :needs_human, -> { where.not(human_required_at: nil) }
        scope :assistant_paused, -> { where.not(assistant_paused_at: nil) }
        scope :assistant_capped, -> { where.not(assistant_cap: nil) }
        scope :resolved_by_assistant, lambda {
          closed.where(closed_by_type: SupportDesk::Assistant.polymorphic_name)
        }
        scope :with_pending_draft, -> { where(id: SupportDesk::Draft.pending.select(:ticket_id)) }
        # Waiting on the desk since before +time+, with nothing from the
        # assistant since the customer wrote: a harness that is down, or one
        # that keeps deciding to do nothing.
        scope :assistant_idle_since, lambda { |time|
          awaiting_reply.where(last_requester_message_at: ..time)
                        .where("assistant_acted_at IS NULL OR assistant_acted_at < last_requester_message_at")
        }
      end

      # --- Readers ------------------------------------------------------------------

      # The assistant who works this case's desk, or nil.
      def assistant = desk&.assistant

      # What she may do here, right now, and why. See AssistantPolicy.
      def assistant_policy(assistant = self.assistant, hand_back: false)
        AssistantPolicy.for(self, assistant, hand_back: hand_back)
      end

      # The token every assistant action has to hold. Never nil: a case that
      # has never been touched still has a turn, which is what makes "the
      # turn you read" a complete answer rather than a special case.
      def assistant_turn = "t#{id}-r#{assistant_revision.to_i}"

      # Whether this case has anything to do with an assistant — configured
      # on the desk now, or spoken in by one at any point. History counts:
      # the door to a person must not vanish because somebody edited an
      # initializer after she answered.
      def assistant_in_play?
        assistant.present? || assistant_turns_count.to_i.positive?
      end

      def held_by_assistant?
        assigned? && assignee_type == SupportDesk::Assistant.polymorphic_name
      end

      # Whether a person has been asked for on this case — by the assistant,
      # by the requester, or by the silent sweep.
      def human_required? = human_required_at.present?

      # Whether a human has switched her off on this case.
      def assistant_paused? = assistant_paused_at.present?

      # How many times she may still speak here; nil when unlimited.
      def assistant_turns_left
        max = assistant&.max_turns
        return nil if max.nil?

        [ max - assistant_turns_count.to_i, 0 ].max
      end

      # The conversation as ordered turns — the readable half of what a
      # harness works from. `limit:` keeps the LAST n, which is the part
      # still being answered. See SupportDesk::Transcript.
      def transcript(limit: nil)
        Transcript.new(self, limit: limit)
      end

      # Everything a machine needs to answer this case, as data: the desk,
      # the policy, the case, the requester and the transcript.
      # `include_internal: true` adds the desk's own notes and proposals —
      # off by default, because it leaves the building. See
      # SupportDesk::Brief.
      def brief(include_internal: false, transcript_limit: 50)
        Brief.new(self, include_internal: include_internal, transcript_limit: transcript_limit)
      end

      # Whether this message came from an assistant — by authorship when she
      # signs, by the provenance stamp when she doesn't. Both shapes, because
      # a host that changes disclosure mode must not rewrite old bubbles.
      def assistant_message?(message)
        return false if message.nil?

        return true if message.author.is_a?(SupportDesk::Assistant)

        stamp = message.try(:metadata)
        stamp.is_a?(Hash) && stamp.dig("support_desk", "assistant").present?
      end

      # --- Her two verbs ------------------------------------------------------------

      # Answer, and let policy decide what that means: sent to the requester,
      # proposed as a draft for a person to send, or withheld. The ONE verb a
      # harness needs — it never has to encode the rules it is working under.
      #
      # Returns a SupportDesk::Outcome. Raises StaleTurn when the case moved
      # on, Locked when there is nobody to write to, NotAnAssistant when
      # `by:` isn't this desk's assistant.
      def respond!(body = nil, by:, turn:, files: [], confidence: nil, sources: [], metadata: {}, request: nil)
        assistant = resolve_assistant!(by)
        raise ArgumentError, "respond! needs something to say" if body.blank? && files.blank?

        with_lock(requires_new: true) do
          reconcile_unregistered_messages!
          ensure_current_turn!(turn)
          ensure_writable!
          policy = assistant_policy(assistant)
          next withhold!(assistant, policy, :policy, request: request) unless policy.may_draft?
          next withhold!(assistant, policy, :not_your_turn, request: request) unless awaiting_reply?

          left = assistant_turns_left
          if policy.may_reply? && (left.nil? || left.positive?)
            message = speak!(body, assistant, policy: policy, turn: turn, files: files, confidence: confidence,
                                              sources: sources, metadata: metadata, request: request)
            Outcome.new(action: :sent, message: message, policy: policy, turn: assistant_turn)
          else
            draft = propose_draft!(body, assistant, policy: policy, files: files, confidence: confidence,
                                                    sources: sources, metadata: metadata)
            reason = nil
            # Out of budget at a level that could otherwise have answered:
            # the draft stays, and so does a person — a conversation that
            # ran out of turns is one somebody has to finish.
            if policy.may_reply? && left&.zero?
              flag_human_required!(actor: assistant, kind: :escalated, reason: "max_turns",
                                   summary: metadata[:summary] || metadata["summary"],
                                   line: :hand_off_line, request: request)
              reason = :max_turns
            end
            Outcome.new(action: :drafted, draft: draft, policy: policy, reason: reason, turn: assistant_turn)
          end
        end
      end

      # Propose a reply for a person to send, whatever the level allows.
      # `respond!` is what a harness should call; this is for a host that has
      # already decided it wants a draft. Returns the SupportDesk::Draft.
      def draft!(body = nil, by:, turn:, files: [], confidence: nil, sources: [], metadata: {}, request: nil)
        assistant = resolve_assistant!(by)
        raise ArgumentError, "draft! needs something to say" if body.blank? && files.blank?

        with_lock(requires_new: true) do
          reconcile_unregistered_messages!
          ensure_current_turn!(turn)
          ensure_writable!
          policy = assistant_policy(assistant)
          raise AssistantNotAllowed.new(policy, verb: :draft) unless policy.may_draft?

          propose_draft!(body, assistant, policy: policy, files: files, confidence: confidence,
                                          sources: sources, metadata: metadata)
        end
      end

      # --- The two exits ------------------------------------------------------------

      # Hand the case to a person: the assistant's own way out, and what the
      # silent sweep calls as `:system`. Releases her seat, records the
      # reason, raises the priority and tells the requester.
      #
      # `turn:` is required when `by:` is the assistant — escalating is an
      # action like any other, and a stale one must not speak.
      def escalate!(by: nil, reason:, summary: nil, turn: nil, request: nil)
        actor = resolve_actor(by)
        ensure_agent!(actor)
        assistant = (resolve_assistant!(actor) if SupportDesk.ai_actor?(actor))
        raise ArgumentError, "escalate! needs a reason" if reason.blank?

        event = nil
        from = nil
        with_lock(requires_new: true) do
          if assistant
            ensure_current_turn!(turn)
            policy = assistant_policy(assistant)
            raise AssistantNotAllowed.new(policy, verb: :escalate) unless policy.may_observe?
          end

          event, from = flag_human_required!(actor: actor, kind: :escalated, reason: reason, summary: summary,
                                             line: :hand_off_line, request: request)
        end
        return self unless event

        stamp_assistant_action! if assistant
        SupportDesk.emit_after_commit(:ticket_escalated, self, from: from, reason: reason.to_sym, by: actor)
        self
      end

      # "Prefiero hablar con una persona." The requester's own door, and the
      # one thing on this case they can always do: it reopens a closed case
      # where the desk allows it, flags the case, and says so in the thread.
      # Idempotent — pressing it twice writes once.
      def request_human!(by: nil, request: nil)
        actor = resolve_actor(by)
        unless self.class.same_actor?(actor, requester)
          raise NotAllowed,
                "#{describe_actor(actor)} can't ask for a person on #{reference} — it isn't their case"
        end

        event = nil
        with_lock(requires_new: true) do
          reopen!(by: actor, request: request) if closed? && desk_config.closed_tickets == :reopen_on_reply
          ensure_writable!
          event, = flag_human_required!(actor: actor, kind: :human_requested, reason: "requester_request",
                                        summary: nil, line: :human_requested_line, request: request)
        end
        return self unless event

        SupportDesk.emit_after_commit(:human_requested, self, by: actor, reason: :requester_request)
        self
      end

      # --- The human override -------------------------------------------------------

      # Switch the assistant off on THIS case: a delicate conversation, a
      # customer who has had enough, a thread somebody wants to handle
      # themselves. Releases her seat, throws away her pending proposal, and
      # floors her policy at :off until somebody resumes her.
      def pause_assistant!(by: nil, reason: nil, request: nil)
        actor = resolve_actor(by)
        if actor.is_a?(Symbol) || SupportDesk.ai_actor?(actor)
          raise NotAllowed, "only a person can pause the assistant on a case"
        end
        ensure_agent!(actor)

        event = write_transition!(:assistant_paused, actor: actor, request: request) do
          raise InvalidTransition, "can't pause the assistant on a closed case" if closed?
          next false if assistant_paused?

          release_assistant_seat!(reason: :released)
          supersede_pending_drafts!
          update!(assistant_paused_at: Time.current, assistant_paused_reason: reason.presence&.to_s)
          { "reason" => reason.presence&.to_s }
        end
        return self unless event

        SupportDesk.emit_after_commit(:assistant_paused, self, by: actor)
        self
      end

      # Let her back in on this case. Clears the pause and NOTHING ELSE: a
      # case cap and a request for a person are different decisions, made by
      # different people, and only an explicit hand-back lifts those.
      def resume_assistant!(by: nil, request: nil)
        actor = resolve_actor(by)
        if actor.is_a?(Symbol) || SupportDesk.ai_actor?(actor)
          raise NotAllowed, "only a person can resume the assistant on a case"
        end
        ensure_agent!(actor)

        event = write_transition!(:assistant_resumed, actor: actor, request: request) do
          next false unless assistant_paused?

          update!(assistant_paused_at: nil, assistant_paused_reason: nil)
          {}
        end
        return self unless event

        SupportDesk.emit_after_commit(:assistant_resumed, self, by: actor)
        emit_assistant_turn if awaiting_reply?
        self
      end

      # --- Internals ----------------------------------------------------------------

      # The verbs the assistant may press on this case right now — the
      # machine's half of `actions_for`, and the same decision the
      # transitions make, so a harness reading `may` from a brief is reading
      # the authorization and not a hint.
      def assistant_actions_for(assistant) # :nodoc:
        return [] unless assistant.is_a?(SupportDesk::Assistant)
        return [] unless self.class.same_actor?(assistant, self.assistant)

        verbs = assistant_policy(assistant).allowed_verbs.dup
        verbs -= %i[escalate] if closed?
        verbs -= %i[reply draft take] if requester_unavailable?
        verbs -= %i[take] unless unassigned?
        verbs -= %i[release] unless assigned_to?(assistant)
        verbs -= %i[reply] unless awaiting_reply?
        verbs -= %i[close] unless assigned_to?(assistant) && awaiting_requester? && !human_required?
        verbs
      end

      # Bump the case's revision — the caller holds the lock. `update_columns`
      # on purpose: inside the transaction, no callbacks, no validations, and
      # the in-memory value moves with the row, so the turn a caller reads
      # next is the one the database has.
      def bump_assistant_revision! # :nodoc:
        update_columns(assistant_revision: assistant_revision.to_i + 1)
      end

      # When the assistant last did anything here — what the idle-turn check
      # and the redispatch task read to tell "she decided not to speak" from
      # "nothing is running".
      def stamp_assistant_action! # :nodoc:
        update_columns(assistant_acted_at: Time.current)
      end

      private

      # The actor, as this desk's assistant — or a refusal that names which
      # of the three things went wrong. Every AI-kind actor comes through
      # here: a host model declared `kind: :ai` is not an assistant, and
      # another desk's assistant is not this desk's (I2).
      def resolve_assistant!(actor)
        unless actor.is_a?(SupportDesk::Assistant)
          raise NotAnAssistant,
                "#{describe_actor(actor)} is an AI agent but not a SupportDesk::Assistant — only the desk's " \
                "configured assistant may act on a case"
        end
        unless self.class.same_actor?(actor, assistant)
          raise NotAnAssistant,
                "#{actor.key} is not desk #{desk.key}'s assistant"
        end

        # Fresh from the row: `active` is a cross-process kill switch, and a
        # record loaded a minute ago is not evidence about now.
        self.class.ensure_agent_record!(actor)
        actor
      end

      # The turn check, under the lock, from the revision the row holds.
      def ensure_current_turn!(turn)
        raise ArgumentError, "turn: is required for an assistant — pass the turn you read" if turn.nil?
        return if turn.to_s == assistant_turn

        raise StaleTurn,
              "#{turn} is stale on #{reference}: the case has changed (now #{assistant_turn})"
      end

      # Fold in any requester message chats has committed but the gem hasn't
      # folded in yet, under the lock, BEFORE the turn is checked (I5).
      #
      # The subscriber runs after commit and the assistant's job runs on
      # another connection: without this, a message the customer sent a
      # millisecond ago would be invisible to the turn, and she would answer
      # around it. Folding it in here makes the turn stale instead, which is
      # exactly what should happen.
      def reconcile_unregistered_messages!
        return if conversation.nil?

        scope = conversation.messages.where(kind: "text", sender_type: requester_type, sender_id: requester_id)
        if last_requester_message_at.present?
          scope = if last_requester_message_id.present?
            # Everything after the clock, plus anything sharing its instant
            # that ISN'T the message the clock was set from — two messages
            # can land on one timestamp, and the second one is real.
            scope.where(
              "chats_messages.created_at > :at OR (chats_messages.created_at = :at AND chats_messages.id <> :id)",
              at: last_requester_message_at, id: last_requester_message_id
            )
          else
            # No pointer to compare against (a 0.2 row whose backfill found
            # nothing): the clock alone, rather than a comparison against an
            # empty string that some adapters refuse outright.
            scope.where("chats_messages.created_at > ?", last_requester_message_at)
          end
        end

        scope.oldest_first.each { |message| record_registration!(message) }
      end

      # Nothing was written, and the reason is on the record: a policy that
      # refused is evidence, not silence.
      def withhold!(assistant, policy, reason, request: nil)
        event = record_transition!(:assistant_withheld, actor: assistant) do
          { "assistant" => assistant.key, "reason" => reason.to_s, "policy" => policy.to_h }
        end
        stamp_assistant_action!
        publish_transition(event, :assistant_withheld, assistant, request)
        SupportDesk.emit_after_commit(:assistant_withheld, self, assistant, reason: reason, policy: policy)
        Outcome.new(action: :withheld, reason: reason, policy: policy, turn: assistant_turn)
      end

      # Say it to the requester. The caller holds the lock and has already
      # decided she may.
      def speak!(body, assistant, policy:, turn:, files:, confidence:, sources:, metadata:, request:)
        notice = (post_disclosure_notice!(assistant) if assistant.notice? && !disclosure_posted?(assistant))
        apply_reply_policy!(assistant, request: request)

        stamped = assistant_message_metadata(assistant, policy: policy, turn: turn, confidence: confidence,
                                                        sources: sources, host: metadata)

        # `author: nil` in the nameless modes, so chats prints no signature
        # and the requester sees the desk — while the metadata above still
        # says exactly what wrote it, for staff, for export and for audit.
        posted = post_agent_message!(body, files: files, by: (assistant if assistant.signs?), metadata: stamped)
        pin_before!(notice, posted) if notice
        record_registration!(posted)
        update_columns(assistant_turns_count: assistant_turns_count.to_i + 1)
        stamp_assistant_action!
        posted
      end

      # What every machine-written message carries: who wrote it, under what
      # disclosure, holding which turn, and the whole policy that allowed it.
      #
      # The host's own metadata is NESTED under "host" rather than merged:
      # the "support_desk" key is the gem's evidence, and a host writing
      # `policy` into it would be rewriting it.
      def assistant_message_metadata(assistant, policy:, turn:, confidence: nil, sources: [], host: {})
        stamped = { "support_desk" => {
          "assistant" => assistant.key,
          "kind" => "ai",
          "display_name" => assistant.disclosed_name,
          "disclosure" => assistant.disclosure.to_s,
          "signed" => assistant.signs?,
          "turn" => turn.to_s,
          "confidence" => confidence,
          "sources" => sources.presence,
          "policy" => policy.to_h
        }.compact }
        stamped["host"] = host if host.present?
        stamped
      end

      # The desk's first word, when it is hers. Called from inside the
      # transaction that created the case (see Ticket.post_opening!), where
      # she is already seated and there is no earlier turn for anybody to
      # have held — so the first turn is the one this message consumes.
      def post_assistant_opening!(body, files:, assistant:)
        policy = assistant_policy(assistant)
        stamped = assistant_message_metadata(assistant, policy: policy, turn: assistant_turn)
        posted = post_agent_message!(body, files: files, by: (assistant if assistant.signs?), metadata: stamped)
        update_columns(assistant_turns_count: 1)
        posted
      end

      # Write the proposal. Validated BEFORE the pending one is superseded:
      # a draft that can't be saved must not take the previous one with it.
      def propose_draft!(body, assistant, policy:, files: [], confidence: nil, sources: [], metadata: {})
        candidate = drafts.new(author: assistant, proposed_turn: assistant_turn, body: body,
                               confidence: confidence, sources: sources || [],
                               metadata: { "policy" => policy.to_h, "host" => metadata.presence }.compact)
        candidate.files = files if files.present? && candidate.respond_to?(:files=)
        candidate.validate!

        # One pending proposal per case. The row lock serialises this, so
        # there is no unique-violation to rescue: supersede, then insert.
        drafts.pending.each(&:supersede!)
        bump_assistant_revision!
        # The turn this proposal LEAVES the case at, not the one it answered
        # — a proposal is itself a change, so stamping the turn it consumed
        # would make every draft stale the moment it was written.
        candidate.proposed_turn = assistant_turn
        candidate.save!
        reset_draft_associations!
        stamp_assistant_action!
        broadcast_change
        SupportDesk.emit_after_commit(:draft_proposed, self, candidate)
        candidate
      end

      # The notice a `:notice` mode opens with, posted once per disclosure
      # MODE: a host that changes mode discloses again, and one that doesn't
      # never repeats itself.
      def post_disclosure_notice!(assistant)
        line = assistant.config.line_for(:disclosure_line, self)
        if line.blank?
          raise ConfigurationError,
                "assistant #{assistant.key} discloses with a notice but has no disclosure_line — " \
                "an undisclosed autonomous message is never posted silently"
        end

        notice = conversation.post_system_message!(line)
        disclosed = (metadata["assistant_disclosed"] || {}).merge(assistant.key.to_s => assistant.disclosure.to_s)
        update!(metadata: metadata.merge("assistant_disclosed" => disclosed))
        notice
      end

      def disclosure_posted?(assistant)
        metadata.dig("assistant_disclosed", assistant.key.to_s) == assistant.disclosure.to_s
      end

      # chats orders a transcript by (created_at, id), and two inserts in one
      # transaction can share a timestamp — so a notice is pinned one
      # database tick before the message it introduces, exactly as the
      # opening line is.
      def pin_before!(notice, message)
        return if notice.nil? || message.nil?

        notice.update_columns(created_at: message.created_at - self.class.send(:ordering_tick))
      end

      # The one write behind both hand-offs: release her seat, record who
      # asked and why, raise the priority, and say so in the thread.
      # Returns [event, previous assignee] — nil event when it was a no-op.
      def flag_human_required!(actor:, kind:, reason:, summary:, line:, request:)
        from = nil
        event = write_transition!(kind, actor: actor, request: request) do
          raise InvalidTransition, "can't #{kind} a closed case — reopen it first" if closed?
          next false if human_required?

          from = assignee
          release_assistant_seat!(reason: :escalated)
          update!(human_required_at: Time.current, human_required_reason: reason.to_s,
                  priority: [ priority.to_i, Topic::PRIORITIES[:high] ].max)
          { "reason" => reason.to_s, "summary" => summary.presence,
            "from" => SupportDesk.actor_key(from) }.compact
        end
        return [ nil, nil ] unless event

        post_assistant_line!(line) unless requester_unavailable?
        [ event, from ]
      end

      # Her seat, and only hers: a human who holds the case keeps it. A case
      # that waited long enough for a person still gets one, seat or no seat.
      def release_assistant_seat!(reason:)
        return unless held_by_assistant?

        assignments.open.each { |assignment| assignment.release!(reason: reason) }
        update!(assignee: nil)
      end

      # One of the assistant's system lines, in the thread. A blank line
      # posts nothing, and a rendering error is reported rather than raised:
      # a missing translation must not roll back a hand-off.
      def post_assistant_line!(setting)
        assistant = self.assistant
        return if assistant.nil? || conversation.nil?

        line = assistant.config.line_for(setting, self)
        return if line.blank?

        conversation.post_system_message!(line)
      rescue StandardError => e
        SupportDesk.report_error(e, context: { hook: setting, ticket: id })
      end

      # The host's "somebody typed 'quiero hablar con una persona'" hook, run
      # on every requester message under the registration lock.
      #
      # It FAILS CLOSED (v2 R28): true hands the case over, false and nil do
      # nothing, and anything else — a String, a raise — is reported AND
      # hands the case over. A hook nobody can read the answer of is a hook
      # that has already failed, and the safe direction is a person.
      def evaluate_hand_off_phrase!(message)
        assistant = self.assistant
        return if assistant.nil? || human_required? || !assistant_in_play?

        block = assistant.config.hand_off_when
        return if block.nil?

        result = begin
          block.call(self, message)
        rescue StandardError => e
          SupportDesk.report_error(e, context: { hook: :hand_off_when, ticket: id })
          :error
        end

        case result
        when true
          flag_human_required!(actor: requester, kind: :human_requested, reason: "phrase", summary: nil,
                               line: :human_requested_line, request: nil)
          SupportDesk.emit_after_commit(:human_requested, self, by: requester, reason: :phrase)
        when false, nil
          nil
        else
          unless result == :error
            SupportDesk.report_error(
              ArgumentError.new("hand_off_when must return true, false or nil, got #{result.inspect}"),
              context: { hook: :hand_off_when, ticket: id }
            )
          end
          flag_human_required!(actor: requester, kind: :human_requested, reason: "hand_off_when_error",
                               summary: nil, line: :human_requested_line, request: nil)
          SupportDesk.emit_after_commit(:human_requested, self, by: requester, reason: :hand_off_when_error)
        end
      end

      # "There is something to answer here." The only event a harness
      # subscribes to, and the only place the gem asks anybody to do work.
      #
      # It carries the turn, so a job can check `ticket.assistant_turn ==
      # turn` before spending money. A hook that raises is reported: a
      # broken subscriber must not roll back the message that triggered it.
      def emit_assistant_turn(message = nil)
        assistant = self.assistant
        return if assistant.nil?
        return unless assistant_policy(assistant).may_observe?

        SupportDesk.emit_after_commit(:assistant_turn, self, assistant, message, turn: assistant_turn)
      rescue StandardError => e
        SupportDesk.report_error(e, context: { hook: :assistant_turn, ticket: id })
      end

      # A human transition that lowers the effective level below :reply while
      # she holds the case takes her seat — a case she may no longer answer
      # is not a case she can go on holding.
      def release_assistant_if_unfit!
        return false unless held_by_assistant?

        holder = assignee
        return false if assistant_policy(holder).may_reply?

        assignments.open.each { |assignment| assignment.release!(reason: :released) }
        update!(assignee: nil)
        true
      end

      # Every pending proposal on this case is out of date. `except:` is the
      # draft being sent right now, which is about to become "sent".
      def supersede_pending_drafts!(except: nil)
        scope = drafts.pending
        scope = scope.where.not(id: except) if except.present?
        scope.each(&:supersede!)
        reset_draft_associations!
      end

      # A closed case has nothing pending. Returns how many it expired, for
      # the close event's payload.
      def expire_pending_drafts!
        pending = drafts.pending.to_a
        pending.each(&:expire!)
        reset_draft_associations!
        pending.size
      end

      # The proposals moved, so what this instance remembers about them is
      # a lie. Everything that changes a draft's status calls this, so
      # `ticket.pending_draft` and `actions_for` are right inside the SAME
      # operation — a console that had to `reload` to see its own write is a
      # console that renders a button nobody can press.
      def reset_draft_associations!
        association(:pending_draft).reset
        association(:drafts).reset
      end
    end
  end
end
