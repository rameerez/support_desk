# frozen_string_literal: true

# Something to ask about, with every `supportable` default left alone —
# which is how we know the defaults work.
class Order < ApplicationRecord
  supportable topic: :order

  belongs_to :user

  def support_label = "Order #{number}"
  def support_status = state
  def support_context = { "Total" => total, "Estado" => state }
end
