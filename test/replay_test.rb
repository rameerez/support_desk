# frozen_string_literal: true

require "test_helper"

# The two signals that used to live only in memory now leave a row, written
# in the transaction that produced them. Every adapter.
class ReplaySignalsTest < ActiveSupport::TestCase
  setup do
    @alice = create_user(name: "Alice")
    @lucia = create_agent(name: "Lucía")
    @rose = configure_assistant!(autonomy: :draft)
    @ticket = ticket_for(@alice, message: "Hola")
  end

  test "a turn owed to the assistant is written down, with the turn it is for" do
    turn = @ticket.events.of_kind(:assistant_turn).sole

    assert_equal @ticket.assistant_turn, turn.payload["turn"]
    assert_equal "rose", turn.payload["assistant"]
    assert_equal @ticket.last_requester_message_id.to_s, turn.payload["message"]
  end

  test "a proposal is written down, and the turn it left the case at" do
    draft = @ticket.draft!("propuesta", by: @rose, turn: @ticket.assistant_turn)
    event = @ticket.events.of_kind(:draft_proposed).sole

    assert_equal draft.id.to_s, event.payload["draft"]
    assert_equal draft.proposed_turn, event.payload["turn"]
    assert_equal @rose, event.actor
  end

  test "handing the case back writes the turn under the same lock" do
    @ticket.request_human!(by: @alice)
    @ticket.assign!(to: @lucia, by: @lucia)

    with_assistant_config(autonomy: :reply) do
      assert_difference -> { @ticket.events.of_kind(:assistant_turn).count } do
        @ticket.assign!(to: @rose, by: @lucia)
      end
    end
  end

  test "the re-emission sweep repeats a turn without writing another one" do
    travel 2.minutes

    assert_no_difference -> { SupportDesk::Event.of_kind(:assistant_turn).count } do
      assert_equal 1, SupportDesk.redispatch_assistant_turns!(older_than: 60)
    end
  end

  test "signals are not history: no timeline entry, nothing in the requester's export" do
    @ticket.draft!("propuesta", by: @rose, turn: @ticket.assistant_turn)

    assert_empty @ticket.timeline.entries.select { |entry| entry.kind.in?(%i[assistant_turn draft_proposed]) }
    assert_empty @ticket.export[:events].select { |event| event[:kind].in?(%w[assistant_turn draft_proposed]) }
  end

  unless ActiveRecord::Base.connection.adapter_name.match?(/\Apostg/i)
    test "replay says plainly that it needs PostgreSQL" do
      error = assert_raises(SupportDesk::ConfigurationError) { SupportDesk::Events.replay(horizon: 0) { nil } }
      assert_match(/PostgreSQL 13/, error.message)
    end
  end
end

# The replay contract, on real PostgreSQL with real concurrent transactions.
# Nothing here can run inside the suite's test transaction: a reader holding
# a transaction id holds the horizon back, which is the whole point.
if ActiveRecord::Base.connection.adapter_name.match?(/\Apostg/i)
  class ReplayTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    setup do
      @alice = create_user(name: "Alice")
      @ticket = ticket_for(@alice, message: "Hola")
    end

    teardown do
      tables = ActiveRecord::Base.connection.tables - %w[schema_migrations ar_internal_metadata]
      ActiveRecord::Base.connection.execute("TRUNCATE #{tables.map { |t| %("#{t}") }.join(", ")} CASCADE")
    end

    def replay(horizon, **options)
      rows = []
      next_horizon = SupportDesk::Events.replay(horizon: horizon, **options) { |row| rows << row }
      [ rows, next_horizon ]
    end

    # The horizon is the SERVER's, not this database's: a transaction open
    # anywhere on it — another suite, a console, another app on the same
    # PostgreSQL — holds it back, exactly as the contract says it must. So a
    # test that needs its own rows below the horizon polls, as a real reader
    # does, until the horizon has passed +xid+ (and fails, saying so, if it
    # never does).
    def replay_past(xid, horizon = 0, **options)
      rows = []
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
      loop do
        horizon = SupportDesk::Events.replay(horizon: horizon, **options) { |row| rows << row }
        return [ rows, horizon ] if horizon > xid

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          pinning = ActiveRecord::Base.connection.select_rows(<<~SQL)
            SELECT pid, datname, application_name, backend_xid::text, state, left(query, 80)
              FROM pg_stat_activity WHERE backend_xid IS NOT NULL
          SQL
          flunk "the horizon stayed at #{horizon}, below #{xid}, for 20s. Holding it: #{pinning.inspect}"
        end
        sleep 0.05
      end
    end

    def newest_xid
      [ SupportDesk::Event.maximum(:xact_id), SupportDesk::MessageRegistration.maximum(:xact_id) ].compact.max
    end

    test "every committed row of both tables, oldest first, then the horizon after them" do
      rows, horizon = replay_past(newest_xid)

      assert_includes rows.map(&:class), SupportDesk::Event
      assert_includes rows.map(&:class), SupportDesk::MessageRegistration
      assert_equal rows.sort_by { |row| [ row.xact_id, row.position ] }, rows
      assert_equal rows.size, rows.map(&:position).uniq.size, "one sequence: a position names one row"
      assert_operator horizon, :>, rows.map(&:xact_id).max
      assert_empty replay(horizon).first, "a drained range is not read again"
    end

    test "the rows of one transaction come out together, in the order they were written" do
      _rows, horizon = replay_past(newest_xid)
      SupportDesk::Event.transaction do
        3.times { |n| SupportDesk::Event.record!(ticket: @ticket, kind: :note, actor: :system, payload: { "n" => n }) }
      end

      rows, = replay_past(newest_xid, horizon)

      assert_equal [ 0, 1, 2 ], rows.map { |row| row.payload["n"] }
      assert_equal 1, rows.map(&:xact_id).uniq.size
    end

    # B takes a transaction id; A takes a LATER one and inserts first, so A's
    # row has the LOWER position; B inserts and commits; the reader polls; A
    # commits. A reader that checkpointed "the last position I saw" would
    # stand on B's position and never read A's row. The horizon reader
    # stopped below A's transaction, so the next poll finds it.
    test "a row committed late behind a higher position is read on the next poll" do
      _rows, horizon = replay_past(newest_xid)
      a, b = 2.times.map { separate_connection }

      b.execute("BEGIN")
      b_xid = b.select_value("SELECT pg_current_xact_id()::text::bigint").to_i
      a.execute("BEGIN")
      a_xid = a.select_value("SELECT pg_current_xact_id()::text::bigint").to_i
      a_position = insert_note(a).to_i
      b_position = insert_note(b).to_i
      b.execute("COMMIT")

      assert_operator b_xid, :<, a_xid
      assert_operator a_position, :<, b_position

      # Polled while A is still open: the horizon gets past B, never past A.
      first, horizon = replay_past(b_xid, horizon)
      assert_equal [ b_position ], first.map(&:position)
      assert_operator horizon, :<=, a_xid

      a.execute("COMMIT")
      second, = replay_past(a_xid, horizon)

      assert_equal [ a_position ], second.map(&:position),
                   "a position checkpoint at #{b_position} would have skipped #{a_position} for ever"
    ensure
      [ a, b ].compact.each(&:disconnect!)
    end

    test "a range that raised is resumed after the last row handled, with the end it started with" do
      2.times { ticket_for(create_user, message: "otro") }
      everything, = replay_past(newest_xid)
      handled = []
      resume = nil

      # Every transaction that wrote a row above has finished, so this
      # range's end is past all of them, whatever else the server is doing.
      assert_raises(RuntimeError) do
        SupportDesk::Events.replay(horizon: 0, batch_size: 2) do |row, cursor|
          raise "the process died" if handled.size == 3

          handled << row.position
          resume = cursor
        end
      end

      ticket_for(create_user, message: "after the crash")
      rest = []
      horizon = SupportDesk::Events.replay(horizon: 0, resume: resume.as_json, batch_size: 2) { |row| rest << row.position }

      assert_equal everything.map(&:position), handled + rest
      assert_equal resume["until"], horizon
    end

    # Every request and job runs with ActiveRecord's query cache on, and so
    # does every test. The snapshot is the same SQL on every poll: cached,
    # the horizon would never move again and a row another process commits
    # would never be read.
    test "a reader under the query cache still sees the horizon move" do
      assert ActiveRecord::Base.connection.query_cache_enabled, "the scenario needs the cache on"
      _rows, horizon = replay_past(newest_xid)
      replay(horizon) # the snapshot is now in the cache
      writer = separate_connection
      # Another thread, as another process would be: a write on THIS thread
      # clears its query caches and would hide the bug.
      positions, xid = Thread.new do
        written = 2.times.map do
          writer.execute("BEGIN")
          writer.select_value("SELECT pg_current_xact_id()")
          position = insert_note(writer).to_i
          writer.execute("COMMIT")
          position
        end
        [ written, writer.select_value("SELECT max(xact_id) FROM support_desk_events").to_i ]
      end.value

      rows, = replay_past(xid, horizon)

      assert_equal positions, rows.map(&:position)
    ensure
      writer&.disconnect!
    end

    test "the horizon never moves past a transaction that is still open" do
      _rows, horizon = replay_past(newest_xid)
      writer = separate_connection
      writer.execute("BEGIN")
      pinned = writer.select_value("SELECT pg_current_xact_id()::text::bigint").to_i
      ticket_for(create_user, message: "behind the pin")

      rows, stuck = replay(horizon)

      assert_operator stuck, :<=, pinned
      assert_empty rows, "the newer committed rows wait until the pin is gone"
    ensure
      writer&.disconnect!
    end

    private

    # A session of its own, outside the pool: the schedule needs three
    # sessions at once, and what it leaves open dies with the disconnect.
    def separate_connection
      ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.new(ActiveRecord::Base.connection_db_config.configuration_hash)
    end

    # A raw INSERT on a connection of its own: the transaction is the test's
    # to open and commit, not ActiveRecord's.
    def insert_note(connection)
      connection.select_value(<<~SQL)
        INSERT INTO support_desk_events (ticket_id, kind, payload, created_at)
        VALUES (#{connection.quote(@ticket.id)}, 'note', '{}', now()) RETURNING position
      SQL
    end
  end
end
