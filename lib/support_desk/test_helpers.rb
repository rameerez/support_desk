# frozen_string_literal: true

module SupportDesk
  # Test helpers for hosts. Include it in your `ActiveSupport::TestCase`:
  #
  #   include SupportDesk::TestHelpers
  #
  #   ticket = open_support_ticket(for: users(:alice), about: rides(:sevilla), message: "No aparece")
  #   ticket = open_support_ticket(for: users(:alice), by: users(:lucia), message: "Vimos que…")
  #   reply_as users(:lucia), ticket, "Lo miramos"
  #   assert_awaiting_requester ticket
  #   assert_ticket_event ticket, :handed_off, from: users(:lucia), to: users(:pedro)
  #
  #   with_support_config(reply_policy: :assignee_only) { … }
  #
  # The assertions read the same way the gem's own suite does, which is the
  # point: your acceptance tests and ours describe the same behaviour.
  module TestHelpers
    # Open a ticket the way a requester would — or, with `by:`, the way the
    # desk does when it writes first. Through the public sugar in both cases,
    # so this helper exercises what hosts actually type.
    def open_support_ticket(message: "Necesito ayuda", about: nil, topic: nil, by: nil, **options)
      requester = options.fetch(:for) { raise ArgumentError, "open_support_ticket needs for: a requester" }
      return requester.ask_support!(message, about: about, topic: topic) if by.nil? || by == requester

      by.open_support_conversation_with!(requester, message, about: about, topic: topic)
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

    # The requester spoke last and the desk owes the next word.
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

    # The case is done.
    def assert_ticket_closed(ticket, message = nil)
      ticket.reload
      assert_predicate ticket, :closed?, message || "expected #{ticket.reference} to be closed, was #{ticket.status}"
    end

    # The case is still live.
    def assert_ticket_open(ticket, message = nil)
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

    # --- Assistants -------------------------------------------------------------

    # The assistant record for +key+ (the desk's default when omitted).
    def support_assistant(key = nil)
      SupportDesk.assistant(key)
    end

    # Answer as the assistant and let policy decide what that becomes.
    # Returns the SupportDesk::Outcome.
    def respond_as(assistant, ticket, body = nil, turn: ticket.assistant_turn, **options)
      ticket.respond!(body, by: assistant, turn: turn, **options)
    end

    # Propose a reply as the assistant. Returns the SupportDesk::Draft.
    def draft_as(assistant, ticket, body = nil, turn: ticket.assistant_turn, **options)
      ticket.draft!(body, by: assistant, turn: turn, **options)
    end

    # --- Assistant assertions ---------------------------------------------------

    # There is a proposal waiting, optionally matching its text (a String is
    # a substring, a Regexp is a match). Returns the draft.
    def assert_pending_draft(ticket, body: nil)
      ticket.reload
      draft = ticket.pending_draft

      refute_nil draft, "expected a pending proposal on #{ticket.reference}, found " \
                        "#{ticket.drafts.map(&:status).join(", ").presence || "none"}"
      case body
      when Regexp then assert_match body, draft.body.to_s
      when String then assert_includes draft.body.to_s, body
      end
      draft
    end

    # Nothing is waiting to be sent.
    def refute_pending_draft(ticket)
      ticket.reload

      assert_nil ticket.pending_draft,
                 "expected no pending proposal on #{ticket.reference}, found #{ticket.pending_draft&.body.inspect}"
    end

    # Somebody has asked for a person on this case, optionally for this
    # reason ("requester_request", "phrase", "assistant_silent", …).
    def assert_needs_human(ticket, reason: nil)
      ticket.reload

      assert_predicate ticket, :human_required?,
                       "expected #{ticket.reference} to need a person"
      return if reason.nil?

      assert_equal reason.to_s, ticket.human_required_reason,
                   "#{ticket.reference} needs a person for a different reason"
    end

    # Nobody has.
    def refute_needs_human(ticket)
      ticket.reload

      refute_predicate ticket, :human_required?,
                       "expected #{ticket.reference} not to need a person " \
                       "(#{ticket.human_required_reason})"
    end

    # The assistant is sitting on this case.
    def assert_held_by_assistant(ticket, assistant = nil)
      ticket.reload

      assert_predicate ticket, :held_by_assistant?,
                       "expected #{ticket.reference} to be held by an assistant, was #{ticket.assignee.inspect}"
      return if assistant.nil?

      assert ticket.assigned_to?(assistant),
             "expected #{ticket.reference} to be held by #{assistant.key}, was #{ticket.assignee.inspect}"
    end

    # No machine has said anything to the requester in this case.
    def refute_assistant_spoke(ticket)
      ticket.reload
      spoken = ticket.conversation.messages.to_a.select { |message| ticket.assistant_message?(message) }

      assert_empty spoken.map(&:body),
                   "expected the assistant to have said nothing on #{ticket.reference}"
    end

    # What she may do here, and why. `because:` takes a String (substring) or
    # a Regexp, because the sentence is the point: a level with no reason is
    # a refusal nobody can act on.
    def assert_assistant_policy(ticket, level, because: nil)
      policy = ticket.reload.assistant_policy

      assert_equal level.to_sym, policy.level,
                   "expected #{ticket.reference} to be at #{level} for the assistant (#{policy.because})"
      case because
      when Regexp then assert_match because, policy.because
      when String then assert_includes policy.because, because
      end
      policy
    end

    # --- Assistant configuration ------------------------------------------------

    # Run a block with different assistant settings, then put them back:
    #
    #   with_assistant_config(autonomy: :reply) { … }
    #   with_assistant_config(:rose, max_turns: 1) { … }
    def with_assistant_config(key = nil, **overrides)
      key ||= SupportDesk.config.default_assistant_key
      configuration = SupportDesk.config.assistant(key)
      previous = overrides.keys.index_with { |name| configuration.read(name) }
      had = overrides.keys.index_with { |name| configuration.own?(name) }

      overrides.each { |name, value| configuration.public_send(:"#{name}=", value) }
      yield
    ensure
      previous.each do |name, value|
        had[name] ? configuration.public_send(:"#{name}=", value) : configuration.send(:reset_setting, name)
      end
    end

    # Run a block with one topic capped, then put the tree back.
    #
    # The tree is frozen at boot, so this REBUILDS it with the cap applied —
    # the same shape a host would have declared with `topic :payments,
    # assistant: :draft`, without asking a test to restate the whole tree.
    def with_topic_assistant_cap(path, level, desk: :default)
      configuration = SupportDesk.config.desk(desk)
      original = configuration.topics
      configuration.instance_variable_set(:@topics, rebuild_topics_with_cap(original, path.to_s, level))
      yield
    ensure
      configuration.instance_variable_set(:@topics, original)
    end

    private

    def rebuild_topics_with_cap(tree, path, level) # :nodoc:
      rebuilt = SupportDesk::TopicTree.new
      copy = lambda do |node, parent|
        options = node.options.dup
        options[:assistant] = level if node.path == path
        fresh = SupportDesk::Topic.new(key: node.key, parent: parent, **options)
        rebuilt.add(fresh, parent: parent)
        node.children.each { |child| copy.call(child, fresh) }
      end
      tree.roots.each { |root| copy.call(root, nil) }
      rebuilt.freeze!
    end

    public

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
