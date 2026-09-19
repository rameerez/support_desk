# frozen_string_literal: true

require "test_helper"

# §12.11 — the doctor's assistant checks.
#
# Every one of them asks EVIDENCE, never the policy's own verdict: a seat
# that exists, a timestamp that has passed, a row that is there twice. A
# policy cannot page anybody about its own bug.
class AssistantDoctorTest < ActiveSupport::TestCase
  setup do
    @alice = create_user(name: "Alice")
    @lucia = create_agent(name: "Lucía")
  end

  def check(name)
    SupportDesk.doctor.checks.find { |candidate| candidate.name == name }
  end

  def messages_of(status)
    SupportDesk.doctor.checks.select { |candidate| candidate.status == status }.map(&:message).join(" · ")
  end

  test "a desk with no assistant is asked none of these questions" do
    ticket_for(@alice)
    names = SupportDesk.doctor.checks.map(&:name)

    assert_empty names.grep(/assistant|drafts/), "nothing about a feature nobody turned on"
  end

  test "a healthy assistant is green" do
    configure_assistant!
    ticket_for(@alice)
    report = SupportDesk.doctor

    assert_predicate report, :ok?, report.failures.map(&:to_s).join(" · ")
    assert_equal :ok, check("assistants (config)").status
    assert_match(/1 assistant/, check("assistants (config)").message)
  end

  test "no max_turns and no promise are warnings, and they name themselves" do
    configure_assistant!(max_turns: nil, responds_within: nil)
    report = SupportDesk.doctor

    assert_predicate report, :ok?, "a warning never fails a build"
    assert_equal :warn, check("assistants (config)").status
    assert_match(/no max_turns/, check("assistants (config)").message)
    assert_match(/no responds_within/, check("assistants (config)").message)
  end

  test "a line naming a key nobody translated fails the check" do
    configure_assistant!(hand_off_line: :"support_desk.system.nope")

    assert_not_predicate SupportDesk.doctor, :ok?
    assert_match(/no .* translation/, check("assistants (config)").message)
  end

  test "an assistant nobody will ever ask to answer is a warning" do
    configure_assistant!

    assert_equal :warn, check("assistant turn subscriber").status
    assert_match(/nothing subscribes/, check("assistant turn subscriber").message)

    SupportDesk.on(:assistant_turn, key: "test") { |*| nil }

    assert_equal :ok, check("assistant turn subscriber").status
  end

  test "an assistant chats can't name fails, because a signed message would go out unsigned" do
    configure_assistant!
    Chats.config.messager_display_name = ->(_messager) { "" }

    assert_not_predicate SupportDesk.doctor, :ok?
    assert_match(/no display name for rose/, check("assistant authorship").message)
  end

  test "a host's own kind: :ai model is a warning, because it is refused everywhere" do
    configure_assistant!
    Object.const_set(:DoctorBot, Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      def self.name = "DoctorBot"
      acts_as_support_agent kind: :ai
    end)

    assert_equal :warn, check("ai agents without policy").status
    assert_match(/DoctorBot/, check("ai agents without policy").message)
    assert_match(/refused/, check("ai agents without policy").message)
  ensure
    SupportDesk.agent_class_names.delete("DoctorBot")
    Object.send(:remove_const, :DoctorBot)
  end

  test "the adapter that cannot take a row lock is a warning, and the one that can is not" do
    # The whole turn rests on `SELECT … FOR UPDATE` blocking a concurrent
    # writer. SQLite has no row locks, so a requester message committing
    # behind an answer is still missed there — a host has to be told which
    # of the two it is running.
    configure_assistant!(autonomy: :reply)
    serialization = check("assistant serialization")

    if ActiveRecord::Base.connection.adapter_name.match?(/sqlite/i)
      assert_equal :warn, serialization.status
      assert_match(/committing behind an answer/, serialization.message)
      assert_match(/PostgreSQL or MySQL/, serialization.message,
                   "a warning that doesn't name the way out is a warning nobody can act on")
    else
      assert_equal :ok, serialization.status
      assert_match(/row locks/, serialization.message)
    end
  end

  test "a desk with no assistant is not asked which adapter it runs" do
    ticket_for(@alice)

    assert_nil check("assistant serialization")
  end

  test "a case that has waited longer than her promise turns the doctor red" do
    rose = configure_assistant!(autonomy: :reply, responds_within: 60)
    ticket = ticket_for(@alice)
    ticket.assign!(to: rose, by: rose, turn: ticket.assistant_turn)

    assert_predicate SupportDesk.doctor, :ok?

    travel 2.minutes

    assert_not_predicate SupportDesk.doctor, :ok?
    assert_match(/waited longer than/, check("assistant silence (rose)").message)
    assert_match(/release_silent_assistants/, check("assistant silence (rose)").message,
                 "a failure that doesn't name the way out is a failure nobody can act on")
  end

  test "an assistant sitting on a case she may not work turns the doctor red" do
    rose = configure_assistant!(autonomy: :reply)
    ticket = ticket_for(@alice)
    ticket.assign!(to: rose, by: rose, turn: ticket.assistant_turn)
    # Straight to the column: this is exactly the state a bug would leave,
    # and the check has to see it however it got there.
    ticket.update_columns(assistant_paused_at: Time.current)

    assert_not_predicate SupportDesk.doctor, :ok?
    assert_match(/held by an assistant who may not hold them/, check("assistant seats").message)
    assert_match(/#{ticket.reference}/, check("assistant seats").message)
  end

  test "the seats check survives the configuration being taken away" do
    rose = configure_assistant!(autonomy: :reply)
    ticket = ticket_for(@alice)
    ticket.assign!(to: rose, by: rose, turn: ticket.assistant_turn)
    # The documented kill switch: she is not declared any more. The seat she
    # is holding is still a seat, and the check that finds it is the one that
    # used to return early here (R6).
    SupportDesk.reset!
    configure_support_desk!

    assert_not_predicate SupportDesk.doctor, :ok?
    assert_match(/held by an assistant who may not hold them/, check("assistant seats").message)
  end

  test "a harness that never picks anything up is a warning that names the task" do
    configure_assistant!(responds_within: 60)
    ticket_for(@alice)

    assert_predicate SupportDesk.doctor, :ok?

    travel 10.minutes
    warning = check("assistant idle turns (default)")

    assert_equal :warn, warning.status
    assert_match(/redispatch_assistant_turns/, warning.message)
  end

  test "two pending proposals on one case is a failure" do
    rose = configure_assistant!
    ticket = ticket_for(@alice)
    ticket.draft!("una", by: rose, turn: ticket.assistant_turn)
    # Bypassing the model, because the model is what the check is there to
    # back up on an adapter with no partial index.
    SupportDesk::Draft.new(ticket: ticket, author: rose, proposed_turn: "t1-r1", body: "otra",
                           status: "pending").save!(validate: false)

    assert_not_predicate SupportDesk.doctor, :ok?
    assert_match(/more than one pending proposal/, check("drafts").message)
  rescue ActiveRecord::RecordNotUnique
    # The database refused it, which is the better outcome and what every
    # adapter but MySQL does.
    assert partial_indexes?
  end

  test "a proposal left pending on a closed case is a warning" do
    rose = configure_assistant!
    ticket = ticket_for(@alice)
    draft = ticket.draft!("una", by: rose, turn: ticket.assistant_turn)
    ticket.close!(by: @lucia)
    draft.update_columns(status: "pending")

    assert_equal :warn, check("drafts").status
    assert_match(/pending proposal\(s\) on closed cases/, check("drafts").message)
  end
end
