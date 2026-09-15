# frozen_string_literal: true

require "test_helper"

# The README's sample is a promise. This runs it verbatim against the dummy
# app, so the first ten lines anybody reads can never quietly stop working.
class ReadmeTest < ActiveSupport::TestCase
  setup do
    @alice = create_user(name: "Alice")
    @lucia = create_agent(name: "Lucía")
    @order = create_order(user: @alice, number: "SO1")
  end

  test "the README example runs" do
    alice = @alice
    lucia = @lucia
    order = @order

    ticket = alice.ask_support!("My order never arrived", about: order)
    ticket.assign!(to: lucia, by: lucia)
    ticket.reply!("We're on it", by: lucia)
    ticket.close!(by: lucia)

    assert_closed ticket
    assert_equal lucia, ticket.assignee
    assert_equal %w[opened assigned closed], ticket.events.chronological.map(&:kind)
    # Alice's question, "Lucía is taking care of your request", and the answer.
    assert_equal 3, ticket.conversation.messages.count
  end

  test "the README's ticket readers all answer" do
    ticket = ticket_for(@alice, about: @order)

    assert_match(/\AT-/, ticket.reference)
    assert_equal "Order SO1", ticket.label
    assert_equal "order", ticket.topic.path
    assert_equal @order, ticket.subject
    assert_equal "open", ticket.status
    assert_predicate ticket, :awaiting_reply?
    assert_kind_of ActiveSupport::Duration, ticket.waiting_for
    assert_not_predicate ticket, :overdue?
    assert_not_predicate ticket, :at_risk?
    assert_nil ticket.time_to_first_reply
    assert_nil ticket.time_to_close
  end

  test "the README's queue lines all answer" do
    ticket_for(create_user)
    q = @lucia.support_queue

    assert_kind_of ActiveRecord::Relation, q.mine
    assert_kind_of ActiveRecord::Relation, q.unassigned
    assert_kind_of ActiveRecord::Relation, q.awaiting
    assert_kind_of Hash, q.counts
    assert_kind_of Integer, q.badge
    assert_kind_of SupportDesk::Ticket, q.next
    assert_equal 6, q.tabs.size
  end

  test "the README's event wiring works as written" do
    seen = []
    SupportDesk.on(:ticket_opened) { |ticket| seen << [ :opened, ticket.agents_to_notify ] }
    SupportDesk.on(:requester_replied) { |ticket, _message| seen << [ :replied, ticket.agents_to_notify ] }
    SupportDesk.on(:ticket_transitioned) do |ticket, kind, by:, request:, payload:|
      seen << [ :transitioned, kind, by, payload, request ]
    end

    ticket = @alice.ask_support!("hola", about: @order)
    @alice.message!(ticket.conversation, "¿alguna noticia?")
    ticket.close!(by: @lucia)

    # Opening is a transition too, so the audit hook sees it first.
    assert_equal %i[transitioned opened replied transitioned], seen.map(&:first)
  end
end
