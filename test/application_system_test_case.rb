# frozen_string_literal: true

require "test_helper"

# A real browser, because a Turbo Frame is only a frame in one. The wizard's
# whole promise — three steps that re-render in place AND stay real URLs — is
# invisible to an integration test, which sees three perfectly ordinary
# responses.
#
# Phone-sized on purpose: these screens are mobile-first, and a 1400px window
# would hide a layout that only breaks on the device people actually use.
class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 390, 844 ]

  # Act as +user+ for the rest of the example. Capybara can't POST, so the
  # dummy exposes the same session endpoint over GET.
  def login_as(user)
    visit "/test_login/#{user.id}"
    assert_text "ok"
  end
end
