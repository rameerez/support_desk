# frozen_string_literal: true

require "application_system_test_case"

# The support list, in a browser: the door, the rows, and the closed section
# that is a real disclosure rather than a second page.
class SupportListTest < ApplicationSystemTestCase
  setup do
    @alice = create_user(name: "Alice", onboarded: true)
    @lucia = create_agent(name: "Lucía")
    @order = create_order(user: @alice, number: "SO1")
    login_as @alice
  end

  test "an empty list is a door, and the door opens the wizard" do
    visit "/messages/support"

    assert_text "You haven't written to us yet"

    click_on "Start a new conversation"

    assert_selector "h1", text: "What do you need help with?"
  end

  test "a case is one tap from the list to the conversation" do
    ticket = ticket_for(@alice, about: @order, message: "No ha llegado")

    visit "/messages/support"

    assert_selector ".chats-row__title", text: "Order SO1"

    click_on "Order SO1"

    assert_current_path "/messages/#{ticket.conversation.id}"
    assert_text "No ha llegado"
  end

  test "closed cases stay folded until somebody asks for them" do
    ticket_for(@alice, about: @order)
    closed = ticket_for(@alice, topic: :other, message: "Una duda vieja")
    closed.close!(by: @lucia)

    visit "/messages/support"

    assert_no_text closed.label
    assert_text "1 closed conversation"

    find("summary", text: "1 closed conversation").click

    assert_text closed.label
  end

  # NOTE: the door this engine puts on CHATS' inbox is covered by
  # ChatsSlotsTest rather than here. chats' inbox renders
  # `turbo_stream_from`, and turbo-rails' system-test helper blocks on every
  # cable stream source reporting `connected` before `visit` returns — which
  # it never does in this dummy, whose Action Cable has no server behind it.
  # That is chats' harness to fix, not this engine's behaviour.
end
