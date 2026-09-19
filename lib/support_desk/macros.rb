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
    # console can tell two kinds of requester apart; `if:` is the per-record
    # check for "may this person ask for help — and be written to — right
    # now" (`if: :kept?` for a host with soft-deleted accounts).
    def has_support_tickets(desk: :default, as: nil, **options)
      condition = Macros.condition!(options, macro: "has_support_tickets", known: ":if, :desk, :as")

      include SupportDesk::Requester

      self.support_desk_requester_options = { desk: desk.to_sym, as: as&.to_s, if: condition }.freeze
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
    # One verb is added — `open_support_conversation_with!`, the only agent
    # action that has no ticket yet. Everything else keeps the ticket as the
    # subject of the sentence (`ticket.assign!(to: lucia)`).
    def acts_as_support_agent(kind: :human, **options)
      condition = Macros.condition!(options, macro: "acts_as_support_agent", known: ":if, :kind")
      kind = Macros.kind!(kind)

      include SupportDesk::Agent

      self.support_desk_agent_options = { if: condition, kind: kind }.freeze
      SupportDesk.register_agent(self)
    end

    # Who the agent IS: a person, or a machine. There are two kinds because
    # they are answerable to different rules, and an unknown third would be
    # treated as a human by every check that isn't looking for :ai — so it
    # fails at class definition instead.
    def self.kind!(kind)
      kind = kind.to_sym if kind.respond_to?(:to_sym)
      return kind if %i[human ai].include?(kind)

      raise ConfigurationError,
            "acts_as_support_agent kind: must be :human or :ai, got #{kind.inspect}"
    end

    # The `if:` both macros take: a method name or a callable, and the only
    # option either of them accepts beyond its own keywords. Written once
    # because "may this person answer" and "may this person ask" are the same
    # question asked of a different side, and two copies of it would be two
    # places to fix the day one grows a third shape.
    def self.condition!(options, macro:, known:)
      unknown = options.keys - [ :if ]
      if unknown.any?
        raise ConfigurationError,
              "unknown #{macro} option#{"s" if unknown.size > 1} " \
              "#{unknown.map(&:inspect).join(", ")} — known options are #{known}"
      end

      condition = options[:if]
      unless condition.nil? || condition.is_a?(Symbol) || condition.respond_to?(:call)
        raise ConfigurationError,
              "#{macro} if: must be a method name or a callable, got #{condition.inspect}"
      end

      condition
    end
  end
end
