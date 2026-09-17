# frozen_string_literal: true

require "test_helper"

# The two public view helpers (PRD §4.6), unit level: what they render, and
# — more importantly — what they refuse to render. `link_to_support` sits in
# generic partials, so "nothing" has to be its answer far more often than
# "a link".
class EngineHelperTest < ActionView::TestCase
  include SupportDesk::EngineHelper

  setup do
    @alice = create_user(name: "Alice Wonder", onboarded: true)
    @mallory = create_user(name: "Mallory")
    @order = create_order(user: @alice, number: "SO1")
  end

  # ActionView::TestCase has no controller auth — emulate the host's
  # current_user the way any host view context exposes it.
  attr_accessor :stubbed_viewer

  def current_user = stubbed_viewer

  test "link_to_support renders nothing when there is nobody to ask" do
    self.stubbed_viewer = nil

    assert_nil link_to_support(about: @order)
    assert_nil link_to_support
  end

  test "link_to_support renders nothing for a record that isn't supportable" do
    self.stubbed_viewer = @alice

    assert_nil link_to_support(about: @mallory)
  end

  test "link_to_support renders nothing for somebody else's record" do
    self.stubbed_viewer = @mallory

    assert_nil link_to_support(about: @order)
  end

  test "link_to_support signs the subject rather than naming it" do
    self.stubbed_viewer = @alice
    html = link_to_support(about: @order)

    assert_includes html, "about="
    assert_not_includes html, "about=#{@order.id}"
    assert_includes html, "Need help with Order SO1?"
  end

  test "link_to_support takes its own text and html options" do
    self.stubbed_viewer = @alice
    html = link_to_support(about: @order, text: "Reportar un problema", class: "btn")

    assert_includes html, "Reportar un problema"
    assert_includes html, 'class="btn"'
  end

  test "link_to_support with no subject is just the way in" do
    self.stubbed_viewer = @alice

    assert_includes link_to_support, "Need help?"
  end

  test "support_unread_badge counts nothing into nothing" do
    self.stubbed_viewer = @alice

    assert_nil support_unread_badge
    assert_nil support_unread_badge(nil)
    assert_nil support_unread_badge(@order) # not a requester at all
  end

  test "support_wizard_partial names the frame for the step the wizard is on" do
    assert_equal "support_desk/tickets/pick_topic",
                 support_wizard_partial(SupportDesk::Wizard.new(@alice))
    assert_equal "support_desk/tickets/pick_thing",
                 support_wizard_partial(SupportDesk::Wizard.new(@alice, { topic: "order" }))
    assert_equal "support_desk/tickets/write",
                 support_wizard_partial(SupportDesk::Wizard.new(@alice, { topic: "other" }))
  end

  test "support_ticket_state says who owes the next word, in the requester's terms" do
    ticket = ticket_for(@alice, about: @order)
    lucia = create_agent

    assert_equal I18n.t("support_desk.tickets.state.awaiting_reply"), support_ticket_state(ticket)

    reply_as lucia, ticket, "Vamos a mirarlo"

    # The clocks move under the subscriber's OWN copy of the row, so this
    # one is stale until it is reloaded — the same reason the gem's
    # assert_awaiting_* helpers reload.
    assert_equal I18n.t("support_desk.tickets.state.answered"), support_ticket_state(ticket.reload)

    ticket.close!(by: lucia)

    assert_equal I18n.t("support_desk.tickets.state.closed"), support_ticket_state(ticket)
  end

  test "support_reply_promise is the SLA, and nothing when the desk promises nothing" do
    assert_match(/1 day|24 hours/, support_reply_promise)

    SupportDesk.config.at_risk_after = nil
    SupportDesk.config.reply_within = nil

    assert_nil support_reply_promise
  end

  test "support_inbox_door? is only for a requester who has never written" do
    assert support_inbox_door?(@alice)

    ticket_for(@alice, topic: :other)

    assert_not support_inbox_door?(@alice)
    assert_not support_inbox_door?(@order) # not a requester
  end

  test "support_inbox_door? honours inbox_entry" do
    SupportDesk.config.inbox_entry = :when_tickets

    assert_not support_inbox_door?(@alice)

    SupportDesk.config.inbox_entry = :never

    assert_not support_inbox_door?(@alice)
  end

  test "support_desk_avatar falls back to initials while the desk has no row" do
    SupportDesk::Desk.delete_all
    SupportDesk.reset_desks!
    html = support_desk_avatar

    assert_includes html, "chats-avatar--initials"
    assert_includes html, ">S<"
  end

  test "a case the desk opened reads 'we wrote to you' until the requester answers" do
    lucia = create_agent(name: "Lucía")
    written = lucia.open_support_conversation_with!(@alice, "Vimos que tu pedido no llegó")

    assert_equal "We wrote to you", support_ticket_state(written)

    ask_again written, "ah, no lo sabía"

    assert_equal "We're on it", support_ticket_state(written.reload)

    written.reply!("te contamos", by: lucia)

    assert_equal "We replied", support_ticket_state(written.reload)
  end
end
