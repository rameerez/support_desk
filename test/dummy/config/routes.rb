# frozen_string_literal: true

Rails.application.routes.draw do
  # Mount both engines the way a real host does — support BEFORE chats, so
  # "/messages/support" is the desk and "/messages" is the inbox.
  mount SupportDesk::Engine => "/messages/support"
  mount Chats::Engine => "/messages"

  # The turnkey console (Layer 4), for hosts with no admin framework.
  mount SupportDesk::ConsoleEngine => "/admin/support"

  # The SAME console through Layer 2, in a host's own namespace — the
  # `:support_console` routing concern plus a host-owned controller and
  # host-owned views. Both are exercised by the suite, because "the gem's
  # console uses only the public API" is a claim that needs a second
  # implementation to be worth anything.
  namespace :madmin do
    resources :support_tickets, only: %i[index show new], concerns: :support_console
  end

  # Test-only session endpoint so integration tests can act as a user
  # without dragging a real auth framework into the dummy.
  post "/test_login", to: "sessions#create", as: :test_login
  get "/test_login/:user_id", to: "sessions#create"

  # A host page that renders the requester-facing view helpers, so they are
  # exercised where hosts really call them.
  get "/doors(/:order_id)", to: "doors#show", as: :door

  root to: "sessions#home"
end
