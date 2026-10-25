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

    # Whose desks these are: the account, workspace or product this request
    # or job serves, in an app that runs one support desk per customer.
    # `SupportDesk.desk(:default)` is then THIS owner's default desk, and
    # `Ticket.for_desk`, the SLA scopes and the console's desk list read
    # this owner's rows only. nil — the default — is the single-desk app
    # every install was before 0.6, and it reads the rows with no owner.
    #
    #   before_action { SupportDesk::Current.owner = current_workspace }
    #   SupportDesk::Current.set(owner: workspace) { … }       # in a job
    #
    # Anything reached FROM a ticket ignores it: a case knows its desk, and
    # a desk knows its owner.
    attribute :owner

    # The owned desks and assistants this request or job has resolved —
    # SupportDesk.desk's cache for owned rows. Gone with the request.
    attribute :resolved

    def self.resolved_records # :nodoc:
      self.resolved ||= {}
    end
  end
end
