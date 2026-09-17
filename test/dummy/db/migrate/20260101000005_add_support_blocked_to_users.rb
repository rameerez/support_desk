# frozen_string_literal: true

# The dummy host's own eligibility flag. `has_support_tickets if:` needs
# something PERSISTED to read: the gem re-reads the requester from the
# database rather than trusting the instance in hand, so a plain attribute
# would answer for a test and never for a closed account.
class AddSupportBlockedToUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :support_blocked, :boolean, null: false, default: false
  end
end
