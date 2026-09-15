# frozen_string_literal: true

require "active_support/current_attributes"

module SupportDesk
  # The ambient actor for the current request or job. Every ticket transition
  # takes `by:`; when it's omitted, this is where it falls back to — the user
  # engine sets it from `current_requester`, the console concern from
  # `current_agent`:
  #
  #   SupportDesk::Current.actor = current_user
  #   ticket.close!                        # => by: current_user
  #
  # Nothing is set for you. When both `by:` and this are empty, transitions
  # raise SupportDesk::ActorMissing rather than writing an unattributed row —
  # a support timeline nobody signed is worth less than no timeline.
  class Current < ActiveSupport::CurrentAttributes
    # The person (or bot) acting: an agent in the console, a requester in the
    # engine. `:system` is a legitimate value for jobs and sweeps.
    attribute :actor

    # The current ActionDispatch::Request, when there is one. Only ever used
    # to enrich event payloads (IP, user agent) — never to authorize.
    attribute :request
  end
end
