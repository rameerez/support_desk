# frozen_string_literal: true

module SupportDesk
  # What `Ticket#respond!` did — the one verb whose answer depends on policy,
  # so the harness can hand over an answer without first working out what it
  # is allowed to become.
  #
  #   outcome = ticket.respond!(text, by: rose, turn: turn)
  #   outcome.sent?       # it went to the requester
  #   outcome.drafted?    # a human will send it
  #   outcome.withheld?   # nothing was written, and #reason says why
  #   outcome.turn        # the successor turn, for a second action in the same run
  Outcome = Struct.new(:action, :message, :draft, :policy, :reason, :turn, keyword_init: true) do
    def sent? = action == :sent
    def drafted? = action == :drafted
    def withheld? = action == :withheld

    # Whether the case was ALSO handed to a person: the budget ran out
    # mid-conversation, so the draft is waiting and so is a human.
    def escalated? = reason == :max_turns

    # Ids, not records: this is what a log line or a job argument wants.
    def to_h
      {
        action: action,
        message: message&.id,
        draft: draft&.id,
        reason: reason,
        turn: turn,
        policy: policy&.to_h
      }
    end

    def inspect
      "#<SupportDesk::Outcome #{action}#{" #{reason}" if reason} turn=#{turn}>"
    end
  end
end
