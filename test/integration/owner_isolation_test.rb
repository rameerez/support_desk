# frozen_string_literal: true

require "test_helper"

# One person, a customer of two owners. Every requester screen serves the
# owner of the request (SupportDesk::Current.owner, set by the host per
# request) and none of them may show, open or count the other owner's case.
class OwnerIsolationTest < ActionDispatch::IntegrationTest
  setup do
    @acme = create_user(name: "Acme")
    @globex = create_user(name: "Globex")
    @alice = create_user(name: "Alice", onboarded: true)
    @acme_case = SupportDesk::Current.set(owner: @acme) { @alice.ask_support!("acme question", topic: :account) }
    @globex_case = SupportDesk::Current.set(owner: @globex) { @alice.ask_support!("globex question", topic: :account) }
  end

  test "the list shows the current owner's cases only" do
    login_as @alice, owner: @acme
    get "/messages/support"

    assert_response :success
    assert_includes response.body, %(href="/messages/#{@acme_case.conversation_id}")
    assert_not_includes response.body, %(href="/messages/#{@globex_case.conversation_id}")
  end

  test "another owner's case is a 404, by reference and by id" do
    login_as @alice, owner: @acme

    get "/messages/support/tickets/#{@globex_case.reference}"
    assert_response :not_found

    get "/messages/support/tickets/#{@globex_case.id}"
    assert_response :not_found

    get "/messages/support/tickets/#{@acme_case.reference}"
    assert_response :redirect
  end

  test "the badge counts the current owner's unread cases only" do
    @globex_case.reply!("from globex", by: create_agent)

    login_as @alice, owner: @globex
    get "/messages/support/tickets/badge", headers: { "Accept" => "text/vnd.turbo-stream.html" }
    globex_badge = response.body

    login_as @alice, owner: @acme
    get "/messages/support/tickets/badge", headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_match(/data-count="[1-9]/, globex_badge)
    assert_match(/data-count="0"/, response.body)
  end
end
