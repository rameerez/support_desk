# frozen_string_literal: true

require "test_helper"

# What the engine refuses, and how. The rule everywhere: a subject that isn't
# yours and a subject that doesn't exist get the SAME answer, because a 403
# with a hint is a "does this order exist?" oracle.
class TicketsAuthorizationTest < ActionDispatch::IntegrationTest
  setup do
    @alice = create_user(name: "Alice", onboarded: true)
    @mallory = create_user(name: "Mallory", onboarded: true)
    @lucia = create_agent(name: "Lucía")
    @order = create_order(user: @alice, number: "SO1")
    @theirs = create_order(user: @mallory, number: "SO-MALLORY")
  end

  def token_for(record) = SupportDesk::Wizard.sign_subject(record)

  test "every screen is behind the host's own authentication" do
    get "/messages/support"

    assert_response :unauthorized

    get "/messages/support/new"

    assert_response :unauthorized

    post "/messages/support/tickets", params: { topic: "other", message: "hola" }

    assert_response :unauthorized
  end

  test "somebody else's subject is a 404, never a 403 with a hint" do
    login_as @alice
    get "/messages/support/new?about=#{token_for(@theirs)}"

    assert_response :not_found
  end

  test "a tampered token is a 404" do
    login_as @alice
    get "/messages/support/new?about=#{token_for(@order).sub(/--\h+\z/, "--0000")}"

    assert_response :not_found
  end

  test "an expired token is a 404" do
    login_as @alice
    token = token_for(@order)

    travel SupportDesk::Wizard::SUBJECT_TOKEN_TTL + 1.minute do
      get "/messages/support/new?about=#{token}"

      assert_response :not_found
    end
  end

  test "a token for a record that has since been deleted is a 404" do
    login_as @alice
    token = token_for(@order)
    @order.destroy!

    get "/messages/support/new?about=#{token}"

    assert_response :not_found
  end

  test "a raw id is not a token, and buys nothing" do
    login_as @alice
    get "/messages/support/new?about=#{@theirs.id}"

    assert_response :not_found
  end

  test "posting somebody else's subject opens nothing" do
    login_as @alice

    assert_no_difference -> { SupportDesk::Ticket.count } do
      post "/messages/support/tickets", params: { topic: "order", subject: token_for(@theirs), message: "…" }
    end

    assert_response :not_found
  end

  test "a case belongs to the person who opened it" do
    ticket = ticket_for(@mallory, topic: :other)
    login_as @alice

    get "/messages/support/tickets/#{ticket.id}"

    assert_response :not_found
  end

  test "your own case redirects into its conversation" do
    ticket = ticket_for(@alice, about: @order)
    login_as @alice

    get "/messages/support/tickets/#{ticket.id}"

    assert_redirected_to "/messages/#{ticket.conversation.id}"
  end

  test "a case can be reached by the reference people read down a phone line" do
    ticket = ticket_for(@alice, about: @order)
    login_as @alice

    get "/messages/support/tickets/#{ticket.reference.downcase}"

    assert_redirected_to "/messages/#{ticket.conversation.id}"
  end

  test "an unknown reference is a 404, not a 500" do
    login_as @alice

    get "/messages/support/tickets/T-000000"

    assert_response :not_found
  end

  test "an unknown id is a 404" do
    login_as @alice

    get "/messages/support/tickets/999999"

    assert_response :not_found
  end

  test "a requester who isn't the configured requester class is a configuration error, named as one" do
    SupportDesk.config.current_requester_method = :current_order
    login_as @alice

    error = assert_raises(SupportDesk::ConfigurationError) do
      without_exception_handling { get "/messages/support" }
    end

    assert_match(/current_requester_method/, error.message)
    assert_match(/has_support_tickets/, error.message)
  ensure
    SupportDesk.config.current_requester_method = :current_user
  end

  test "an authentication filter the host doesn't have fails with the fix in the message" do
    SupportDesk.config.authenticate_method = :sign_in_or_something!

    error = assert_raises(SupportDesk::ConfigurationError) do
      without_exception_handling { get "/messages/support" }
    end

    assert_match(/config.authenticate_method/, error.message)
  ensure
    SupportDesk.config.authenticate_method = :authenticate_user!
  end
end
