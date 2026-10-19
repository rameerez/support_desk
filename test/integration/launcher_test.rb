# frozen_string_literal: true

require "test_helper"

# The "Need help?" launcher (`support_launcher`, 0.5.0): an item of chats'
# tray, in the messaging dock or in a corner of its own, whose panel is this
# engine's own screens answered to the panel's frame.
#
# The dummy's layout renders it from the `launcher` cookie ("dock" or
# "standalone"); /doors is a host page. The engine is mounted at
# /messages/support, chats at /messages.
class LauncherTest < ActionDispatch::IntegrationTest
  PANEL = { "Turbo-Frame" => SupportDesk::Launcher::FRAME }.freeze

  setup do
    @alice = create_user(name: "Alice", onboarded: true)
    @lucia = create_agent(name: "Lucía")
  end

  # --- on a host page ----------------------------------------------------------

  test "no call, no launcher: a host that never renders it has none" do
    login_as @alice
    get "/doors"

    assert_response :success
    assert_empty css_select("#chats_tray_support")
  end

  test "on its own: a corner of chats' tray, the tab, the live badge and a lazy panel onto the list" do
    ticket = ticket_for(@alice, topic: :other, message: "Where is my refund?")
    reply_as @lucia, ticket, "On its way"
    login_as @alice
    cookies[:launcher] = "standalone"

    get "/doors"

    assert_response :success
    assert_no_missing_translations
    assert_select ".chats-dock.chats-dock--tray-only > .chats-tray > details#chats_tray_support.chats-tray__item" do |items|
      item = items.first
      assert_equal "/messages/support/tickets/badge", item["data-chats-tray-badge-url"]
      assert_select "summary.chats-tray__launcher" do
        assert_select ".chats-tray__icon svg"
        assert_select ".chats-tray__label", text: "Need help?"
        assert_select ".chats-tray__title", text: /Soporte/
        assert_select "turbo-cable-stream-source", 1 # [alice, :support_desk]
        # The reply and the desk's "Lucía is taking care of your request": both unread.
        assert_select "##{SupportDesk::Launcher::BADGE_ID}.chats-tray__badge[data-count='2']:not([hidden])"
      end
      assert_select ".chats-tray__body turbo-frame##{SupportDesk::Launcher::FRAME}" \
                    "[src='/messages/support/'][loading='lazy'][refresh='morph']" \
                    "[data-chats-tray-home='/messages/support/']" do
        assert_select "a[href='/messages/support/'][data-turbo-frame='_top']", text: "Open support"
      end
    end
    assert_select "link[rel='stylesheet'][href*='support_desk']"
  end

  test "in the dock: the same item, in the dock's tray beside its bar" do
    login_as @alice
    cookies[:launcher] = "dock"

    get "/doors"

    assert_select "aside.chats-dock[data-controller='chats--dock'] > .chats-tray > details#chats_tray_support"
    assert_empty css_select(".chats-dock--tray-only"), "never a second corner"
  end

  test "signed out, with show_for: :everyone: how to reach the desk, no frame and no stream" do
    cookies[:launcher] = "dock"

    with_support_config(email: "help@pepperbox.test", reply_within: 24.hours) do
      get "/doors"
    end

    assert_response :success
    assert_no_missing_translations
    assert_select ".chats-dock--tray-only #chats_tray_support" do
      assert_empty css_select("#chats_tray_support turbo-cable-stream-source")
      assert_empty css_select("#chats_tray_support turbo-frame")
      assert_nil css_select("#chats_tray_support").first["data-chats-tray-badge-url"]
      assert_select ".support-desk-panel__lead", text: /Sign in/
      assert_select ".support-desk-panel__promise", text: /24 hours/
      assert_select "a.support-desk-button[href='/messages/support/'][data-turbo-frame='_top']",
                    text: "Sign in to write to us"
      assert_select ".support-desk-panel__note a[href='mailto:help@pepperbox.test']"
      assert_select "a[href='https://help.example.com']", text: "Visit the help centre"
    end
  end

  test "support_launcher: nothing for a visitor who is signed out unless asked, and only two audiences" do
    view = ApplicationController.new.view_context
    def view.current_user = nil

    assert_nil view.support_launcher
    assert_raises(ArgumentError) { view.support_launcher(show_for: :admins) }
  end

  # --- the panel: the engine's screens, answered to its frame -------------------

  test "the panel's first screen: the door with the promise, open cases opening in the panel, the way to the page" do
    open_case = ticket_for(@alice, topic: :other, message: "Still open")
    closed = ticket_for(@alice, topic: :account, message: "Old")
    closed.close!(by: @lucia)
    login_as @alice

    with_support_config(reply_within: 72.hours) { get "/messages/support", headers: PANEL }

    assert_response :success
    assert_no_missing_translations
    assert_empty css_select(".pb-bar"), "the panel's frame and nothing else of the layout"
    assert_select "turbo-frame##{SupportDesk::Launcher::FRAME} .support-desk-panel__screen[data-chats-tray-refresh]" do
      assert_select "a.support-desk-door[href='/messages/support/new']" do
        assert_select ".support-desk-door__hint", text: /72 hours/
      end
      assert_select "ul.chats-dock__list a.chats-row__link[href=?]", "/messages/support/tickets/#{open_case.reference}"
      assert_empty css_select("a.chats-row__link[href*='#{closed.reference}']"), "closed cases stay on the page"
      assert_select "a.chats-dock__see-all[href='/messages/support/'][data-turbo-frame='_top']",
                    text: /All your conversations.*1 closed conversation/m
    end
  end

  test "without the panel's frame the list is the page it always was" do
    login_as @alice
    get "/messages/support"

    assert_select ".pb-bar"
    assert_select ".chats-inbox__title"
    assert_empty css_select("turbo-frame##{SupportDesk::Launcher::FRAME}")
  end

  test "the wizard in the panel: its step in the panel's one frame, never advancing the page's address" do
    login_as @alice

    get "/messages/support/new", headers: PANEL

    assert_response :success
    assert_select "turbo-frame##{SupportDesk::Launcher::FRAME} .support-desk-panel__wizard" do
      assert_empty css_select("turbo-frame#support_wizard"), "the panel is the frame"
      assert_empty css_select("[data-turbo-action]")
      assert_select "a.support-desk-wizard__back[href='/messages/support/']:not([data-turbo-frame])"
      assert_select "a.support-desk-choice[href='/messages/support/new?topic=order']"
    end

    get "/messages/support/new", params: { topic: "other" }, headers: PANEL
    assert_select "form.support-desk-form[action='/messages/support/tickets']:not([data-turbo-frame])"
  end

  test "sending from the panel opens the new case in the panel, whatever thread_page says" do
    login_as @alice

    post "/messages/support/tickets", params: { topic: "other", message: "Help from the panel" }, headers: PANEL

    ticket = @alice.support_tickets.last
    assert_redirected_to "/messages/support/tickets/#{ticket.reference}"
    assert_equal :chats, SupportDesk.config.thread_page, "the dummy reads cases in the chats inbox"

    get "/messages/support/tickets/#{ticket.reference}", headers: PANEL
    assert_response :success
    assert_select "turbo-frame##{SupportDesk::Launcher::FRAME}" do
      assert_select ".chats-thread.chats-thread--window[data-chats--thread-read-pending-value='true']" do
        assert_select "header.chats-window__header.support-desk-panel__nav" do
          assert_select "a.chats-window__icon[href='/messages/support/'][aria-label='Back']"
          assert_select ".chats-window__name", text: ticket.label
          assert_select "a.chats-window__icon[href=?][data-turbo-frame='_top']",
                        "/messages/support/tickets/#{ticket.reference}"
        end
        assert_select ".chats-message__text", text: "Help from the panel"
        assert_select "form[action=?]", "/messages/#{ticket.conversation_id}/messages"
      end
      assert_empty css_select("[data-chats-dock-hide]"), "the panel never hides the dock it may sit in"
    end

    get "/messages/support/tickets/#{ticket.reference}"
    assert_redirected_to "/messages/#{ticket.conversation_id}", "outside the panel, the ticket URL does what it did"
  end

  test "a refused send in the panel re-renders the step in the panel" do
    login_as @alice

    post "/messages/support/tickets", params: { topic: "other", message: "" }, headers: PANEL

    assert_response :unprocessable_entity
    assert_select "turbo-frame##{SupportDesk::Launcher::FRAME} .support-desk-error", text: /few lines/
  end

  test "another requester's case is a 404 in the panel too" do
    bob = create_user(name: "Bob")
    ticket = ticket_for(bob, topic: :other)
    login_as @alice

    get "/messages/support/tickets/#{ticket.reference}", headers: PANEL

    assert_response :not_found
  end

  # --- the badge ----------------------------------------------------------------

  test "the badge endpoint answers the replace the stream would have sent" do
    ticket = ticket_for(@alice, topic: :other)
    reply_as @lucia, ticket, "One"
    reply_as @lucia, ticket, "Two"
    login_as @alice

    get "/messages/support/tickets/badge", as: :turbo_stream

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_select "turbo-stream[action='replace'][target='#{SupportDesk::Launcher::BADGE_ID}'] template" do
      # Two replies and the notice that Lucía took the case.
      assert_select "##{SupportDesk::Launcher::BADGE_ID}[data-count='3']", text: /3/
    end
  end

  test "the badge endpoint needs a requester" do
    get "/messages/support/tickets/badge", as: :turbo_stream

    assert_response :unauthorized
  end
end
