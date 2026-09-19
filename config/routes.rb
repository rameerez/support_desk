# frozen_string_literal: true

# The requester-facing engine:
#
#   mount SupportDesk::Engine => "/support"
#
# Everything a person who needs help touches lives here — the wizard, their
# list of cases, and the doors into them. The agent console is BYOUI: query
# objects and presenters (Layer 1), a controller concern and a routing
# concern (Layer 2), or the generated console (Layer 3). See the README.
SupportDesk::Engine.routes.draw do
  # The wizard is ONE url with three frames, so it gets the short spelling:
  # /support/new, not /support/tickets/new. Every step is a real URL
  # (`/support/new?topic=payments/withdrawal`), which is what makes the back
  # gesture, a bookmark and a cold-boot deep link all work.
  get "new", to: "tickets#new", as: :new_ticket

  # `show` redirects into the chats conversation — a stable URL for a case,
  # for emails and notifications, that never has to know where chats is
  # mounted.
  resources :tickets, only: %i[create show] do
    # The door out of a machine. It is a POST on the CASE rather than
    # anything to do with chats, because it is a fact about the case: from
    # here on a person is expected, whatever the assistant would have done
    # next.
    post :request_human, on: :member
  end

  root to: "tickets#index"
end
