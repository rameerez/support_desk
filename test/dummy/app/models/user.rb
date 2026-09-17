# frozen_string_literal: true

# The dummy host's person: asks for help, and (when admin) answers it.
class User < ApplicationRecord
  acts_as_messager
  has_support_tickets if: :support_contactable?
  acts_as_support_agent if: :admin?

  has_many :orders, dependent: :destroy
  has_many :invoices, dependent: :destroy

  def display_name = name

  # Who may ask for help and be written to. The gem has no opinion about it;
  # this is the dummy's version of the host predicate decision 16 recommends
  # (CarHey spells it `kept? && !banned?`).
  def support_contactable? = !support_blocked?
end
