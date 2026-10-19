# frozen_string_literal: true

require "application_system_test_case"

# The "Need help?" launcher in a real browser, both ways a host renders it
# (the dummy's `launcher` cookie): on its own in a corner, and in the
# messaging dock's tray. Its panel is this engine's own screens in a frame:
# the list, the wizard, a case's thread, all without leaving the page.
class LauncherSystemTest < ApplicationSystemTestCase
  setup do
    @alice = create_user(name: "Alice", onboarded: true)
    @lucia = create_agent(name: "Lucía")
  end

  test "on a desk, on its own: start a case and read it in the panel, never leaving the page" do
    at(1280)
    sign_in_with_launcher("standalone")

    open_launcher
    within(".chats-tray__item[open]") do
      assert_selector ".support-desk-door", text: "Start a new conversation"
      click_on "Start a new conversation"
      assert_selector ".support-desk-wizard__ask", text: "What do you need help with?"
      click_on "Something else"
      fill_in "message", with: "My refund never arrived"
      click_on "Send"

      assert_selector ".chats-thread--window .chats-message__text", text: "My refund never arrived"
      assert_selector ".support-desk-panel__nav .chats-window__name", text: "Something else"
    end
    assert_equal "/doors", URI(current_url).path, "the page never moved"

    ticket = @alice.support_tickets.last
    assert ticket.conversation.messages.exists?(body: "My refund never arrived")

    find(".support-desk-panel__nav a[aria-label='Back']").click
    assert_selector ".chats-tray__item[open] .chats-row__title", text: "Something else"
  end

  test "a reply lights the badge live, and reading it in the panel puts it out" do
    ticket = ticket_for(@alice, topic: :other, message: "Where is my refund?")
    at(1280)
    sign_in_with_launcher("standalone")
    assert_selector "#support_desk_launcher_badge", visible: :hidden

    perform_enqueued_jobs { reply_as @lucia, ticket, "It is on its way" }

    assert_selector "#support_desk_launcher_badge", text: "2" # the reply and "Lucía is taking care of your request"

    open_launcher
    find(".chats-tray__item[open] .chats-row__link", text: "Something else").click
    assert_selector ".chats-tray__item[open] .chats-message__text", text: "It is on its way"
    using_wait_time(5) { assert_equal 0, @alice.reload.unread_support_count }
    perform_enqueued_jobs
    assert_selector "#support_desk_launcher_badge", visible: :hidden
  end

  test "in the dock: the tab sits beside the Messages bar, and opening it folds the Messages panel" do
    at(1280)
    sign_in_with_launcher("dock")

    tab = rect(".chats-tray__item")
    bar = rect(".chats-dock__panel")
    assert_operator tab["right"], :<=, bar["left"], "beside the bar, never over it"
    assert_in_delta bar["bottom"], tab["bottom"], 1

    find(".chats-dock__panel > summary").click
    assert_selector ".chats-dock__panel[open]"
    open_launcher
    assert_no_selector ".chats-dock__panel[open]"
    assert_selector ".chats-tray__item[open] .support-desk-door"
  end

  test "on a phone: a round button, and the panel is a full-screen sheet" do
    at(390, height: 844, mobile: true) # a desktop window can't be narrower than ~500px
    sign_in_with_launcher("standalone")

    button = rect(".chats-tray__item")
    assert_in_delta 48, button["width"], 1

    open_launcher
    settle
    sheet = rect(".chats-tray__item")
    assert_equal [ 0, 0, 390, 844 ], [ sheet["left"], sheet["top"], sheet["width"], sheet["height"] ].map(&:round)
    assert_selector ".chats-tray__item[open] .support-desk-door"

    find(".chats-tray__close-glyph").click
    assert_no_selector ".chats-tray__item[open]"
  end

  test "signed out: the panel says how to reach us" do
    at(1280)
    visit "/doors"
    page.driver.browser.manage.add_cookie(name: "launcher", value: "standalone")
    visit "/doors"

    open_launcher
    within(".chats-tray__item[open]") do
      assert_text "Sign in and write to us"
      assert_link "Sign in to write to us", href: "/messages/support/"
      assert_link "Visit the help centre"
    end
  end

  private

  def at(width, height: 900, mobile: false)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: width, height: height, deviceScaleFactor: 1, mobile: mobile)
  end

  def sign_in_with_launcher(where)
    login_as @alice
    page.driver.browser.manage.add_cookie(name: "launcher", value: where)
    visit "/doors"
    page.execute_script("localStorage.clear()")
    assert_selector ".chats-tray[data-controller='chats--tray']"
    assert_selector "turbo-cable-stream-source[connected]", visible: :all, minimum: 1
  end

  def open_launcher
    find(".chats-tray__launcher").click
    assert_selector ".chats-tray__item[open]"
  end

  def rect(selector)
    page.evaluate_script(
      "JSON.parse(JSON.stringify(document.querySelector(#{selector.to_json}).getBoundingClientRect()))"
    )
  end

  # Until every finite animation (the sheet rising) has finished.
  def settle
    page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1]
      const finite = document.getAnimations().filter((a) => a.effect?.getTiming().iterations !== Infinity)
      Promise.all(finite.map((a) => a.finished.catch(() => {}))).then(() => done())
    JS
  end
end
