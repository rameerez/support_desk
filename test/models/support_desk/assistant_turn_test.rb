# frozen_string_literal: true

require "test_helper"

module SupportDesk
  # §12.6 — the turn, sequentially. (The threaded half is in
  # assistant_concurrency_test.rb, which runs the same scenarios for real on
  # PostgreSQL.)
  #
  # The whole safety story is here: a model takes seconds to answer, a
  # customer can write again while it does, and a queue can deliver the same
  # job twice. One integer under the row lock has to make all three safe.
  class AssistantTurnTest < ActiveSupport::TestCase
    setup do
      @alice = create_user(name: "Alice")
      @lucia = create_agent(name: "Lucía")
      @rose = configure_assistant!(autonomy: :reply)
      @ticket = ticket_for(@alice, message: "Hola")
    end

    def revision = @ticket.reload.assistant_revision
    def turn = @ticket.reload.assistant_turn

    # --- What moves it -----------------------------------------------------------

    test "a requester message moves the turn" do
      before = revision
      ask_again(@ticket, "¿hay novedades?")

      assert_operator revision, :>, before
    end

    test "an agent message moves the turn" do
      before = revision
      @ticket.reply!("Ya lo vemos", by: @lucia)

      assert_operator revision, :>, before
    end

    test "every real transition moves the turn, and a no-op moves nothing" do
      @ticket.assign!(to: @lucia, by: @lucia)
      before = revision

      @ticket.assign!(to: @lucia, by: @lucia)

      assert_equal before, revision, "assigning the holder again wrote no event"

      @ticket.release!(by: @lucia)

      assert_operator revision, :>, before
    end

    test "a proposal moves the turn — she changed the case" do
      with_assistant_config(autonomy: :draft) do
        before = revision
        @ticket.draft!("propuesta", by: @rose, turn: turn)

        assert_operator revision, :>, before
      end
    end

    test "the turn is derived from the revision, and is never nil" do
      assert_equal "t#{@ticket.id}-r#{revision}", turn

      fresh = Ticket.new

      assert_equal "t-r0", fresh.assistant_turn
    end

    # --- What it refuses ---------------------------------------------------------

    test "a turn the case has moved past writes nothing" do
      stale = turn
      ask_again(@ticket, "otra cosa")

      error = assert_raises(StaleTurn) { @ticket.respond!("Hola", by: @rose, turn: stale) }

      assert_match(/is stale on #{@ticket.reference}/, error.message)
      assert_match(/now #{turn}/, error.message)
      refute_assistant_spoke @ticket
      refute_pending_draft @ticket
    end

    test "a redelivered job after a committed action is a no-op" do
      held = turn
      @ticket.respond!("Ya lo miramos", by: @rose, turn: held)

      assert_raises(StaleTurn) { @ticket.respond!("Ya lo miramos", by: @rose, turn: held) }
      assert_equal 1, @ticket.conversation.messages.where(kind: "text").count { |m| @ticket.assistant_message?(m) }
      assert_equal 1, @ticket.reload.assistant_turns_count
    end

    test "every verb consumes it, so a second action needs the successor" do
      held = turn
      @ticket.note!("mirando", by: @rose, turn: held)

      assert_raises(StaleTurn) { @ticket.note!("otra vez", by: @rose, turn: held) }

      @ticket.note!("otra vez", by: @rose, turn: turn)

      assert_equal 2, @ticket.events.of_kind(:note).count
    end

    test "a stale escalation writes nothing" do
      stale = turn
      ask_again(@ticket, "otra")

      assert_raises(StaleTurn) { @ticket.escalate!(by: @rose, reason: "no sé", turn: stale) }
      refute_needs_human @ticket
    end

    # --- Reconciliation (I5) -----------------------------------------------------

    test "a message chats committed but nobody registered is folded in before the turn is read" do
      # The gem's subscriber runs after commit and the harness runs on
      # another connection. Without this, she would answer around a question
      # the case has not registered yet.
      held = turn
      # The gem finds its case through `Ticket.for_conversation`. Blinding
      # that is exactly what a subscriber running after commit, on another
      # connection, looks like from in here.
      Ticket.stub(:for_conversation, nil) { @alice.message!(@ticket.conversation, "una cosa más") }

      assert_equal held, turn, "nothing registered it, so the turn hasn't moved yet"

      # Without the fold this would have been a perfectly current turn, and
      # she would have answered a conversation missing its last question.
      assert_raises(StaleTurn) { @ticket.respond!("Hola", by: @rose, turn: held) }
      # And the refusal took the fold with it (I15): a refused operation
      # rolls back everything it touched, message pointers included.
      refute_assistant_spoke @ticket
      refute_pending_draft @ticket
      assert_equal held, turn
    end

    test "two messages on the same instant are both registered" do
      # Forward, not just coarse: a message BEHIND the clock is a replay,
      # and replay protection is the other half of this rule.
      frozen = 1.minute.from_now.change(usec: 0)
      travel_to(frozen) do
        ask_again(@ticket, "primera")
        before = revision
        ask_again(@ticket, "segunda")

        assert_operator revision, :>, before, "the second message is not the first one again"
      end
    end

    test "a replayed older message is still skipped" do
      message = ask_again(@ticket, "primera")
      @ticket.reply!("vale", by: @lucia)
      before = revision

      @ticket.reload.register!(message)

      assert_equal before, revision
    end

    # --- The event ---------------------------------------------------------------

    test "the opening message emits a turn, and so does every later one" do
      turns = []
      SupportDesk.on(:assistant_turn) { |ticket, assistant, message, turn:| turns << [ ticket.id, assistant.key, message&.body, turn ] }

      ticket = ticket_for(@alice, topic: :order, message: "Otra consulta")

      assert_equal 1, turns.size
      assert_equal [ ticket.id, "rose", "Otra consulta" ], turns.first.first(3)
      assert_equal ticket.reload.assistant_turn, turns.first.last

      ask_again(ticket, "y otra cosa")

      assert_equal 2, turns.size
    end

    test "no turn is emitted where she may not even look" do
      turns = []
      SupportDesk.on(:assistant_turn) { |*| turns << true }

      with_assistant_config(autonomy: :off) { ask_again(@ticket, "hola") }

      assert_empty turns

      @ticket.pause_assistant!(by: @lucia)
      ask_again(@ticket, "hola otra vez")

      assert_empty turns, "a paused assistant is not asked to think about it"
    end

    test "a turn is still emitted at :observe, person or no person" do
      @ticket.request_human!(by: @alice)
      turns = []
      SupportDesk.on(:assistant_turn) { |*| turns << true }

      ask_again(@ticket, "otra cosa")

      assert_equal 1, turns.size, "she may still leave a note for whoever picks it up"
    end

    test "a desk with no assistant emits nothing" do
      SupportDesk.reset!
      configure_support_desk!
      SupportDesk.subscribe_to_chats!
      turns = []
      SupportDesk.on(:assistant_turn) { |*| turns << true }

      ticket_for(@alice, topic: :order, message: "Sin asistente")

      assert_empty turns
    end

    test "a subscriber that raises never takes the message down with it" do
      SupportDesk.on(:assistant_turn) { |*| raise "boom" }

      assert_nothing_raised { ask_again(@ticket, "hola") }
      assert_awaiting_reply @ticket
    end
  end
end
