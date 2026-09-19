# frozen_string_literal: true

# Stop support writes and drain old web/jobs before migrating. Old processes
# cannot write receipts. Existing messages at/before the legacy clocks form
# the historical baseline; messages ahead of those clocks remain repairable.
# A pre-upgrade lost callback behind a clock cannot be inferred from old data:
# review historical suspect cases before resuming writes (see README).
class CreateSupportDeskMessageRegistrations < ActiveRecord::Migration[7.2]
  def up
    return if table_exists?(:support_desk_message_registrations)

    create_table :support_desk_message_registrations, id: false do |t|
      t.column :message_id, column_type(:chats_messages, "id"), null: false
      t.column :ticket_id, column_type(:support_desk_tickets, "id"), null: false
    end
    add_index :support_desk_message_registrations, :message_id, unique: true, name: "index_sd_registrations_message"
    add_index :support_desk_message_registrations, :ticket_id, name: "index_sd_registrations_ticket"
    add_foreign_key :support_desk_message_registrations, :support_desk_tickets, column: :ticket_id, on_delete: :cascade
    add_foreign_key :support_desk_message_registrations, :chats_messages, column: :message_id, on_delete: :cascade

    execute <<~SQL
      INSERT INTO support_desk_message_registrations (message_id, ticket_id)
      SELECT m.id, t.id FROM chats_messages m
      JOIN support_desk_tickets t ON t.conversation_id = m.conversation_id
      WHERE m.kind = 'text' AND (
        (m.sender_type = t.requester_type AND m.sender_id = t.requester_id
          AND m.created_at <= t.last_requester_message_at)
        OR (m.sender_type = 'SupportDesk::Desk' AND m.sender_id = t.desk_id
          AND m.created_at <= t.last_agent_message_at))
    SQL
  end

  def down
    drop_table :support_desk_message_registrations, if_exists: true
  end

  private

  def column_type(table, name)
    connection.columns(table).find { |column| column.name == name }.sql_type
  end
end
