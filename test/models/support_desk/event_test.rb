# frozen_string_literal: true

require "test_helper"

module SupportDesk
  class EventTest < ActiveSupport::TestCase
    setup do
      @alice = create_user
      @lucia = create_agent
      @ticket = ticket_for(@alice)
    end

    test "record! writes one row with its payload" do
      event = Event.record!(ticket: @ticket, kind: :closed, actor: @lucia, payload: { "reason" => "solved" })

      assert_equal "closed", event.kind
      assert_equal @lucia, event.actor
      assert_equal "solved", event.payload["reason"]
    end

    test "a symbol actor is kept in the payload, since there is no row to point at" do
      event = Event.record!(ticket: @ticket, kind: :closed, actor: :system)

      assert_nil event.actor
      assert_equal "system", event.payload["by"]
      assert_equal :system, event.actor_or_system
    end

    test "events are append-only" do
      event = Event.record!(ticket: @ticket, kind: :note, actor: @lucia, payload: { "note" => "ojo" })

      assert_predicate event, :readonly?
      assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(kind: "closed") }
    end

    test "kinds are validated in the model, not by a check constraint" do
      assert_raises(ActiveRecord::RecordInvalid) do
        Event.record!(ticket: @ticket, kind: :exploded, actor: @lucia)
      end
    end

    test "requester_visible hides notes and drop-ins" do
      @ticket.note!("interno", by: @lucia)

      kinds = @ticket.events.requester_visible.map(&:kind)

      assert_includes kinds, "opened"
      assert_not_includes kinds, "note"
    end

    test "destroying a ticket takes its timeline with it" do
      @ticket.note!("interno", by: @lucia)
      ticket_id = @ticket.id

      @ticket.destroy!

      assert_empty Event.where(ticket_id: ticket_id)
    end
  end
end
