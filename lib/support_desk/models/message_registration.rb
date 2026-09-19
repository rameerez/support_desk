# frozen_string_literal: true

module SupportDesk
  # Internal receipt written in the same transaction as the clocks and turn.
  # Message identity establishes idempotency; timestamp/UUID order does not.
  class MessageRegistration < ApplicationRecord
    self.table_name = "support_desk_message_registrations"
    self.primary_key = :message_id

    belongs_to :ticket, class_name: "SupportDesk::Ticket"
  end
end
