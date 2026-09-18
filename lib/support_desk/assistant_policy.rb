# frozen_string_literal: true

module SupportDesk
  # What the assistant may do on ONE case, right now, and why.
  #
  #   policy = ticket.assistant_policy
  #   policy.level       # => :draft
  #   policy.because     # => "topic payments caps rose at draft"
  #   policy.may_reply?  # => false
  #
  # == Ceilings and floors
  #
  # A CEILING lowers what the assistant may ever produce here: her configured
  # autonomy, the topic's cap (the minimum over the topic and every ancestor),
  # the host's `cap` block, the case's persisted cap (what a reopen writes),
  # and a pause. The lowest ceiling wins, and `because` names the rule that
  # decided it — so a refusal can always be traced to one line of
  # configuration.
  #
  # A FLOOR lowers the level because of the case's state: she is inactive,
  # the case is closed, a person was asked for, or a human holds it. Floors
  # run after ceilings and only ever lower.
  #
  # == It is the authorization, not a hint
  #
  # Every assistant verb asks this object, under the ticket's row lock, from
  # freshly read state — `Ticket#actions_for` is a projection of the same
  # decision, never a second opinion. No query: the topic is an in-memory
  # lookup, the assignee is the loaded association, everything else is a
  # column on the row we already hold.
  class AssistantPolicy
    # What the assistant may PRODUCE, from least to most. Ordered, and the
    # order is the meaning: everything compares by RANK, never by name.
    LEVELS = %i[off observe draft reply resolve].freeze
    RANK = LEVELS.each_with_index.to_h.freeze

    # The verbs each level unlocks. Every level's array is the previous one
    # plus its own, written out rather than computed: a reader has to be able
    # to see what ":reply" means without running anything.
    VERBS_BY_LEVEL = {
      off: [],
      observe: %i[note escalate release],
      draft: %i[note escalate release draft],
      reply: %i[note escalate release draft reply take],
      resolve: %i[note escalate release draft reply take close]
    }.freeze

    # Every verb the top level knows — what `forbidden_verbs` subtracts from.
    ALL_VERBS = VERBS_BY_LEVEL.fetch(:resolve)

    attr_reader :ticket, :assistant, :level, :because, :ceilings, :floors

    # The policy for +assistant+ on +ticket+.
    #
    # `hand_back: true` asks a different question — "could she hold this case
    # once the human-side flags were cleared?" — and is used by one caller,
    # `Ticket#ensure_assignable!`, so that a human handing a case back is not
    # refused by the very flags that hand-back exists to lift. The hard
    # ceilings (autonomy, topic, the `cap` block) and the hard floors
    # (inactive, closed) still apply.
    def self.for(ticket, assistant = ticket.assistant, hand_back: false)
      return Null.new(ticket, reason: "no assistant on desk #{ticket.desk&.key}") if assistant.nil?
      unless SupportDesk::Ticket.same_actor?(assistant, ticket.assistant)
        return Null.new(ticket, reason: "#{assistant.try(:key) || assistant.class} is not desk " \
                                        "#{ticket.desk&.key}'s assistant")
      end

      config = assistant.config
      ceilings = {
        assistant: config.autonomy,
        topic: ticket.topic&.assistant_cap,
        cap: evaluate_cap(config, ticket),
        case: (ticket.assistant_cap&.to_sym unless hand_back),
        pause: (:off if ticket.assistant_paused? && !hand_back)
      }.compact

      # Hash#min_by yields [key, value]; destructuring it the other way round
      # is how a policy starts reporting "the level caps her at :topic".
      rule, level = ceilings.min_by { |_rule, value| RANK.fetch(value) }
      because = ceiling_sentence(rule, level, assistant, ticket)
      floors = []

      if !assistant.active?
        level = :off
        because = "#{assistant.key} is inactive"
        floors << :inactive
      end
      if ticket.closed? && RANK.fetch(level) > RANK.fetch(:observe)
        level = :observe
        because = "the case is closed"
        floors << :closed
      end
      if !hand_back && ticket.human_required? && RANK.fetch(level) > RANK.fetch(:observe)
        level = :observe
        because = "a person was requested (#{ticket.human_required_reason})"
        floors << :human_required
      end
      if !hand_back && ticket.assigned? && !ticket.assigned_to?(assistant) &&
         RANK.fetch(level) > RANK.fetch(:draft)
        level = :draft
        because = "#{holder_name(ticket)} holds the case"
        floors << :held_by_human
      end

      new(ticket: ticket, assistant: assistant, level: level, because: because,
          ceilings: ceilings, floors: floors)
    end

    # Run the host's `cap` block and check what it said. A block that returns
    # something that isn't a level is a configuration mistake, and it is
    # named as one here rather than turning into a NoMethodError inside a
    # transaction. A block that RAISES is the host's exception to see: it
    # propagates (the one caller that can't afford that — the turn emitter —
    # reports it and emits nothing).
    def self.evaluate_cap(config, ticket) # :nodoc:
      block = config.cap
      return nil if block.nil?

      value = block.call(ticket)
      return nil if value.nil?

      level = value.respond_to?(:to_sym) ? value.to_sym : value
      unless LEVELS.include?(level)
        raise ConfigurationError,
              "assistant #{config.key}'s cap block must return one of #{LEVELS.map(&:inspect).join(", ")} " \
              "or nil, got #{value.inspect}"
      end

      level
    end

    def self.ceiling_sentence(rule, level, assistant, ticket) # :nodoc:
      case rule
      when :assistant then "#{assistant.key}'s autonomy is #{level}"
      when :topic then "topic #{ticket.topic&.path} caps #{assistant.key} at #{level}"
      when :cap then "this desk's cap block caps #{assistant.key} at #{level}"
      when :case then "this case caps #{assistant.key} at #{level}"
      when :pause then "#{assistant.key} is paused on this case"
      else "#{assistant.key} may work at #{level}"
      end
    end

    def self.holder_name(ticket) # :nodoc:
      ticket.assignee.try(:support_agent_name) || "somebody else"
    end

    private_class_method :ceiling_sentence, :holder_name

    # Built by `.for`. The attributes are the whole object: a policy is a
    # value, computed once under the lock and then only read.
    def initialize(ticket:, assistant:, level:, because:, ceilings: {}, floors: [])
      @ticket = ticket
      @assistant = assistant
      @level = level
      @because = because
      @ceilings = ceilings
      @floors = floors
    end

    # Whether the effective level is at least +other+.
    def at_least?(other)
      RANK.fetch(level) >= RANK.fetch(other.to_sym)
    end

    # Whether this verb is unlocked at the effective level.
    def may?(verb) = allowed_verbs.include?(verb.to_sym)

    def may_observe? = at_least?(:observe)
    def may_draft? = at_least?(:draft)
    def may_reply? = at_least?(:reply)
    # Holding a case means owing the next word, so it takes the level that
    # may say one.
    def may_hold? = may_reply?
    def may_close? = at_least?(:resolve)

    def allowed_verbs = VERBS_BY_LEVEL.fetch(level)
    def forbidden_verbs = ALL_VERBS - allowed_verbs

    # Whether this is the null policy — no assistant to ask about.
    def null? = false

    # The whole decision, as data: what goes into message metadata, a draft
    # row and an event payload, so forensics never has to re-run the policy
    # against a case that has moved on.
    def to_h
      {
        assistant: assistant&.key,
        level: level,
        because: because,
        ceilings: { assistant: ceilings[:assistant], topic: ceilings[:topic], cap: ceilings[:cap],
                    case: ceilings[:case], pause: ceilings[:pause] },
        floors: floors
      }
    end

    # "draft — topic payments caps rose at draft"
    def to_s = "#{level} — #{because}"

    def inspect
      "#<SupportDesk::AssistantPolicy #{assistant&.key || "none"} #{level} #{because.inspect}>"
    end

    # No assistant on this desk, or an assistant that is somebody else's.
    # Every predicate says no, and `because` says which of the two it was.
    class Null < AssistantPolicy
      def initialize(ticket, reason:)
        super(ticket: ticket, assistant: nil, level: :off, because: reason, ceilings: {}, floors: [])
      end

      def null? = true
    end
  end
end
