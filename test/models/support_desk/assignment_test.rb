# frozen_string_literal: true

require "test_helper"

module SupportDesk
  class AssignmentTest < ActiveSupport::TestCase
    setup do
      @alice = create_user
      @lucia = create_agent(name: "Lucía")
      @pedro = create_agent(name: "Pedro")
      @ticket = ticket_for(@alice)
    end

    test "open! closes the previous holder's row and opens a new one" do
      first = Assignment.open!(ticket: @ticket, agent: @lucia, by: @lucia, reason: :taken)
      second = Assignment.open!(ticket: @ticket, agent: @pedro, by: @lucia, reason: :handed_off,
                                release_reason: :handed_off)

      assert_predicate first.reload, :released?
      assert_equal "handed_off", first.release_reason
      assert_predicate second, :open?
      assert_equal 1, Assignment.open.where(ticket: @ticket).count
    end

    test "the default release reason follows the new assignment's reason" do
      assert_equal "handed_off", Assignment.default_release_reason(:handed_off)
      assert_equal "escalated", Assignment.default_release_reason(:escalated)
      assert_equal "released", Assignment.default_release_reason(:assigned)
    end

    test "release! is idempotent" do
      assignment = Assignment.open!(ticket: @ticket, agent: @lucia, by: @lucia, reason: :taken)
      assignment.release!(reason: :shift_end)
      released_at = assignment.released_at

      assignment.release!(reason: :closed)

      assert_equal released_at, assignment.reload.released_at
      assert_equal "shift_end", assignment.release_reason
    end

    test "held_for measures the seat" do
      assignment = Assignment.open!(ticket: @ticket, agent: @lucia, by: @lucia, reason: :taken)
      assignment.update!(assigned_at: 2.hours.ago)

      assert_in_delta 2.hours.to_i, assignment.held_for.to_i, 5
    end

    test "reasons are validated" do
      assert_raises(ActiveRecord::RecordInvalid) do
        Assignment.create!(ticket: @ticket, agent: @lucia, reason: "borrowed", assigned_at: Time.current)
      end
    end

    test "a symbol actor leaves assigned_by empty rather than inventing a record" do
      assignment = Assignment.open!(ticket: @ticket, agent: @lucia, by: :routing, reason: :routed)

      assert_nil assignment.assigned_by
      assert_equal "routed", assignment.reason
    end
  end
end
