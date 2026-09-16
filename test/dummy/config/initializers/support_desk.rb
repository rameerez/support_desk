# frozen_string_literal: true

# Minimal host wiring, close to what the install generator suggests. Tests
# that need other settings use `with_support_config` (SupportDesk::TestHelpers)
# or reconfigure in setup — test_helper.rb resets between examples.
SupportDesk.configure do |config|
  config.requester_class = "User"
  config.name = "Soporte"
  config.agents { User.where(admin: true) }

  config.topics do
    topic :order, about: Order
    topic :billing do
      topic :invoice, about: Invoice
    end
    topic :account, only: ->(requester) { requester.onboarded? }
    other
  end
end
