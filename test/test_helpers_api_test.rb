# frozen_string_literal: true

require "test_helper"

# SupportDesk::TestHelpers is public API: a host's acceptance tests and the
# gem's own suite should describe behaviour the same way.
class TestHelpersApiTest < ActiveSupport::TestCase
  setup do
    @alice = create_user(name: "Alice")
    @lucia = create_agent(name: "Lucía")
    @pedro = create_agent(name: "Pedro")
  end

  test "open_support_ticket opens one the way a requester would" do
    order = create_order(user: @alice)
    ticket = open_support_ticket(for: @alice, about: order, message: "No ha llegado")

    assert_equal @alice, ticket.requester
    assert_equal order, ticket.subject
    assert_equal "No ha llegado", ticket.messages.first.body
  end

  test "open_support_ticket needs a requester" do
    assert_raises(ArgumentError) { open_support_ticket(message: "hola") }
  end

  test "reply_as and ask_again drive both sides" do
    ticket = open_support_ticket(for: @alice)

    reply_as @lucia, ticket, "vamos"

    assert_awaiting_requester ticket

    ask_again ticket, "gracias"

    assert_awaiting_reply ticket
  end

  test "the state assertions read like the states" do
    ticket = open_support_ticket(for: @alice)

    assert_ticket_open ticket
    assert_unassigned ticket

    ticket.assign!(to: @lucia, by: @lucia)

    assert_assigned_to ticket, @lucia

    ticket.close!(by: @lucia)

    assert_ticket_closed ticket
  end

  test "assert_ticket_event matches the actors in the payload" do
    ticket = open_support_ticket(for: @alice)
    ticket.assign!(to: @lucia, by: @lucia)
    ticket.hand_off!(to: @pedro, by: @lucia)

    assert_ticket_event ticket, :handed_off, from: @lucia, to: @pedro
    refute_ticket_event ticket, :closed
  end

  test "assert_ticket_event fails loudly when the event isn't there" do
    ticket = open_support_ticket(for: @alice)

    error = assert_raises(Minitest::Assertion) { assert_ticket_event ticket, :closed }

    assert_match(/expected a closed event/, error.message)
  end

  test "with_support_config puts the setting back, inherited or not" do
    assert_equal :anyone, SupportDesk.config.reply_policy

    with_support_config(reply_policy: :assignee_only) do
      assert_equal :assignee_only, SupportDesk.config.reply_policy
    end

    assert_equal :anyone, SupportDesk.config.reply_policy
    assert_not SupportDesk.config.default_desk.own?(:reply_policy)
  end

  test "with_support_config restores a value the host had really set" do
    SupportDesk.config.reply_policy = :take_over

    with_support_config(reply_policy: :assignee_only) { }

    assert_equal :take_over, SupportDesk.config.reply_policy
    assert SupportDesk.config.default_desk.own?(:reply_policy)
  end

  test "with_support_config targets another desk" do
    SupportDesk.config.desk(:billing)

    with_support_config(:billing, reply_within: 1.hour) do
      assert_equal 1.hour, SupportDesk.config.desk(:billing).reply_within
      assert_equal 24.hours, SupportDesk.config.reply_within
    end

    assert_equal 24.hours, SupportDesk.config.desk(:billing).reply_within
  end

  test "capture_support_events collects what the block emitted" do
    ticket = open_support_ticket(for: @alice)

    events = capture_support_events(:ticket_closed, :ticket_transitioned) do
      ticket.close!(by: @lucia)
    end

    assert_equal %i[ticket_transitioned ticket_closed].sort, events.map(&:first).sort
  end

  test "capture_support_events unsubscribes on the way out" do
    before = SupportDesk.subscribers[:ticket_closed].size

    capture_support_events(:ticket_closed) { open_support_ticket(for: @alice) }

    assert_equal before, SupportDesk.subscribers[:ticket_closed].size
  end

  test "capture_support_events unsubscribes even when the block raises" do
    before = SupportDesk.subscribers[:ticket_closed].size

    assert_raises(RuntimeError) do
      capture_support_events(:ticket_closed) { raise "boom" }
    end

    assert_equal before, SupportDesk.subscribers[:ticket_closed].size
  end

  test "ticket_for needs no hand-registration: the chats subscriber already ran" do
    ticket = ticket_for(@alice)

    assert_equal "agent", ticket.awaiting
    assert_not_nil ticket.last_requester_message_at
    assert_equal ticket.conversation.messages.first.id.to_s, ticket.last_registered_message_id.to_s
  end
  test "open_support_ticket by: opens as the desk" do
    ticket = open_support_ticket(for: @alice, by: @lucia, message: "Vimos que tu pedido no llegó")

    assert_predicate ticket, :opened_by_support?
    assert_equal @lucia, ticket.opened_by
    assert_assigned_to ticket, @lucia
    assert_awaiting_requester ticket
    assert_equal "Vimos que tu pedido no llegó", ticket.messages.where(kind: "text").sole.body
  end

  test "open_support_ticket by: the requester is the requester asking" do
    ticket = open_support_ticket(for: @alice, by: @alice, message: "necesito ayuda")

    assert_predicate ticket, :opened_by_requester?
    assert_predicate ticket, :unassigned?
    assert_awaiting_reply ticket
  end
end
