# frozen_string_literal: true

require "test_helper"
require "rake"

# §12.11 — the three maintenance tasks. Two of them are the nets under a
# dead harness and have to be scheduled; the third is the read-only "what is
# she doing right now".
class AssistantTasksTest < ActiveSupport::TestCase
  setup do
    @alice = create_user(name: "Alice")
    @lucia = create_agent(name: "Lucía")
    @rose = configure_assistant!(autonomy: :reply, responds_within: 60)
    Rake::Task.clear
    Rake::Task.define_task(:environment)
    load File.expand_path("../../lib/tasks/support_desk.rake", __dir__)
  end

  teardown { Rake::Task.clear }

  def run_task(name)
    capture_io { Rake::Task["support_desk:#{name}"].invoke }.first
  end

  test "release_silent_assistants hands over the cases she sat on, and says how many" do
    ticket = ticket_for(@alice)
    ticket.assign!(to: @rose, by: @rose)
    travel 2.minutes

    output = run_task("release_silent_assistants")

    assert_match(/1 case\(s\) handed to a person/, output)
    assert_needs_human ticket, reason: "assistant_silent"
    assert_unassigned ticket
  end

  test "release_silent_assistants is quiet when there is nothing to do" do
    ticket_for(@alice)

    assert_match(/0 case\(s\)/, run_task("release_silent_assistants"))
  end

  test "redispatch_assistant_turns re-emits what nobody picked up" do
    ticket = ticket_for(@alice)
    turns = []
    SupportDesk.on(:assistant_turn) { |_ticket, _assistant, _message, turn:| turns << turn }
    travel 2.minutes

    output = run_task("redispatch_assistant_turns")

    assert_match(/1 turn\(s\) re-emitted/, output)
    assert_equal [ ticket.reload.assistant_turn ], turns
  end

  test "redispatch_assistant_turns takes its window from the environment" do
    ticket_for(@alice)
    travel 30.seconds
    ENV["OLDER_THAN"] = "600"

    assert_match(/0 turn\(s\)/, run_task("redispatch_assistant_turns"))
  ensure
    ENV.delete("OLDER_THAN")
  end

  test "assistant_status reads the numbers and writes nothing" do
    ticket = ticket_for(@alice)
    ticket.assign!(to: @rose, by: @rose)
    other = ticket_for(@alice, topic: :order, message: "Otra")
    other.escalate!(by: @lucia, reason: "para una persona")
    with_assistant_config(autonomy: :draft) do
      ticket_for(@alice, topic: :account, message: "Y otra").tap do |third|
        third.draft!("propuesta", by: @rose, turn: third.assistant_turn)
      end
    end

    output = run_task("assistant_status")

    assert_match(/rose \(active, reply\): 1 case\(s\) held/, output)
    assert_match(/1 case\(s\) need a person/, output)
    assert_match(/1 proposal\(s\) waiting/, output)
    assert_equal 3, SupportDesk::Ticket.count, "it changed nothing"
  end

  test "assistant_status says so when nobody configured an assistant" do
    SupportDesk.reset!
    configure_support_desk!

    assert_match(/no assistant is configured/, run_task("assistant_status"))
  end
end
