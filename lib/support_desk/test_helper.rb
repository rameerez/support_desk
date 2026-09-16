# frozen_string_literal: true

module SupportDesk
  # Test helpers for hosts. Include it in your `ActiveSupport::TestCase`:
  #
  #   include SupportDesk::TestHelper
  #
  #   ticket = open_support_ticket(for: users(:alice), about: rides(:sevilla), message: "No aparece")
  #   reply_as users(:lucia), ticket, "Lo miramos"
  #   assert_awaiting_requester ticket
  #   assert_ticket_event ticket, :handed_off, from: users(:lucia), to: users(:pedro)
  #
  #   with_support_config(reply_policy: :assignee_only) { … }
  #
  # The assertions read the same way the gem's own suite does, which is the
  # point: your acceptance tests and ours describe the same behaviour.
  module TestHelper
    # Open a ticket the way a requester would, and hand it back.
    def open_support_ticket(message: "Necesito ayuda", about: nil, topic: nil, **options)
      requester = options.fetch(:for) { raise ArgumentError, "open_support_ticket needs for: a requester" }
      requester.ask_support!(message, about: about, topic: topic)
    end

    # Answer as an agent. Returns the Chats::Message.
    def reply_as(agent, ticket, body, files: [])
      ticket.reply!(body, by: agent, files: files)
    end

    # Say something else as the requester. Returns the Chats::Message.
    def ask_again(ticket, body)
      ticket.requester.message!(ticket.conversation, body)
    end

    # --- Assertions -------------------------------------------------------------

    def assert_awaiting_reply(ticket, message = nil)
      ticket.reload
      assert_predicate ticket, :awaiting_reply?,
                       message || "expected #{ticket.reference} to be waiting on the desk, was #{ticket.awaiting}"
    end

    # The desk answered and the ball is in the requester's court.
    def assert_awaiting_requester(ticket, message = nil)
      ticket.reload
      assert_predicate ticket, :awaiting_requester?,
                       message || "expected #{ticket.reference} to be waiting on the requester, " \
                                  "was #{ticket.awaiting}"
    end

    # The case is done, or still live.
    def assert_closed(ticket, message = nil)
      ticket.reload
      assert_predicate ticket, :closed?, message || "expected #{ticket.reference} to be closed, was #{ticket.status}"
    end

    # The case is still live.
    def assert_open(ticket, message = nil)
      ticket.reload
      assert_predicate ticket, :open?, message || "expected #{ticket.reference} to be open, was #{ticket.status}"
    end

    # Who is holding the case, or that nobody is.
    def assert_assigned_to(ticket, agent, message = nil)
      ticket.reload
      assert ticket.assigned_to?(agent),
             message || "expected #{ticket.reference} to be held by #{agent.inspect}, was #{ticket.assignee.inspect}"
    end

    # Nobody is holding it.
    def assert_unassigned(ticket, message = nil)
      ticket.reload
      assert_predicate ticket, :unassigned?,
                       message || "expected #{ticket.reference} to be unassigned, was #{ticket.assignee.inspect}"
    end

    # Assert the ticket's timeline holds an event of +kind+, optionally
    # matching the actors in its payload.
    def assert_ticket_event(ticket, kind, from: nil, to: nil, by: nil)
      events = ticket.events.of_kind(kind).to_a
      refute_empty events, "expected a #{kind} event on #{ticket.reference}, found " \
                           "#{ticket.events.map(&:kind).join(", ").presence || "none"}"

      events = events.select { |event| event.payload["from"] == SupportDesk.actor_key(from) } if from
      events = events.select { |event| event.payload["to"] == SupportDesk.actor_key(to) } if to
      events = events.select { |event| event.actor == by } if by

      refute_empty events, "expected a #{kind} event on #{ticket.reference} with " \
                           "#{{ from: from, to: to, by: by }.compact.inspect}"
      events.first
    end

    # Assert the case's timeline has NO event of this kind.
    def refute_ticket_event(ticket, kind)
      assert_empty ticket.events.of_kind(kind).to_a,
                   "expected no #{kind} event on #{ticket.reference}"
    end

    # --- Configuration ----------------------------------------------------------

    # Run a block with different desk settings, then put them back:
    #
    #   with_support_config(reply_policy: :assignee_only) { … }
    #   with_support_config(:billing, reply_within: 1.hour) { … }
    def with_support_config(desk = :default, **overrides)
      configuration = SupportDesk.config.desk(desk)
      previous = overrides.keys.index_with { |key| configuration.read(key) }
      had = overrides.keys.index_with { |key| configuration.own?(key) }

      overrides.each { |key, value| configuration.public_send(:"#{key}=", value) }
      yield
    ensure
      previous.each do |key, value|
        had[key] ? configuration.public_send(:"#{key}=", value) : configuration.send(:reset_setting, key)
      end
    end

    # Capture the events the gem emits inside the block:
    #
    #   events = capture_support_events(:ticket_closed) { ticket.close!(by: lucia) }
    #
    # The subscribers are removed again on the way out, block or raise, so a
    # capture in one example can never fire in the next one.
    def capture_support_events(*names)
      captured = []
      key = :"support_desk_capture_#{SecureRandom.hex(4)}"
      names.each do |name|
        SupportDesk.on(name, key: key) { |*args, **kwargs| captured << [ name, args, kwargs ] }
      end

      yield
      captured
    ensure
      names.each { |name| SupportDesk.off(name, key) }
    end
  end
end
