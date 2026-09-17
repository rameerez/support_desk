# frozen_string_literal: true

# A migrated COPY of add_opened_by_to_support_desk_tickets.rb.erb with the migration
# version pinned. Keep the two IN SYNC: a drift test in
# test/generators/upgrade_generator_test.rb compares everything below this line.

class AddOpenedByToSupportDeskTickets < ActiveRecord::Migration[7.2]
  INDEX_NAME = "index_support_desk_tickets_on_opened_by"

  def up
    ensure_columns_are_ours!

    add_reference :support_desk_tickets, :opened_by, polymorphic: true, null: true,
                                                     type: opened_by_id_type, index: false
    add_index :support_desk_tickets, [ :opened_by_type, :opened_by_id ], name: INDEX_NAME

    # SQL, and deliberately not the model: a backfill that loaded today's
    # Ticket would run this release's validations, callbacks and events over
    # last release's rows, in a migration that must only move two columns.
    execute(<<~SQL.squish)
      UPDATE support_desk_tickets
         SET opened_by_type = requester_type,
             opened_by_id = requester_id
       WHERE opened_by_id IS NULL
    SQL
  end

  # Exactly what `up` added, and nothing else. Note that this DESTROYS
  # provenance: every case the desk opened stops being distinguishable from
  # one the requester opened. It is here for a failed deploy of the schema
  # alone, never as the way back from a code rollback.
  def down
    remove_index :support_desk_tickets, name: INDEX_NAME if
      index_exists?(:support_desk_tickets, [ :opened_by_type, :opened_by_id ], name: INDEX_NAME)

    remove_column :support_desk_tickets, :opened_by_type if
      column_exists?(:support_desk_tickets, :opened_by_type)
    remove_column :support_desk_tickets, :opened_by_id if
      column_exists?(:support_desk_tickets, :opened_by_id)
  end

  private

  # A column we did not add is a schema we cannot reason about: its type may
  # not match, it may hold something else's data, and `down` would drop it.
  # Say so with the way out rather than skipping the backfill and the index
  # in silence.
  def ensure_columns_are_ours!
    existing = %i[opened_by_type opened_by_id].select { |name| column_exists?(:support_desk_tickets, name) }
    return if existing.empty?

    raise ActiveRecord::MigrationError,
          "support_desk_tickets already has #{existing.join(" and ")}. This migration owns those two columns " \
          "and #{INDEX_NAME}, so it won't write over a schema it didn't make. If you added them by hand and " \
          "they already hold every case's provenance, record this migration as run instead " \
          "(bin/rails db:migrate:up VERSION=, with this file's timestamp); otherwise drop them and run it again."
  end

  # The storage this table already uses for a host record's id — uuid,
  # bigint, integer. `opened_by_id` points at the same records as
  # `requester_id`, so it has to be stored the same way.
  def opened_by_id_type
    column = connection.columns(:support_desk_tickets).find { |candidate| candidate.name == "requester_id" }
    unless column
      raise ActiveRecord::MigrationError,
            "support_desk_tickets has no requester_id column — run support_desk's install migration first."
    end

    column.sql_type
  end
end
