# frozen_string_literal: true

module SupportDesk
  # The three host-facing macros. The engine extends `ActiveRecord::Base`
  # with this module, so any model can declare:
  #
  #   class User < ApplicationRecord
  #     acts_as_messager                    # chats
  #     has_support_tickets                 # can ask for help
  #     acts_as_support_agent if: :admin?   # can answer
  #   end
  #
  #   class Ride < ApplicationRecord
  #     supportable topic: :ride            # can be asked about
  #   end
  #
  # Each macro includes the matching concern — all the behaviour lives in
  # SupportDesk::Requester / Supportable / Agent, so it's discoverable,
  # testable, and `include`-able directly when a host prefers that style.
  module Macros
    # The requester side. `desk:` names which desk this model writes to;
    # `as:` records a role on every ticket ("driver", "passenger") so the
    # console can tell two kinds of requester apart.
    def has_support_tickets(desk: :default, as: nil)
      include SupportDesk::Requester

      self.support_desk_requester_options = { desk: desk.to_sym, as: as&.to_s }.freeze
      SupportDesk.register_requester(self)
    end

    # Makes a domain record something people can ask about: a ride, an
    # order, a withdrawal. `topic:` is the topic a ticket opened from this
    # record's door lands on; `candidates:` overrides the "which one?"
    # picker; `one_open_ticket: false` lets a requester hold several open
    # tickets about the same record.
    def supportable(topic:, candidates: nil, one_open_ticket: true)
      if candidates && !candidates.respond_to?(:call)
        raise ConfigurationError, "supportable candidates: must respond to #call, got #{candidates.inspect}"
      end

      include SupportDesk::Supportable

      self.support_desk_supportable_options = {
        topic: topic.to_s, candidates: candidates, one_open_ticket: !!one_open_ticket
      }.freeze
      SupportDesk.register_supportable(self)
    end

    # The agent side: who may answer. `if:` is the per-record eligibility
    # check (a Symbol method name or a callable); `kind:` is :human or :ai.
    # No verbs are added — the ticket is the subject of every sentence
    # (`ticket.assign!(to: lucia)`), never the agent.
    def acts_as_support_agent(kind: :human, **options)
      unknown = options.keys - [ :if ]
      if unknown.any?
        raise ConfigurationError,
              "unknown acts_as_support_agent option#{"s" if unknown.size > 1} " \
              "#{unknown.map(&:inspect).join(", ")} — known options are :if, :kind"
      end

      condition = options[:if]
      unless condition.nil? || condition.is_a?(Symbol) || condition.respond_to?(:call)
        raise ConfigurationError,
              "acts_as_support_agent if: must be a method name or a callable, got #{condition.inspect}"
      end

      include SupportDesk::Agent

      self.support_desk_agent_options = { if: condition, kind: kind.to_sym }.freeze
      SupportDesk.register_agent(self)
    end
  end
end
