# frozen_string_literal: true

module SupportDesk
  # Base class for every error this gem raises, so hosts can
  # `rescue SupportDesk::Error` to catch anything support-specific.
  class Error < StandardError; end

  # Raised by `SupportDesk.configure`, by the validating setters, and by the
  # boot-time checks when the configuration can't work as written.
  class ConfigurationError < Error; end

  # Raised when a transition was given no `by:` and nothing set
  # `SupportDesk::Current.actor`. Pass `by: :system` from jobs.
  class ActorMissing < Error; end

  # Raised when the record handed to an agent-side operation isn't an eligible
  # agent (no `acts_as_support_agent`, or its `if:` said no).
  class NotAnAgent < Error; end

  # Raised when the record handed to a requester-side operation isn't an
  # eligible requester (no `has_support_tickets`, or its `if:` said no) — a
  # closed account, for instance, can neither ask nor be written to.
  class NotARequester < Error; end

  # Raised by `hand_off!` when the actor doesn't currently hold the ticket.
  class NotTheAssignee < Error; end

  # Raised when policy forbids the attempted action — a drop-in reply under
  # `reply_policy = :assignee_only`, a requester acting on someone else's
  # ticket, a subject the requester may not talk about.
  class NotAllowed < Error; end

  # Raised when a transition can't happen from the ticket's current state
  # (releasing a closed ticket, assigning one).
  class InvalidTransition < Error; end

  # Raised when the conversation behind a ticket is locked for writing —
  # a closed ticket on a desk configured `closed_tickets: :locked`.
  # A subclass of InvalidTransition, so `rescue InvalidTransition` still
  # catches it and the specific name is there when you want it.
  class Locked < InvalidTransition; end

  # Raised when a topic path isn't in the desk's tree.
  class UnknownTopic < Error; end

  # Raised when a record was offered as a ticket subject without `supportable`.
  class NotSupportable < Error; end

  # Raised when a requester trips `config.open_rate_limit`.
  class RateLimited < Error; end

  # Raised when a requester is already at `config.max_open_tickets`.
  class TooManyOpenTickets < Error; end

  # Raised when an AI-kind actor is not the desk's own SupportDesk::Assistant.
  # A host model declared `acts_as_support_agent kind: :ai` never inherits
  # human authority: every support write by it, or to it, is refused rather
  # than quietly treated as a human's (see the README's assistants section).
  class NotAnAssistant < NotAnAgent; end

  # Raised when the assistant's policy forbids the verb on this case. It
  # carries the policy that refused and the verb that was asked for, so a
  # host can log the RULE rather than parse the sentence.
  class AssistantNotAllowed < NotAllowed
    attr_reader :policy, :verb

    def initialize(policy, verb:, message: nil)
      @policy = policy
      @verb = verb.to_sym
      super(message || default_message)
    end

    private

    # "rose may not reply on T-AB12CD: topic payments caps rose at draft" —
    # who, what, where, and the rule that decided it.
    def default_message
      return "an assistant may not #{@verb} here" if @policy.nil?

      "#{@policy.assistant&.key || "the assistant"} may not #{@verb} on " \
        "#{@policy.ticket&.reference || "this case"}: #{@policy.because}"
    end
  end

  # Raised when an assistant acts on a turn that is no longer the case's:
  # somebody (the requester, a human, the assistant itself) changed the case
  # since it was read. A subclass of InvalidTransition, so a host that
  # rescues that still catches it — and a late, retried or redelivered job
  # writes nothing.
  class StaleTurn < InvalidTransition; end
end
