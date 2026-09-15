# frozen_string_literal: true

# Something to ask about under a NESTED topic path, so the tree is exercised
# beyond one level.
class Invoice < ApplicationRecord
  supportable topic: "billing/invoice", candidates: ->(requester) { requester.invoices.order(number: :desc) }

  belongs_to :user

  def support_label = "Invoice #{number}"
end
