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

  # Raised by `hand_off!` when the actor doesn't currently hold the ticket.
  class NotTheAssignee < Error; end

  # Raised when routing or an assignment targets an agent who is off duty.
  class OffDuty < Error; end

  # Raised when policy forbids the attempted action — a drop-in reply under
  # `reply_policy = :assignee_only`, a requester acting on someone else's
  # ticket, a subject the requester may not talk about.
  class NotAllowed < Error; end

  # Raised when a transition can't happen from the ticket's current state
  # (replying into a locked closed ticket, releasing a closed one).
  class InvalidTransition < Error; end

  # Raised when the conversation behind a ticket is locked for writing.
  class Locked < Error; end

  # Raised when a topic path isn't in the desk's tree.
  class UnknownTopic < Error; end

  # Raised when a record was offered as a ticket subject without `supportable`.
  class NotSupportable < Error; end

  # Raised when a requester trips `config.open_rate_limit`.
  class RateLimited < Error; end

  # Raised when a requester is already at `config.max_open_tickets`.
  class TooManyOpenTickets < Error; end
end
