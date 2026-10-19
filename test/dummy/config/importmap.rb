# frozen_string_literal: true

# What `rails new` + `rails turbo:install stimulus:install` give a host: Turbo,
# Stimulus, and the stock eager loader that registers every
# controllers/*_controller pin, chats' own (controllers/chats/*: the dock, the
# tray the launcher sits in, the thread) included.
pin "application", preload: true
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from File.expand_path("../app/javascript/controllers", __dir__), under: "controllers"
