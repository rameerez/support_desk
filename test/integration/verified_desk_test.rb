# frozen_string_literal: true

require "test_helper"

# The desk is an OFFICIAL account (`acts_as_messager verified: true`, chats
# 0.3.0), so chats badges it wherever it names a messager. A requester should
# be able to tell the real desk from anyone who simply called themselves
# "Soporte", without reading the name carefully.
class VerifiedDeskTest < ActionDispatch::IntegrationTest
  BADGE = "span.chats-verified"

  setup do
    @alice = create_user(name: "Alice", onboarded: true)
    login_as @alice
  end

  test "the desk's inbox row carries the official-account badge" do
    ticket_for(@alice, topic: :other)

    get "/messages"

    assert_response :success
    row = css_select(".chats-row--group").first
    assert_includes row.text, "Soporte"
    assert_equal 1, row.css(BADGE).size
  end

  test "the case thread badges the desk in its header" do
    ticket = ticket_for(@alice, topic: :other)

    get "/messages/#{ticket.conversation_id}"

    assert_response :success
    title = css_select(".chats-thread__title").first
    assert_includes title.text, "Soporte"
    assert_equal 1, title.css(BADGE).size
  end

  test "an ordinary person is never badged" do
    bob = create_user(name: "Bob")
    conversation = @alice.chat_with(bob)

    get "/messages"
    assert_response :success
    # Alice has no case, so the desk door is on this page too and IS badged.
    # Bob is the row under test: a plain acts_as_messager model is not an
    # official account, and sharing a screen with one does not make it one.
    bobs_row = css_select("li.chats-row").reject { |row| row.text.include?("Soporte") }.first
    assert_includes bobs_row.text, "Bob"
    assert_empty bobs_row.css(BADGE)

    get "/messages/#{conversation.id}"
    assert_response :success
    assert_empty css_select(BADGE)
    assert_equal "Bob", css_select(".chats-thread__title").first.text.strip
  end

  # --- the door ---------------------------------------------------------------
  #
  # The door stands in for the desk's own inbox row BEFORE the requester has
  # written. chats badges that real row, so if the door went unbadged the mark
  # would read as a property of having written to us rather than of the
  # account.

  test "the door is badged before the requester has any case" do
    get "/messages"

    assert_response :success
    door = css_select(".support-desk-inbox-door").first
    assert_includes door.text, "Soporte"
    assert_equal 1, door.css(BADGE).size
  end

  test "the door is badged even before the desk has a row at all" do
    SupportDesk::Desk.delete_all
    SupportDesk.reset_desks!

    assert_no_difference -> { SupportDesk::Desk.count } do
      get "/messages"
    end

    assert_equal 1, css_select(".support-desk-inbox-door #{BADGE}").size,
                 "the badge is a property of the account, not of whether the table has a row yet"
  end

  test "badging the door costs no query of its own" do
    # The avatar already looked the desk up; the badge must share that lookup,
    # not add a second one. Two renders so a per-render regression shows up as
    # 4 instead of 2.
    counts = []
    2.times do
      counts << count_desk_queries { get "/messages" }
      assert_response :success
    end

    assert_equal [ 1, 1 ], counts,
                 "the door resolves the desk exactly once per render (avatar + badge share it)"
  end

  test "the badge says what it means, in the host's locale" do
    ticket_for(@alice, topic: :other)

    get "/messages"

    badge = css_select(BADGE).first
    assert_equal "img", badge["role"]
    assert_equal I18n.t("chats.verified.label"), badge["aria-label"]
  end

  private

  # SELECTs against support_desk_desks while the block runs. Scoped to that
  # table on purpose: the inbox issues plenty of other queries, and this test
  # is about ONE of them.
  def count_desk_queries
    count = 0
    counter = lambda do |_name, _start, _finish, _id, payload|
      count += 1 if payload[:sql].to_s.match?(/\bFROM\s+["`]?support_desk_desks\b/i)
    end

    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end
end
