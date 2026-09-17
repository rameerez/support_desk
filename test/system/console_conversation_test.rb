# frozen_string_literal: true

require "application_system_test_case"

# Writing first, in a real browser: the form, the case it lands on, and what
# happens when the first attempt is refused and the agent fixes it and sends
# again.
#
# An integration test cannot see that last part. A 422 that re-renders the
# form is only worth something if the browser then submits the CORRECTED form
# ONCE, into one case, with one message in it.
#
# It enters through the form's own URL rather than the queue's "Write to
# someone" button: turbo-rails patches `visit` to wait for every
# `<turbo-cable-stream-source>` on the page to connect, and the queue streams
# its own refreshes, which the dummy has no cable for. The button itself is
# checked where it can be — `console_engine_test.rb`, over HTTP.
class ConsoleConversationTest < ApplicationSystemTestCase
  setup do
    @alice = create_user(name: "Alice", email: "alice@example.com")
    @lucia = create_agent(name: "Lucía")
    SupportDesk.desk
    SupportDesk.config.find_requester { |query| User.find_by(email: query.to_s.strip.downcase) }

    login_as @lucia
  end

  test "an agent writes to somebody and lands on the case" do
    visit "/admin/support/new"

    assert_selector "h1", text: "Write as support"

    fill_in "requester_query", with: "alice@example.com"
    select "Something else", from: "topic"
    fill_in "body", with: "Vimos que tu pedido no llegó"
    click_on "Send as Soporte"

    # Wait for the page the browser landed on BEFORE reading the database:
    # `sole` waits for nothing, and the POST is still in flight.
    assert_text "Vimos que tu pedido no llegó"

    ticket = SupportDesk::Ticket.sole

    assert_current_path "/admin/support/#{ticket.id}"
    assert_predicate ticket, :opened_by_support?
    assert_equal @lucia, ticket.opened_by
  end

  test "a refusal comes back with the draft, and the retry sends exactly once" do
    visit "/admin/support/new"

    fill_in "requester_query", with: "nobody@example.com"
    fill_in "body", with: "Vimos que tu pedido no llegó"
    click_on "Send as Soporte"

    assert_text "We can't find that person."
    # Still in the box: nobody should have to retype their message to fix an
    # email address.
    assert_field "body", with: "Vimos que tu pedido no llegó"
    assert_equal 0, SupportDesk::Ticket.count

    fill_in "requester_query", with: "alice@example.com"
    click_on "Send as Soporte"

    assert_text "Vimos que tu pedido no llegó"

    ticket = SupportDesk::Ticket.sole

    assert_current_path "/admin/support/#{ticket.id}"
    assert_equal 1, ticket.messages.where(kind: "text").count, "the refused attempt posted nothing"
  end
end
