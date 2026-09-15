# frozen_string_literal: true

# The dummy host's person: asks for help, and (when admin) answers it.
class User < ApplicationRecord
  acts_as_messager
  has_support_tickets
  acts_as_support_agent if: :admin?

  has_many :orders, dependent: :destroy
  has_many :invoices, dependent: :destroy

  def display_name = name
end
