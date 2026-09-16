# frozen_string_literal: true

# Something to ask about, with every `supportable` default left alone —
# which is how we know the defaults work.
class Order < ApplicationRecord
  supportable topic: :order

  # Also a chats subject, and one that LOCKS — so the suite has a locked
  # conversation that is not a support case, which is the branch the engine's
  # `locked_composer` slot must leave to chats.
  acts_as_chat_subject

  def chat_locked? = state == "closed"
  def chat_locked_notice = "This order is closed."

  belongs_to :user

  def support_label = "Order #{number}"
  def support_status = state
  def support_context = { "Total" => total, "Estado" => state }
end
