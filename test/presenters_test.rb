# frozen_string_literal: true

require "test_helper"

class PresentersTest < ActiveSupport::TestCase
  setup do
    @alice = create_user(name: "Alice")
    @lucia = create_agent(name: "Lucía")
    @order = create_order(user: @alice, number: "SO1", state: "paid")
    @ticket = ticket_for(@alice, about: @order, message: "No ha llegado")
  end

  # --- ContextCard --------------------------------------------------------------

  test "the context card is everything next to the transcript" do
    card = @ticket.context_card

    assert_equal "Order SO1", card.title
    assert_equal "paid", card.status
    assert_equal({ "Total" => 0.0, "Estado" => "paid" }, card.pairs)
    assert_nil card.subject_url
    assert_equal "Order", card.topic_label
    assert_equal "Alice", card.requester_name
    assert_equal 1, card.requester_open_tickets
  end

  test "the context card of a free-form ticket still renders" do
    card = ticket_for(create_user).context_card

    assert_nil card.subject
    assert_nil card.status
    assert_empty card.pairs
    assert_equal "Something else", card.title
  end

  test "the card is a hash when a JSON API needs one" do
    assert_equal "Order SO1", @ticket.context_card.to_h[:title]
  end

  # --- Summary -------------------------------------------------------------------

  test "the summary is one line with the state in it" do
    summary = @ticket.summary.to_s

    assert_includes summary, @ticket.reference
    assert_includes summary, "Order SO1"
    assert_includes summary, "Alice"
    assert_includes summary, "awaiting reply"
  end

  test "the summary follows the case" do
    @ticket.reply!("vamos", by: @lucia)

    assert_includes @ticket.reload.summary.to_s, "awaiting requester"

    @ticket.close!(by: @lucia)

    assert_includes @ticket.reload.summary.to_s, "closed"
  end

  test "the summary is a hash too" do
    @ticket.assign!(to: @lucia, by: @lucia)

    assert_equal "Lucía", @ticket.summary.to_h[:assignee]
  end

  # --- Timeline ------------------------------------------------------------------

  test "the timeline merges what was said and what was done, by time" do
    @ticket.assign!(to: @lucia, by: @lucia)
    @ticket.reply!("vamos", by: @lucia)
    @ticket.note!("cliente VIP", by: @lucia)
    @ticket.close!(by: @lucia)

    kinds = @ticket.timeline.map(&:kind)

    assert_equal %i[opened message assigned message message note closed], kinds
  end

  test "a timeline entry knows who is responsible for it" do
    @ticket.reply!("vamos", by: @lucia)

    reply = @ticket.timeline.find { |entry| entry.message? && entry.body == "vamos" }

    assert_equal @lucia, reply.actor
    assert_predicate reply, :message?
    assert_not_predicate reply, :event?

    opened = @ticket.timeline.find { |entry| entry.kind == :opened }

    assert_equal @alice, opened.actor
  end

  test "the timeline prints itself for a console" do
    output = StringIO.new
    @ticket.timeline.print(output)

    assert_includes output.string, "No ha llegado"
    assert_includes output.string, "opened"
  end

  test "the timeline is enumerable and sized" do
    assert_equal 2, @ticket.timeline.size
    assert_equal 2, @ticket.timeline.to_a.size
    assert_kind_of SupportDesk::Timeline::Entry, @ticket.timeline.last
  end
  # The console is rendered in the reader's language, so the waiting time has
  # to be too. Duration#inspect is English whatever the locale, which left
  # "Esperando respuesta · 27 seconds" in an otherwise Spanish console.
  test "the waiting time speaks the reader's language" do
    ticket = @alice.ask_support!("hola", topic: :other)
    ticket.update_columns(awaiting: "agent", waiting_since: 27.minutes.ago)

    I18n.with_locale(:es) { assert_equal "27 minutos", ticket.summary.waiting }
    I18n.with_locale(:en) { assert_equal "27 minutes", ticket.summary.waiting }
  end

end
