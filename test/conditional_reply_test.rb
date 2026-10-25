# frozen_string_literal: true

require "test_helper"

# A person may answer at a turn too: the `If-Match` of a reply composed
# against a case that may have moved on.
class ConditionalReplyTest < ActiveSupport::TestCase
  setup do
    @alice = create_user(name: "Alice")
    @lucia = create_agent(name: "Lucía")
    @ticket = ticket_for(@alice, message: "Hola")
  end

  test "a reply at the current turn is posted, and moves the turn" do
    seen = @ticket.assistant_turn
    @ticket.reply!("Ya lo vemos", by: @lucia, turn: seen)

    assert_equal "Ya lo vemos", @ticket.conversation.messages.last.body
    assert_not_equal seen, @ticket.reload.assistant_turn
  end

  test "a reply at a stale turn raises StaleTurn and posts nothing" do
    seen = @ticket.assistant_turn
    ask_again(@ticket, "¿hay novedades?")

    assert_no_difference -> { @ticket.conversation.messages.where(kind: "text").count } do
      assert_raises(SupportDesk::StaleTurn) { @ticket.reply!("Ya lo vemos", by: @lucia, turn: seen) }
    end
    assert_nil @ticket.reload.assignee, "the refused reply took no seat either"
  end

  test "without a turn a person's reply is unconditional, as before" do
    ask_again(@ticket, "¿hay novedades?")

    assert_difference -> { @ticket.conversation.messages.where(kind: "text").count } do
      @ticket.reply!("Ya lo vemos", by: @lucia)
    end
  end

  test "a note honours the turn the same way" do
    seen = @ticket.assistant_turn
    @ticket.reply!("Ya lo vemos", by: @lucia)

    assert_raises(SupportDesk::StaleTurn) { @ticket.note!("ojo", by: @lucia, turn: seen) }
    assert_empty @ticket.notes

    @ticket.note!("ojo", by: @lucia, turn: @ticket.reload.assistant_turn)
    assert_equal [ "ojo" ], @ticket.notes.map(&:note)
  end
end
