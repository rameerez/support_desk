# frozen_string_literal: true

require "test_helper"

# The requester's support list: /support.
class TicketsIndexTest < ActionDispatch::IntegrationTest
  setup do
    @alice = create_user(name: "Alice", onboarded: true)
    @lucia = create_agent(name: "Lucía")
    @order = create_order(user: @alice, number: "SO1")
  end

  test "the list needs a logged-in requester" do
    get "/messages/support"

    assert_response :unauthorized
  end

  test "an empty list is a door and a reassurance, never a blank screen" do
    login_as @alice
    get "/messages/support"

    assert_response :success
    assert_select "a[href=?]", "/messages/support/new", text: /Abrir una nueva conversación|Start a new conversation/
    assert_select ".chats-empty__title"
  end

  test "open cases render as rows that link into their conversation" do
    ticket = ticket_for(@alice, about: @order)
    login_as @alice
    get "/messages/support"

    assert_response :success
    assert_select ".chats-row__title", text: "Order SO1"
    assert_select "a[href=?]", "/messages/#{ticket.conversation.id}"
    # Who owes the next word, in the requester's terms.
    assert_select ".chats-row__subject", text: I18n.t("support_desk.tickets.state.awaiting_reply")
  end

  test "an answered case says so, and carries its unread badge" do
    ticket = ticket_for(@alice, about: @order)
    reply_as @lucia, ticket, "Lo estamos mirando"

    login_as @alice
    get "/messages/support"

    assert_select ".chats-row__subject", text: I18n.t("support_desk.tickets.state.answered")
    assert_select ".chats-badge"
    assert_select ".chats-row__preview", text: /Lo estamos mirando/
  end

  test "closed cases are folded away while something is still live" do
    open_ticket = ticket_for(@alice, about: @order)
    closed = ticket_for(@alice, topic: :other)
    closed.close!(by: @lucia)

    login_as @alice
    get "/messages/support"

    assert_select "details.support-desk-closed:not([open])"
    assert_select "details.support-desk-closed .chats-row__title", text: closed.label
    assert_select "ul.chats-inbox__list > li .chats-row__title", text: open_ticket.label
  end

  test "with nothing open, the closed section is already expanded" do
    ticket = ticket_for(@alice, about: @order)
    ticket.close!(by: @lucia)

    login_as @alice
    get "/messages/support"

    assert_select "details.support-desk-closed[open]"
    assert_select ".chats-row__subject", text: I18n.t("support_desk.tickets.state.closed")
  end

  test "the list never shows another requester's cases" do
    mallory = create_user(name: "Mallory")
    ticket_for(mallory, topic: :other, message: "Lo de Mallory")

    login_as @alice
    get "/messages/support"

    assert_response :success
    assert_select ".chats-row", count: 0
  end

  test "the door carries the desk's promise, which is the SLA it breaches on" do
    login_as @alice
    get "/messages/support"

    assert_select ".support-desk-door__hint", text: /1 day|24 hours/
  end
  test "the list costs the same number of queries however many cases there are" do
    # The caps are the desk's business, not this test's.
    SupportDesk.config.open_rate_limit = nil
    SupportDesk.config.max_open_tickets = nil
    3.times { |i| ticket_for(@alice, about: create_order(user: @alice, number: "SO#{i}")) }
    login_as @alice
    get "/messages/support"
    three = count_queries { get "/messages/support" }

    5.times { |i| ticket_for(@alice, about: create_order(user: @alice, number: "MORE#{i}")) }
    eight = count_queries { get "/messages/support" }

    # `Ticket#label` reads the polymorphic subject, so without it preloaded
    # this grows by one query per row.
    assert_equal three.size, eight.size, "the index is N+1:\n#{(eight - three).join("\n")}"
  end

  test "the closed section counts what is really there, and says what it is showing" do
    SupportDesk.config.open_rate_limit = nil
    SupportDesk.config.max_open_tickets = nil
    ticket_for(@alice, about: @order)
    25.times do |i|
      ticket = ticket_for(@alice, about: create_order(user: @alice, number: "OLD#{i}"))
      ticket.close!(by: @lucia)
    end
    login_as @alice
    get "/messages/support"

    assert_select ".support-desk-closed__summary", text: /25/
    assert_select "details.support-desk-closed .chats-row",
                  count: SupportDesk::TicketsController::CLOSED_TICKETS_SHOWN
    assert_select ".support-desk-closed__capped"
  end

  test "the stylesheet goes in the head, where a stylesheet belongs" do
    login_as @alice
    get "/messages/support"

    assert_select "head link[href*=?]", "support_desk"
    assert_select "body link[href*=?]", "support_desk", count: 0
  end
end
