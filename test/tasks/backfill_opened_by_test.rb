# frozen_string_literal: true

require "test_helper"
require "rake"

# `rake support_desk:backfill_opened_by` is the handover step: the migration
# backfills provenance once, and 0.1 processes still serving traffic keep
# writing NULL until they stop, so the same UPDATE runs again when they have.
class BackfillOpenedByTaskTest < ActiveSupport::TestCase
  setup do
    @alice = create_user(name: "Alice")
    Rake::Task.clear
    Rake::Task.define_task(:environment)
    load File.expand_path("../../lib/tasks/support_desk.rake", __dir__)
  end

  teardown { Rake::Task.clear }

  test "a case an old process left without provenance goes back to its requester" do
    ticket = ticket_for(@alice)
    ticket.update_columns(opened_by_type: nil, opened_by_id: nil)

    run_task
    ticket.reload

    assert_equal @alice.class.polymorphic_name, ticket.opened_by_type
    assert_equal @alice.id.to_s, ticket.opened_by_id.to_s
  end

  test "it never rewrites provenance somebody already recorded" do
    lucia = create_agent(name: "Lucía")
    written_first = open_support_ticket(for: @alice, by: lucia, message: "Vimos que…")
    legacy = ticket_for(create_user, topic: :account)
    legacy.update_columns(opened_by_type: nil, opened_by_id: nil)

    run_task

    assert_equal lucia, written_first.reload.opened_by
    assert_equal legacy.requester, legacy.reload.opened_by
  end

  test "running it twice is running it once" do
    ticket = ticket_for(@alice)
    ticket.update_columns(opened_by_type: nil, opened_by_id: nil)

    run_task
    first = ticket.reload.opened_by_id
    run_task

    assert_equal first.to_s, ticket.reload.opened_by_id.to_s
  end

  private

  def run_task
    task = Rake::Task["support_desk:backfill_opened_by"]
    task.reenable
    capture_io { task.invoke }
  end
end
