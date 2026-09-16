# frozen_string_literal: true

require "test_helper"

class QueueTest < ActiveSupport::TestCase
  setup do
    @lucia = create_agent(name: "Lucía")
    @pedro = create_agent(name: "Pedro")
    @queue = SupportDesk::Queue.for(@lucia)

    @mine = ticket_for(create_user)
    @mine.assign!(to: @lucia, by: @lucia)
    @theirs = ticket_for(create_user)
    @theirs.assign!(to: @pedro, by: @pedro)
    @unclaimed = ticket_for(create_user)
    @done = ticket_for(create_user)
    @done.close!(by: @lucia)
  end

  test "each tab is a relation" do
    assert_equal [ @mine ], @queue.mine.to_a
    assert_equal [ @unclaimed ], @queue.unassigned.to_a
    # "Needs a reply" is about the transcript, not about ownership: taking a
    # ticket doesn't answer the person who is waiting.
    assert_equal [ @mine, @theirs, @unclaimed ].map(&:id).sort, @queue.awaiting.map(&:id).sort
    assert_equal [ @done ], @queue.closed.to_a
    assert_empty @queue.snoozed
    assert_equal 3, @queue.open.count
    assert_equal 4, @queue.all.count
  end

  test "awaiting is the work: open and waiting on the desk" do
    @mine.reply!("vamos", by: @lucia)

    assert_not_includes @queue.awaiting, @mine.reload
  end

  test "counts answers every tab in one query" do
    counts = nil
    queries = count_queries { counts = @queue.counts }

    assert_equal 1, queries
    assert_equal({ awaiting: 3, mine: 1, unassigned: 1, open: 3, snoozed: 0, closed: 1 }, counts)
  end

  test "counts and the relations agree" do
    counts = @queue.counts

    SupportDesk::Queue::TABS.each do |tab|
      assert_equal @queue.public_send(tab).count, counts[tab], "#{tab} disagrees"
    end
  end

  test "badge is what this agent should feel responsible for" do
    # Lucía: her own one plus the unclaimed one. Pedro: the same unclaimed
    # one plus his own — an unheld ticket is everybody's problem.
    assert_equal 2, @queue.badge
    assert_equal 2, SupportDesk::Queue.for(@pedro).badge
  end

  test "badge is cached briefly, and the cache is per agent" do
    Rails.cache.clear
    assert_equal 2, @queue.badge

    ticket_for(create_user)

    assert_equal 2, @queue.badge, "the badge should still be the cached value"

    Rails.cache.clear

    assert_equal 3, @queue.badge
  end

  test "next is the most urgent thing this agent could pick up" do
    @unclaimed.update!(priority: 2)

    assert_equal @unclaimed, @queue.next

    @unclaimed.assign!(to: @pedro, by: @pedro)

    assert_equal @mine, @queue.next
  end

  test "next is the most urgent, not the newest" do
    # The urgent one is also the OLDEST, so an ordering that starts with
    # "newest first" would quietly hand out the wrong ticket — and a test
    # whose urgent ticket happened to be newest would never notice.
    urgent = @unclaimed
    urgent.update!(priority: 2, opened_at: 3.days.ago)
    newest = ticket_for(create_user)
    newest.update!(priority: 0, opened_at: 1.minute.ago)

    assert_equal urgent, @queue.next
    assert_equal urgent, @queue.unassigned.first
    assert_equal urgent, @queue.awaiting.first
    assert_equal urgent, @queue.open.first
  end

  test "each tab states its own order, so the base scope can't overrule it" do
    # Opened first, touched last: the two orders disagree on purpose, so a
    # tab whose own order was a dead tiebreaker answers wrongly.
    long_running = @done
    long_running.update_columns(opened_at: 3.days.ago, updated_at: Time.current)
    recently_opened = ticket_for(create_user)
    recently_opened.close!(by: @lucia)
    recently_opened.update_columns(opened_at: 1.minute.ago, updated_at: 2.days.ago)

    assert_equal long_running, @queue.closed.first, "closed is most recently touched first"

    listed = @queue.all.to_a

    assert_operator listed.index(recently_opened), :<, listed.index(long_running), "all is newest first"
  end

  test "next never offers somebody else's ticket" do
    assert_not_equal @theirs, @queue.next
  end

  test "tabs come with i18n labels, in display order" do
    tabs = @queue.tabs

    assert_equal SupportDesk::Queue::VISIBLE_TABS, tabs.map(&:first)
    assert_equal "Needs a reply", tabs.first[1]
    assert_equal 3, tabs.first[2]
  end

  test "a tab whose feature hasn't shipped isn't offered, but still answers" do
    # Snoozing is 0.2. Until then the tab would be a permanent zero, so
    # nothing renders it — while `scope` and `counts` still cover it, so a
    # host that gets snoozed rows from elsewhere isn't locked out.
    assert_not_includes @queue.tabs.map(&:first), :snoozed
    assert_includes SupportDesk::Queue::TABS, :snoozed
    assert_includes @queue.counts.keys, :snoozed
    assert_equal @queue.snoozed.to_a, @queue.scope(:snoozed).to_a
  end

  test "scope routes a params[:tab] without a case statement" do
    assert_equal @queue.mine.to_a, @queue.scope(:mine).to_a
    assert_equal @queue.awaiting.to_a, @queue.scope(nil).to_a
    assert_raises(ArgumentError) { @queue.scope(:nope) }
  end

  test "a queue is scoped to its desk" do
    SupportDesk.config.desk(:billing)
    billing = SupportDesk::Queue.for(@lucia, desk: SupportDesk.desk(:billing))

    assert_equal 0, billing.counts[:open]
    assert_equal 3, @queue.counts[:open]
  end

  test "agent.support_queue is the same queue" do
    assert_equal @queue.mine.to_a, @lucia.support_queue.mine.to_a
  end

  private

  def count_queries
    count = 0
    counter = ->(_name, _start, _finish, _id, payload) { count += 1 unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end
end
