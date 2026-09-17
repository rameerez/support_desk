# frozen_string_literal: true

require "test_helper"

class DoctorTest < ActiveSupport::TestCase
  test "a healthy install is green, and says so" do
    ticket_for(create_user)
    report = SupportDesk.doctor

    assert_predicate report, :ok?
    assert_empty report.failures
    assert_includes report.to_s, "support_desk is healthy"
  end

  test "the report prints and answers with its own verdict" do
    output = StringIO.new

    assert SupportDesk.doctor.print(output)
    assert_includes output.string, "requester_class"
  end

  test "a requester_class that isn't one fails the check, not the doctor" do
    SupportDesk.config.requester_class = "Order"
    report = SupportDesk.doctor

    assert_not_predicate report, :ok?
    assert_match(/has_support_tickets/, report.failures.map(&:message).join)
  end

  test "an about: class that isn't supportable fails" do
    SupportDesk.config.topics { topic :nope, about: "User" }
    report = SupportDesk.doctor

    assert_not_predicate report, :ok?
    assert_match(/not supportable: User/, report.failures.map(&:message).join)
  end

  test "a tree with no way out is a warning, not a failure" do
    SupportDesk.config.topics { topic :order, about: "Order" }
    report = SupportDesk.doctor

    assert_predicate report, :ok?
    assert_match(/no free-form topic/, report.warnings.map(&:message).join)
  end

  test "an agents block that raises is reported as a failed check" do
    SupportDesk.config.agents { raise "no pool" }
    report = SupportDesk.doctor

    assert_not_predicate report, :ok?
    assert_match(/no pool/, report.failures.map(&:message).join)
  end

  test "it checks the chats seams this gem is built on" do
    names = SupportDesk.doctor.checks.map(&:name)

    assert_includes names, "chats subscribers"
    assert_includes names, "chats authorship"
    assert_includes names, "desk messager"
  end

  test "a ticket without a conversation fails the invariant" do
    ticket = ticket_for(create_user)
    ticket.update_columns(conversation_id: nil)

    assert_match(/without a conversation/, SupportDesk.doctor.failures.map(&:message).join)
  end

  test "an assignee with no open assignment fails the invariant" do
    ticket = ticket_for(create_user)
    lucia = create_agent
    ticket.assign!(to: lucia, by: lucia)
    ticket.assignments.open.each { |assignment| assignment.release!(reason: :released) }

    assert_match(/no open assignment/, SupportDesk.doctor.failures.map(&:message).join)
  end

  test "two open assignments on one ticket are impossible where partial indexes exist" do
    ticket = ticket_for(create_user)
    lucia = create_agent
    pedro = create_agent
    SupportDesk::Assignment.create!(ticket: ticket, agent: lucia, reason: "assigned", assigned_at: Time.current)

    second = lambda do
      SupportDesk::Assignment.create!(ticket: ticket, agent: pedro, reason: "assigned", assigned_at: Time.current)
    end

    if partial_indexes?
      # The partial unique index is the belt; the doctor is the braces.
      assert_raises(ActiveRecord::RecordNotUnique) { second.call }
    else
      second.call

      assert_match(/more than one open assignment/, SupportDesk.doctor.failures.map(&:message).join)
    end
  end

  test "a ticket waiting on the desk after the desk answered fails the invariant" do
    ticket = ticket_for(create_user)
    ticket.update_columns(awaiting: "agent", last_agent_message_at: Time.current,
                          last_requester_message_at: 1.hour.ago)

    assert_match(/after the desk already answered/, SupportDesk.doctor.failures.map(&:message).join)
  end

  test "a check that explodes is a failed check with the error in it" do
    SupportDesk.config.requester_class = "Ghost"
    report = SupportDesk.doctor

    assert_not_predicate report, :ok?
    assert_match(/doesn't exist/, report.failures.map(&:message).join)
  end

  test "an unmounted engine is a warning" do
    SupportDesk.stub(:root_path, nil) do
      report = SupportDesk.doctor

      assert_predicate report, :ok?
      assert_match(/isn't mounted/, report.warnings.map(&:message).join)
    end
  end
  test "a case waiting on the desk that only the desk has spoken in fails the invariant too" do
    # The NULL leg: `last_agent_message_at > last_requester_message_at` is
    # NULL when the requester has never written, so a plain comparison walks
    # straight past this row.
    ticket = ticket_for(create_user)
    ticket.update_columns(awaiting: "agent", last_agent_message_at: Time.current,
                          last_requester_message_at: nil)

    assert_match(/after the desk already answered/, SupportDesk.doctor.failures.map(&:message).join)
  end

  test "provenance: half an opened_by fails, and a legacy row asks for the backfill" do
    healthy = ticket_for(create_user)

    assert_predicate SupportDesk.doctor, :ok?

    legacy = ticket_for(create_user)
    legacy.update_columns(opened_by_type: nil, opened_by_id: nil)
    report = SupportDesk.doctor

    assert_predicate report, :ok?, "a row to backfill is a warning, not a failure"
    assert_match(/backfill_opened_by/, report.warnings.map(&:message).join)

    healthy.update_columns(opened_by_id: nil)

    assert_match(/half an opened_by/, SupportDesk.doctor.failures.map(&:message).join)
  end
  test "an opening line naming a translation nobody wrote is a failed check" do
    SupportDesk.config.opening_line = :"support_desk.thread.nope"

    report = SupportDesk.doctor

    assert_not_predicate report, :ok?
    assert_match(/no .* translation/, report.failures.map(&:message).join)
  end

  test "a block opening line is left alone: running a host's callback is not a diagnostic" do
    called = false
    SupportDesk.config.opening_line { |_ticket| called = true }

    assert_predicate SupportDesk.doctor, :ok?
    assert_not called
  end

  test "find_requester is checked by its shape, never by calling it" do
    called = false

    assert_match(/not set/, SupportDesk.doctor.checks.find { |check| check.name == "find_requester" }.message)

    SupportDesk.config.find_requester { |_query| called = true }

    assert_predicate SupportDesk.doctor, :ok?
    assert_not called

    SupportDesk.config.find_requester = -> { nil }

    assert_match(/calls it with one/, SupportDesk.doctor.failures.map(&:message).join)

    SupportDesk.config.find_requester = Class.new { def call(query) = query }.new

    assert_predicate SupportDesk.doctor, :ok?
  end
end
