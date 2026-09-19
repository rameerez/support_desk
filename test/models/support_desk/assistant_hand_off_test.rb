# frozen_string_literal: true

require "test_helper"

module SupportDesk
  # §12.8 — the two exits, and the rule that humans outrank machines.
  #
  # A way to a person that always works is the thing this feature is
  # answerable for. Three doors reach it: she escalates, the customer asks,
  # or a phrase does it for them — and every one of them ends in the same
  # column, the same event and the same tab.
  class AssistantHandOffTest < ActiveSupport::TestCase
    setup do
      @alice = create_user(name: "Alice")
      @lucia = create_agent(name: "Lucía")
      @rose = configure_assistant!(autonomy: :reply)
      @ticket = ticket_for(@alice, message: "No me llega el pedido")
    end

    def turn = @ticket.reload.assistant_turn

    # --- Every hand-off tells the host (R7) --------------------------------------

    test "running out of turns publishes the escalation the host subscribes to" do
      # The budget branch wrote the event row, released her seat and posted
      # the public line — everything except the one signal a host's "a person
      # is needed here" notifier listens for.
      with_assistant_config(max_turns: 1) do
        @ticket.respond!("Primera respuesta", by: @rose, turn: turn)
        ask_again(@ticket, "sigo sin saberlo")
        @ticket.reload
        seen = []
        SupportDesk.on(:ticket_escalated) { |ticket, from:, reason:, by:| seen << [ ticket.id, reason, by ] }

        outcome = @ticket.respond!("Última propuesta", by: @rose, turn: turn)

        assert_equal :max_turns, outcome.reason
        assert_needs_human @ticket, reason: "max_turns"
        assert_equal [ [ @ticket.id, :max_turns, @rose ] ], seen
      end
    end

    # --- She hands it over -------------------------------------------------------

    test "escalating releases her seat, flags the case and tells the customer" do
      @ticket.assign!(to: @rose, by: @rose, turn: @ticket.reload.assistant_turn)
      seen = []
      SupportDesk.on(:ticket_escalated) { |ticket, from:, reason:, by:| seen << [ ticket.id, from, reason, by ] }

      @ticket.escalate!(by: @rose, reason: "no sé de qué va", summary: "Pide una factura de 2019", turn: turn)

      assert_needs_human @ticket, reason: "no sé de qué va"
      assert_unassigned @ticket
      assert_equal "escalated", @ticket.assignments.first.release_reason
      assert_equal Topic::PRIORITIES[:high], @ticket.priority

      event = assert_ticket_event(@ticket, :escalated)

      assert_equal "Pide una factura de 2019", event.summary
      assert_equal SupportDesk.actor_key(@rose), event.payload["from"]
      assert_equal [ [ @ticket.id, @rose, :"no sé de qué va", @rose ] ], seen

      line = @ticket.conversation.messages.where(kind: "system").last.body

      assert_equal I18n.t("support_desk.system.handed_off_to_humans_with_promise",
                          reply_within: SupportDesk.humanize_duration(24.hours)), line
    end

    test "escalating twice writes once" do
      @ticket.escalate!(by: @rose, reason: "no sé", turn: turn)
      @ticket.escalate!(by: @rose, reason: "otra vez", turn: turn)

      assert_equal 1, @ticket.events.of_kind(:escalated).count
      assert_equal "no sé", @ticket.reload.human_required_reason
    end

    test "escalating needs the turn, and a reason worth reading" do
      assert_raises(ArgumentError) { @ticket.escalate!(by: @rose, reason: "x") }
      assert_raises(ArgumentError) { @ticket.escalate!(by: @rose, reason: "  ", turn: turn) }
    end

    test "escalating a case a person holds flags it and leaves their seat alone" do
      @ticket.assign!(to: @lucia, by: @lucia)

      @ticket.escalate!(by: @rose, reason: "esto es para ti", turn: turn)

      assert_needs_human @ticket
      assert_assigned_to @ticket, @lucia, "Lucía was already on it"
    end

    test "escalating a closed case is refused — reopen it first" do
      @ticket.reply!("Ya está", by: @lucia)
      @ticket.close!(by: @lucia)

      assert_raises(InvalidTransition) { @ticket.escalate!(by: @rose, reason: "x", turn: turn) }
    end

    test "a person and the system may escalate too" do
      @ticket.escalate!(by: @lucia, reason: "lo paso a segundo nivel")

      assert_needs_human @ticket, reason: "lo paso a segundo nivel"

      other = ticket_for(@alice, topic: :order, message: "Otra")
      other.escalate!(by: :system, reason: "assistant_silent", summary: "no answer in 3 minutes")

      assert_needs_human other, reason: "assistant_silent"
      assert_equal "system", other.events.of_kind(:escalated).first.payload["by"]
    end

    test "a pending proposal survives the hand-off — somebody may still want to send it" do
      with_assistant_config(autonomy: :draft) do
        draft = @ticket.draft!("propuesta", by: @rose, turn: turn)
        @ticket.escalate!(by: @rose, reason: "mejor una persona", turn: turn)

        assert_predicate draft.reload, :pending?
      end
    end

    # --- The customer asks -------------------------------------------------------

    test "the door flags the case, says so, and is idempotent" do
      seen = []
      SupportDesk.on(:human_requested) { |ticket, by:, reason:| seen << [ ticket.id, by, reason ] }

      @ticket.request_human!(by: @alice)
      @ticket.request_human!(by: @alice)

      assert_needs_human @ticket, reason: "requester_request"
      assert_equal 1, @ticket.events.of_kind(:human_requested).count
      assert_equal [ [ @ticket.id, @alice, :requester_request ] ], seen
      assert_includes @ticket.conversation.messages.where(kind: "system").pluck(:body),
                      I18n.t("support_desk.system.human_requested_with_promise",
                             reply_within: SupportDesk.humanize_duration(24.hours))
    end

    test "the door is on your own case and nobody else's" do
      mallory = create_user(name: "Mallory")

      assert_raises(NotAllowed) { @ticket.request_human!(by: mallory) }
      assert_raises(NotAllowed) { @ticket.request_human!(by: @lucia) }
      refute_needs_human @ticket
    end

    test "asking for a person reopens a closed case and flags it in one go" do
      @ticket.reply!("Ya está", by: @lucia)
      @ticket.close!(by: @lucia)

      @ticket.request_human!(by: @alice)

      assert_ticket_open @ticket
      assert_needs_human @ticket
      assert_equal 1, @ticket.reopen_count
    end

    test "a locked desk says so rather than half-reopening" do
      with_support_config(closed_tickets: :locked) do
        @ticket.reply!("Ya está", by: @lucia)
        @ticket.close!(by: @lucia)

        assert_raises(Locked) { @ticket.request_human!(by: @alice) }
        assert_ticket_closed @ticket
        refute_needs_human @ticket
      end
    end

    test "a desk with no assistant still flags, and posts no line" do
      SupportDesk.reset!
      configure_support_desk!
      SupportDesk.subscribe_to_chats!
      ticket = ticket_for(@alice, topic: :order, message: "Sin asistente")
      before = ticket.conversation.messages.where(kind: "system").count

      ticket.request_human!(by: @alice)

      assert_needs_human ticket
      assert_equal before, ticket.conversation.messages.where(kind: "system").count
    end

    # --- A phrase asks for them --------------------------------------------------

    test "a phrase hands the case over before the model ever runs" do
      with_assistant_config(hand_off_when: ->(_ticket, message) { message.body.to_s.match?(/persona/i) }) do
        ask_again(@ticket, "quiero hablar con una persona")

        assert_needs_human @ticket, reason: "phrase"
        assert_equal "quiero hablar con una persona", last_text(@ticket)
      end
    end

    test "a hook that says no changes nothing" do
      with_assistant_config(hand_off_when: ->(_ticket, _message) { false }) do
        ask_again(@ticket, "hola")

        refute_needs_human @ticket
      end

      with_assistant_config(hand_off_when: ->(_ticket, _message) { nil }) do
        ask_again(@ticket, "hola otra vez")

        refute_needs_human @ticket
      end
    end

    test "a hook that answers something unreadable fails closed" do
      with_assistant_config(hand_off_when: ->(_ticket, _message) { "yes" }) do
        ask_again(@ticket, "hola")

        assert_needs_human @ticket, reason: "hand_off_when_error"
        assert_equal "hola", last_text(@ticket), "the message is kept"
      end
    end

    test "a hook that raises fails closed, and the message still lands" do
      with_assistant_config(hand_off_when: ->(_ticket, _message) { raise "boom" }) do
        assert_nothing_raised { ask_again(@ticket, "hola") }

        assert_needs_human @ticket, reason: "hand_off_when_error"
        assert_awaiting_reply @ticket
      end
    end

    # --- Humans outrank ----------------------------------------------------------

    test "a person answering a case she holds takes it over, under every reply policy" do
      SupportDesk::Configuration::DeskConfiguration::REPLY_POLICIES.each do |policy|
        ticket = ticket_for(@alice, topic: :order, message: "Consulta #{policy}")
        ticket.respond!("Te contesto yo", by: @rose, turn: ticket.assistant_turn)

        assert_held_by_assistant ticket, @rose
        assert ticket.may_reply?(@lucia), "#{policy}: a person may always answer a machine's case"

        with_support_config(reply_policy: policy) do
          ask_again(ticket, "no me vale")
          ticket.reply!("Lo veo yo", by: @lucia)
        end

        assert_assigned_to ticket, @lucia
        ticket.close!(by: @lucia)
      end
    end

    test "she is never allowed to take a case back off a person" do
      @ticket.assign!(to: @lucia, by: @lucia)

      assert_raises(AssistantNotAllowed) { @ticket.reply!("dejadme a mí", by: @rose, turn: turn) }
      assert_assigned_to @ticket, @lucia
    end

    # --- Handing it back ---------------------------------------------------------

    test "a hand-back is the one action that lifts all three flags" do
      @ticket.pause_assistant!(by: @lucia)
      @ticket.update!(assistant_cap: "draft")
      @ticket.request_human!(by: @alice)

      @ticket.assign!(to: @rose, by: @lucia)

      assert_held_by_assistant @ticket, @rose
      refute_needs_human @ticket
      refute_predicate @ticket, :assistant_paused?
      assert_nil @ticket.assistant_cap
      assert_equal true, assert_ticket_event(@ticket, :assigned).payload["handed_back"]
    end

    test "a hand-back wakes the harness when the customer is waiting" do
      @ticket.request_human!(by: @alice)
      turns = []
      SupportDesk.on(:assistant_turn) { |_ticket, _assistant, message, turn:| turns << [ message, turn ] }

      @ticket.assign!(to: @rose, by: @lucia)

      assert_equal 1, turns.size
      assert_nil turns.first.first, "there is no new message — the case simply became hers again"
      assert_equal @ticket.reload.assistant_turn, turns.first.last
    end

    test "hand_off! hands back too" do
      @ticket.assign!(to: @lucia, by: @lucia)
      @ticket.request_human!(by: @alice)

      @ticket.hand_off!(to: @rose, by: @lucia)

      assert_held_by_assistant @ticket, @rose
      refute_needs_human @ticket
    end

    test "a hand-back onto a case she may not work is refused, and the flags stay" do
      @ticket.request_human!(by: @alice)

      with_topic_assistant_cap("other", :draft) do
        error = assert_raises(AssistantNotAllowed) { @ticket.assign!(to: @rose, by: @lucia) }

        assert_equal :take, error.verb
      end

      assert_needs_human @ticket
      assert_unassigned @ticket
    end

    test "resuming her is not a hand-back" do
      @ticket.pause_assistant!(by: @lucia)
      @ticket.update!(assistant_cap: "draft")
      @ticket.request_human!(by: @alice)

      @ticket.resume_assistant!(by: @lucia)

      refute_predicate @ticket, :assistant_paused?
      assert_equal "draft", @ticket.assistant_cap, "a cap is a different decision"
      # And so is asking for a person.
      assert_needs_human @ticket
    end
    private

    # What somebody actually typed, ignoring the desk's own system lines.
    def last_text(ticket)
      ticket.conversation.messages.where(kind: "text").order(:created_at, :id).last.body
    end
  end
end
