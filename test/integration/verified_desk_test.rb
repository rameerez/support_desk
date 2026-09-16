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
    assert_empty css_select(BADGE), "a plain acts_as_messager model is not an official account"

    get "/messages/#{conversation.id}"
    assert_response :success
    assert_empty css_select(BADGE)
    assert_equal "Bob", css_select(".chats-thread__title").first.text.strip
  end

  test "the badge says what it means, in the host's locale" do
    ticket_for(@alice, topic: :other)

    get "/messages"

    badge = css_select(BADGE).first
    assert_equal "img", badge["role"]
    assert_equal I18n.t("chats.verified.label"), badge["aria-label"]
  end
end
