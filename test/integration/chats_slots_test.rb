# frozen_string_literal: true

require "test_helper"

# What this engine contributes to CHATS' screens, through the view slots
# (seam S5): the door above the inbox, and the way out of a locked case.
class ChatsSlotsTest < ActionDispatch::IntegrationTest
  setup do
    @alice = create_user(name: "Alice", onboarded: true)
    @lucia = create_agent(name: "Lucía")
    login_as @alice
  end

  # --- The inbox door -----------------------------------------------------------

  test "with no cases at all, the inbox carries the door" do
    get "/messages"

    assert_response :success
    assert_select ".support-desk-inbox-door a[href=?]", "/messages/support/"
    assert_select ".support-desk-inbox-door .chats-row__preview",
                  text: I18n.t("support_desk.inbox.empty_hint")
  end

  test "the door steps aside once the desk has a row of its own" do
    ticket_for(@alice, topic: :other)
    get "/messages"

    assert_response :success
    assert_select ".support-desk-inbox-door", count: 0
    # chats renders the desk's grouped row instead — one entry, never two.
    assert_select ".chats-row--group .chats-row__title", text: "Soporte"
  end

  test "inbox_entry :when_tickets keeps the inbox to itself until there is a case" do
    SupportDesk.config.inbox_entry = :when_tickets
    get "/messages"

    assert_response :success
    assert_select ".support-desk-inbox-door", count: 0
  end

  test "inbox_entry :never never renders it" do
    SupportDesk.config.inbox_entry = :never
    get "/messages"

    assert_response :success
    assert_select ".support-desk-inbox-door", count: 0
  end

  test "the door never INSERTs a desk just because somebody opened their inbox" do
    SupportDesk::Desk.delete_all
    SupportDesk.reset_desks!

    assert_no_difference -> { SupportDesk::Desk.count } do
      get "/messages"
    end

    assert_select ".support-desk-inbox-door .chats-avatar--initials", text: "S"
  end

  # --- The locked case ----------------------------------------------------------

  test "a locked closed case offers a new conversation where its composer was" do
    SupportDesk.config.closed_tickets = :locked
    ticket = ticket_for(@alice, topic: :other)
    ticket.close!(by: @lucia)

    get "/messages/#{ticket.conversation.id}"

    assert_response :success
    assert_select ".chats-composer--locked a[href=?]", "/messages/support/new?topic=other",
                  text: I18n.t("support_desk.doors.new_conversation")
    assert_select ".chats-composer__locked-notice", text: I18n.t("support_desk.thread.closed_notice")
  end

  test "a conversation that is not a case keeps chats' own locked composer" do
    # A LOCKED conversation about something that isn't a ticket: the slot
    # replaces the composer's body for every locked conversation in the host,
    # so it has to render chats' own notice and nothing of ours.
    bob = create_user(name: "Bob")
    order = create_order(user: @alice, number: "CLOSED", state: "closed")
    conversation = @alice.chat_with(bob, about: order)

    get "/messages/#{conversation.id}"

    assert_response :success
    assert_select ".chats-composer--locked"
    assert_select ".chats-composer__locked-notice", text: "This order is closed."
    assert_select ".support-desk-button", count: 0
  end

  test "the default desk leaves the composer alone, because writing reopens the case" do
    ticket = ticket_for(@alice, topic: :other)
    ticket.close!(by: @lucia)

    get "/messages/#{ticket.conversation.id}"

    assert_response :success
    assert_select ".chats-composer--locked", count: 0
    assert_select "textarea"
  end
end
