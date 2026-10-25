# frozen_string_literal: true

# support_desk 0.6.0 — DURABLE REPLAY (PostgreSQL 13+; a no-op elsewhere).
#
# Two columns on the two tables that are the desk's durable record,
# `support_desk_events` and `support_desk_message_registrations`:
#
# - `xact_id`: the transaction that wrote the row, `pg_current_xact_id()`.
#   Stored as bigint — an xid8 IS a 64-bit integer — because Rails cannot
#   dump an xid8 column: schema.rb would silently lose the whole table.
# - `position`: from ONE sequence for both tables, so `(xact_id, position)`
#   orders every row of both, and `position` alone identifies one.
#
# SupportDesk::Events.replay reads them. Adding a column with a sequence
# default rewrites the table under an exclusive lock: on a large events
# table, run it in a quiet window. Rows that already exist get the
# migration's own transaction id, so a reader starting from zero reads them
# all. Every statement is guarded, so it is safe to run twice.
class AddReplayToSupportDesk < ActiveRecord::Migration[7.2]
  SEQUENCE = "support_desk_events_position_seq"
  XACT_ID = "(pg_current_xact_id()::text::bigint)"
  TABLES = {
    support_desk_events: "index_support_desk_events_on_replay",
    support_desk_message_registrations: "index_sd_registrations_on_replay"
  }.freeze

  def up
    return unless postgresql?

    if connection.database_version < 130_000
      raise ActiveRecord::MigrationError,
            "support_desk's durable replay needs PostgreSQL 13 or later (pg_current_xact_id)."
    end

    # The events column OWNS the sequence (bigserial); the registrations
    # column draws from it — the same order, for both tables.
    unless column_exists?(:support_desk_events, :position)
      execute "ALTER TABLE support_desk_events ADD COLUMN position bigserial NOT NULL"
    end
    unless column_exists?(:support_desk_message_registrations, :position)
      execute "ALTER TABLE support_desk_message_registrations " \
              "ADD COLUMN position bigint NOT NULL DEFAULT nextval('#{SEQUENCE}'::regclass)"
    end

    TABLES.each do |table, index|
      unless column_exists?(table, :xact_id)
        execute "ALTER TABLE #{table} ADD COLUMN xact_id bigint NOT NULL DEFAULT #{XACT_ID}"
      end
      add_index table, [ :xact_id, :position ], name: index unless index_exists?(table, [ :xact_id, :position ], name: index)
    end
  end

  # Exactly what `up` added. The registrations column goes first: its
  # default draws from the sequence the events column owns.
  def down
    return unless postgresql?

    TABLES.each do |table, index|
      remove_index table, name: index if index_exists?(table, [ :xact_id, :position ], name: index)
    end
    %i[support_desk_message_registrations support_desk_events].each do |table|
      remove_column table, :xact_id if column_exists?(table, :xact_id)
      remove_column table, :position if column_exists?(table, :position)
    end
  end

  private

  # Matched by prefix, because PostGIS answers "PostGIS".
  def postgresql?
    connection.adapter_name.match?(/\Apostg/i)
  end
end
