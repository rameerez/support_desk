# frozen_string_literal: true

module SupportDesk
  # The gem emits; the host delivers. Every domain moment goes through one
  # multi-subscriber, error-isolated dispatcher:
  #
  #   SupportDesk.on(:ticket_opened)     { |ticket|    Support::TicketNotifier.deliver(ticket.agents_to_notify) }
  #   SupportDesk.on(:requester_replied) { |ticket, m| … }
  #   SupportDesk.on(:ticket_transitioned) { |ticket, kind, by:, request:, payload:| AuditLog.log(…) }
  #
  # Three guarantees worth knowing:
  #
  # 1. **After commit.** Events fire once the transition they describe is
  #    durable, so a subscriber never reads uncommitted state and never
  #    enqueues a job that races the write.
  # 2. **Isolated.** A subscriber that raises is reported through
  #    `Rails.error` and the next subscriber still runs. A broken notifier
  #    can't roll back a ticket.
  # 3. **Mirrored.** Every event is also published on ActiveSupport
  #    ::Notifications as `"<event>.support_desk"` for APM and hosts that
  #    prefer that bus.
  module Events
    # The catalogue. Keys are event names; values document the arguments
    # subscribers receive (see 09-events-and-notifications).
    CATALOGUE = {
      ticket_opened: "ticket",
      requester_replied: "ticket, message",
      agent_replied: "ticket, message",
      ticket_assigned: "ticket, assignment",
      ticket_handed_off: "ticket, assignment, from:, note:",
      ticket_released: "ticket, from:, reason:",
      ticket_closed: "ticket, by:",
      ticket_reopened: "ticket, by:",
      ticket_topic_changed: "ticket, from:, to:, by:",
      subject_attached: "ticket, subject, by:",
      note_added: "ticket, event",
      # The assistants (0.3). `assistant_turn` is the one a harness
      # subscribes to: everything else is something to notify a human about.
      assistant_turn: "ticket, assistant, message, turn:",
      draft_proposed: "ticket, draft",
      draft_sent: "ticket, draft, message, by:",
      draft_rejected: "ticket, draft, by:, reason:",
      assistant_withheld: "ticket, assistant, reason:, policy:",
      ticket_escalated: "ticket, from:, reason:, by:",
      human_requested: "ticket, by:, reason:",
      assistant_paused: "ticket, by:",
      assistant_resumed: "ticket, by:",
      ticket_transitioned: "ticket, kind, by:, request:, payload:"
    }.freeze

    # One registered callable, and the key it can be replaced under.
    Subscriber = Struct.new(:key, :callable) do
      def call(*args, **kwargs) = callable.call(*args, **kwargs)
    end

    # Subscribe to an event. Multiple subscribers per event are the point;
    # they run in registration order and never see each other's exceptions.
    # Returns the block, so a host can keep the handle.
    #
    # Pass `key:` from anywhere that runs more than once — a `to_prepare`
    # block, an engine initializer — and re-registering REPLACES that
    # subscriber in place instead of stacking a second copy on every code
    # reload.
    def on(event, key: nil, &block)
      event = event.to_sym
      unless CATALOGUE.key?(event)
        raise ConfigurationError,
              "unknown event #{event.inspect} — support_desk emits #{CATALOGUE.keys.map(&:inspect).join(", ")}"
      end
      raise ConfigurationError, "SupportDesk.on(#{event.inspect}) needs a block" unless block

      entry = Subscriber.new(key, block)
      list = subscribers[event]
      existing = key && list.index { |subscriber| subscriber.key == key }
      existing ? list[existing] = entry : list << entry
      block
    end

    # Drop a keyed subscriber. Mostly for tests and for hosts that wire
    # support up and down around a block.
    def off(event, key)
      subscribers[event.to_sym].reject! { |subscriber| subscriber.key == key }
      self
    end

    # Everything registered, as { event => [block, …] }. Mutable on purpose:
    # `reset!` empties it between tests.
    def subscribers
      @subscribers ||= Hash.new { |hash, key| hash[key] = [] }
    end

    # Fire +event+ now. Internal — the models call this; hosts subscribe.
    def emit(event, *args, **kwargs) # :nodoc:
      event = event.to_sym

      instrument(event, *args, **kwargs)

      subscribers[event].each do |subscriber|
        subscriber.call(*args, **kwargs)
      rescue StandardError => e
        report_subscriber_error(e, event)
      end

      nil
    end

    # Fire +event+ once the surrounding transaction commits (immediately when
    # there is none). Every transition emits through here.
    def emit_after_commit(event, *args, **kwargs) # :nodoc:
      if defined?(ActiveRecord) && ActiveRecord.respond_to?(:after_all_transactions_commit)
        ActiveRecord.after_all_transactions_commit { emit(event, *args, **kwargs) }
      else
        emit(event, *args, **kwargs)
      end
    end

    private

    def instrument(event, *args, **kwargs)
      return unless defined?(ActiveSupport::Notifications)

      ActiveSupport::Notifications.instrument("#{event}.support_desk", args: args, **kwargs)
    end

    def report_subscriber_error(error, event)
      report_error(error, context: { event: event, hook: :subscriber })
    end
  end
end
