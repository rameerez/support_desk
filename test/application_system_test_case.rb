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

# Chrome reports a node that vanished mid-check — the browser swapping in a
# 422 re-render while Capybara was still inspecting a node from the page it
# replaced — as an UnknownError ("Node with given id does not belong to the
# document"), not as the StaleElementReferenceError Capybara already retries.
# Seen on CI only, on 1–2 of 16 legs, always at the moment a full page load
# lands. Retrying it inside Capybara's own wait is the same treatment stale
# nodes get; a real problem still surfaces when the wait runs out.
module RetryDetachedNodes
  def invalid_element_errors
    @invalid_element_errors ||= super + [ ::Selenium::WebDriver::Error::UnknownError ]
  end
end
Capybara::Selenium::Driver.prepend(RetryDetachedNodes)
