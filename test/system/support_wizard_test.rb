# frozen_string_literal: true

require "application_system_test_case"

# The three frames, driven the way a person drives them.
class SupportWizardTest < ApplicationSystemTestCase
  setup do
    @alice = create_user(name: "Alice", onboarded: true)
    @lucia = create_agent(name: "Lucía")
    @order = create_order(user: @alice, number: "SO1")
    login_as @alice
  end

  test "topic, thing, write — and the URL keeps up with the frame" do
    visit "/messages/support"
    click_on "Start a new conversation"

    assert_selector "h1", text: "What do you need help with?"
    assert_current_path "/messages/support/new"

    click_on "Order"

    # The frame re-rendered in place, and `turbo_action: advance` pushed the
    # step into history: this is a real URL, which is what the native apps
    # and the back gesture need it to be.
    assert_selector "h1", text: "Which one?"
    assert_current_path "/messages/support/new", ignore_query: true
    assert_equal "order", URI.decode_www_form(URI.parse(current_url).query).to_h["topic"]

    click_on "Order SO1"

    assert_selector "h1", text: "Tell us what happened"
    assert_selector ".support-desk-card__label", text: "Order SO1"

    fill_in "message", with: "No ha llegado"
    click_on "Send"

    # Submitting leaves the frame and lands in the conversation itself. Wait
    # for the navigation BEFORE reading the database: the click returns the
    # moment it is dispatched, and the ticket is written by the request it
    # kicks off.
    assert_current_path(%r{\A/messages/[^/]+\z})

    ticket = SupportDesk::Ticket.last

    assert_current_path "/messages/#{ticket.conversation.id}"
    assert_text "No ha llegado"
    assert_equal @order, ticket.subject
  end

  test "back walks the steps it came in through" do
    visit "/messages/support/new"
    click_on "Billing"

    assert_selector ".support-desk-choice__label", text: "Invoice"

    click_on "Back"

    assert_selector ".support-desk-choice__label", text: "Order"
    assert_current_path "/messages/support/new"
  end

  test "none of these skips the picker and still opens a case" do
    visit "/messages/support/new?topic=order"
    click_on "None of these"

    assert_selector "h1", text: "Tell us what happened"

    fill_in "message", with: "Es sobre otra cosa"
    click_on "Send"

    assert_current_path(%r{\A/messages/[^/]+\z})

    ticket = SupportDesk::Ticket.last

    assert_nil ticket.subject
    assert_equal "order", ticket.topic.path
    assert_current_path "/messages/#{ticket.conversation.id}"
  end

  test "something already being talked about links into that conversation" do
    ticket = ticket_for(@alice, about: @order)

    visit "/messages/support/new?topic=order"
    click_on "Order SO1"

    assert_current_path "/messages/#{ticket.conversation.id}"
  end

  test "an empty message is refused without losing the step" do
    visit "/messages/support/new?topic=other"
    click_on "Send"

    # By CSS rather than assert_text: the 422 replaces the whole document,
    # and reading `page.text` across that swap can catch a node that no
    # longer belongs to it.
    assert_selector ".support-desk-error", text: I18n.t("support_desk.wizard.message_required")
    assert_selector "textarea[name=message]"
    assert_equal 0, SupportDesk::Ticket.count
  end
end
