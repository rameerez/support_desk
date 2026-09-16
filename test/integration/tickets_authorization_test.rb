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

  # --- Topic visibility is authorization, not decoration -------------------------
  #
  # `only:` and `retired:` decide what a requester may FILE UNDER, not just
  # what the picker draws. Typing the path, or pointing at a record whose own
  # topic is hidden, must both come back refused — otherwise a topic carrying
  # `priority:` or `route_to:` is a privilege anybody can claim.

  test "a topic hidden by only: cannot be walked into by typing its path" do
    login_as create_user(name: "Fresh", onboarded: false)

    get "/messages/support/new?topic=account"

    assert_response :success
    # The topic step, not the composer: nothing to write into.
    assert_select "textarea[name=message]", count: 0
    assert_select ".support-desk-choice__label", text: "Account", count: 0
  end

  test "posting under a topic hidden by only: opens nothing" do
    login_as create_user(name: "Fresh", onboarded: false)

    assert_no_difference -> { SupportDesk::Ticket.count } do
      post "/messages/support/tickets", params: { topic: "account", message: "Déjame entrar" }
    end

    assert_response :unprocessable_entity
  end

  test "a retired topic opens nothing either" do
    SupportDesk.config.topics do
      topic :order, about: "Order", retired: true
      other
    end
    login_as @alice

    get "/messages/support/new?topic=order"

    assert_select "textarea[name=message]", count: 0

    assert_no_difference -> { SupportDesk::Ticket.count } do
      post "/messages/support/tickets", params: { topic: "order", message: "Sobre un pedido viejo" }
    end

    assert_response :unprocessable_entity
  end

  test "a hidden topic's priority cannot be claimed by naming it" do
    SupportDesk.config.topics do
      topic :safety, priority: :urgent, only: ->(requester) { requester.admin? }
      other
    end
    login_as @alice # not an admin

    assert_no_difference -> { SupportDesk::Ticket.count } do
      post "/messages/support/tickets", params: { topic: "safety", message: "Es urgente" }
    end

    assert_response :unprocessable_entity

    # And the honest route still files at the normal priority.
    post "/messages/support/tickets", params: { topic: "other", message: "Una duda" }

    assert_equal 0, SupportDesk::Ticket.last.priority
  end

  test "a subject whose own topic is hidden does not smuggle the requester in" do
    SupportDesk.config.topics do
      topic :order, about: "Order", priority: :urgent, only: ->(_requester) { false }
      other
    end
    login_as @alice

    get "/messages/support/new?about=#{token_for(@order)}"

    assert_response :success
    assert_select "textarea[name=message]", count: 0

    assert_no_difference -> { SupportDesk::Ticket.count } do
      post "/messages/support/tickets", params: { topic: "order", subject: token_for(@order), message: "…" }
    end
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
