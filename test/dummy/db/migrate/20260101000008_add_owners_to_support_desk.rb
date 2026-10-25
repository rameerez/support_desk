# frozen_string_literal: true

# support_desk 0.6.0 — OWNERS.
#
# A polymorphic, nullable `owner` on desks and assistants, for an app that
# runs a support desk per customer (an account, a workspace, a product):
# every owner gets its own `:default` desk, and SupportDesk::Current.owner
# says whose is meant. Rows with no owner are the single-desk app every
# install was before, and nothing about them changes.
#
# A key is unique PER OWNER: `(owner_type, owner_id, key)`. The old unique
# index on `key` alone becomes a partial one over the rows with no owner,
# where partial indexes exist (PostgreSQL, SQLite). MySQL has none, so there
# an ownerless key is kept unique by the find-first lookup only.
#
# `owner_id` follows your generator's primary key type (uuid or bigint).
# If your owners are keyed differently, change `owner_id_type` before you
# migrate. Every statement is guarded.
#
# The migration itself is safe under 0.5: until a row has an owner, a key
# still names one row. TURNING OWNERS ON is not: 0.5 finds desks and
# assistants with `find_by(key:)`, so the first owned row can be picked by a
# 0.5 process. Migrate, deploy 0.6 to every process and retire every 0.5
# one, and only then set SupportDesk::Current.owner.
class AddOwnersToSupportDesk < ActiveRecord::Migration[7.2]
  TABLES = { support_desk_desks: "desks", support_desk_assistants: "assistants" }.freeze

  def up
    TABLES.each do |table, name|
      unless column_exists?(table, :owner_id)
        add_reference table, :owner, polymorphic: true, null: true, type: owner_id_type, index: false
      end

      owned = "index_support_desk_#{name}_on_owner_and_key"
      add_index table, %i[owner_type owner_id key], unique: true, name: owned unless index_name_exists?(table, owned)

      global = "index_support_desk_#{name}_on_key"
      remove_index table, name: global if index_name_exists?(table, global)

      ownerless = "index_support_desk_#{name}_on_key_without_owner"
      next unless partial_indexes?
      next if index_name_exists?(table, ownerless)

      add_index table, :key, unique: true, name: ownerless, where: "owner_type IS NULL AND owner_id IS NULL"
    end
  end

  # Exactly what `up` took away comes back. It fails — on purpose — once two
  # owners share a key: the old schema has no way to hold them.
  def down
    TABLES.each do |table, name|
      %W[index_support_desk_#{name}_on_owner_and_key index_support_desk_#{name}_on_key_without_owner].each do |index|
        remove_index table, name: index if index_name_exists?(table, index)
      end
      global = "index_support_desk_#{name}_on_key"
      add_index table, :key, unique: true, name: global unless index_name_exists?(table, global)
      remove_reference table, :owner, polymorphic: true if column_exists?(table, :owner_id)
    end
  end

  private

  def owner_id_type
    generators = Rails.configuration.generators
    generators.options[generators.orm][:primary_key_type] == :uuid ? :uuid : :bigint
  end

  # Whether this adapter can enforce a rule over SOME rows. Everything but
  # MySQL can — and Trilogy is MySQL under a different ADAPTER_NAME.
  def partial_indexes?
    !connection.adapter_name.match?(/mysql|trilogy/i)
  end
end
