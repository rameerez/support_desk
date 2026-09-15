# frozen_string_literal: true

require "test_helper"

# What somebody at the cap sees. A limit a requester can hit is a screen, not
# an exception: the wall always carries the way out on it.
class TicketLimitsTest < ActionDispatch::IntegrationTest
  setup do
    @alice = create_user(name: "Alice", onboarded: true)
    @lucia = create_agent(name: "Lucía")
    login_as @alice
  end

  test "at the open-ticket cap, the wall lists the conversations they already have" do
    SupportDesk.config.max_open_tickets = 1
    existing = ticket_for(@alice, topic: :other, message: "La primera")

    assert_no_difference -> { SupportDesk::Ticket.count } do
      post "/messages/support/tickets", params: { topic: "order", no_subject: "1", message: "La segunda" }
    end

    assert_response :too_many_requests
    assert_select ".chats-row__title", text: existing.label
    assert_select "a[href=?]", "/messages/#{existing.conversation.id}"
    assert_match(/already have|Ya tienes/, response.body)
  end

  test "opening too many too fast says so in its own words" do
    SupportDesk.config.max_open_tickets = nil
    SupportDesk.config.open_rate_limit = { to: 1, within: 1.hour }
    ticket_for(@alice, topic: :other, message: "La primera")

    post "/messages/support/tickets", params: { topic: "order", no_subject: "1", message: "La segunda" }

    assert_response :too_many_requests
    assert_select ".support-desk-notice__title", text: I18n.t("support_desk.limits.too_fast")
  end

  test "the cap never blocks writing into a case that is already open" do
    SupportDesk.config.max_open_tickets = 1
    existing = ticket_for(@alice, about: create_order(user: @alice, number: "SO1"))

    # The same subject resolves to the same ticket, so the cap is never
    # consulted: "you already have this one" beats "you have too many".
    post "/messages/support/tickets",
         params: { topic: "order", subject: SupportDesk::Wizard.sign_subject(existing.subject), message: "Otra vez" }

    assert_redirected_to "/messages/#{existing.conversation.id}"
  end

  test "a limit is never a 500" do
    SupportDesk.config.max_open_tickets = 1
    ticket_for(@alice, topic: :other)

    post "/messages/support/tickets", params: { topic: "order", no_subject: "1", message: "…" }

    assert_response :too_many_requests
  end
end
