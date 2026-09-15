# frozen_string_literal: true

Rails.application.routes.draw do
  # Mount both engines the way a real host does — support BEFORE chats, so
  # "/messages/support" is the desk and "/messages" is the inbox.
  mount SupportDesk::Engine => "/messages/support"
  mount Chats::Engine => "/messages"

  # Test-only session endpoint so integration tests can act as a user
  # without dragging a real auth framework into the dummy.
  post "/test_login", to: "sessions#create", as: :test_login

  root to: "sessions#home"
end
