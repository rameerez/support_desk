# frozen_string_literal: true

require "test_helper"

# "Prefiero hablar con una persona."
#
# The one control a requester always has while a machine is answering, and
# the reason the machine is allowed to answer at all: nobody is ever trapped
# in a conversation with software. It is a POST on the CASE rather than
# anything to do with chats, because it is a fact about the case — from here
# on a person is expected, whatever the assistant would have done next.
class RequestHumanTest < ActionDispatch::IntegrationTest
  setup do
    @alice = create_user(name: "Alice", onboarded: true)
    @mallory = create_user(name: "Mallory", onboarded: true)
    @lucia = create_agent(name: "Lucía")
    @rose = configure_assistant!
    @ticket = ticket_for(@alice, message: "¿Dónde está mi pedido?")
  end

  def request_human_path(ticket) = "/messages/support/tickets/#{ticket.id}/request_human"

  test "the door needs a logged-in requester" do
    post request_human_path(@ticket)

    assert_response :unauthorized
    refute_needs_human @ticket
  end

  test "pressing it flags the case and says so" do
    login_as @alice
    post request_human_path(@ticket)

    assert_response :see_other
    assert_redirected_to "/messages/support/tickets/#{@ticket.id}"
    assert_equal "Done. Somebody from the team will take it from here.", flash[:notice]
    assert_needs_human @ticket, reason: "requester_request"

    # And the thread says it too, so the promise is where the conversation
    # is and not only in a flash that is gone on the next page.
    assert_match "Somebody from the team will take it from here",
                 @ticket.conversation.messages.where(kind: "system").last.body
  end

  test "pressing it twice writes once" do
    login_as @alice
    post request_human_path(@ticket)
    at = @ticket.reload.human_required_at

    post request_human_path(@ticket)

    assert_response :see_other
    assert_equal "Done. Somebody from the team will take it from here.", flash[:notice]
    assert_equal at, @ticket.reload.human_required_at, "the second press moved the flag"
    assert_equal 1, @ticket.events.of_kind("human_requested").count
  end

  test "somebody else's case is a 404, not a refusal that confirms it exists" do
    login_as @mallory
    post request_human_path(@ticket)

    assert_response :not_found
    refute_needs_human @ticket
  end

  test "a case nobody can write to comes back with the reason on it" do
    with_support_config(closed_tickets: :locked) do
      @ticket.close!(by: @lucia)

      login_as @alice
      post request_human_path(@ticket)

      assert_response :see_other
      assert_redirected_to "/messages/support/tickets/#{@ticket.id}"
      assert_equal @ticket.chat_locked_notice, flash[:alert]
      assert_nil flash[:notice]
      refute_needs_human @ticket
    end
  end

  test "the list says who is on a case, and what changes when a person is asked for" do
    with_assistant_config(autonomy: :reply) do
      @ticket.assign!(to: @rose, by: @lucia)
    end

    login_as @alice
    get "/messages/support"

    assert_response :success
    assert_match "Handled by Rose · virtual assistant", response.body

    @ticket.request_human!(by: @alice)
    get "/messages/support"

    assert_response :success
    assert_match "Somebody from the team will take it from here", response.body
    assert_no_match(/Handled by Rose/, response.body)
  end
end

# The door itself, as a partial — the three states, and the one that matters
# is the middle one. A door that stays pressable after it worked is a door
# people press again wondering whether it did.
#
# It is a helper rather than a path hosts render, because the thread is
# CHATS' screen: a host that has ejected chats' views drops one line into
# their own copy and the door works, wherever that copy lives.
class RequestHumanDoorTest < ActionView::TestCase
  include SupportDesk::EngineHelper

  setup do
    @alice = create_user(name: "Alice", onboarded: true)
    @lucia = create_agent(name: "Lucía")
  end

  test "no case, nothing to render" do
    assert_nil support_human_door(nil)
  end

  test "no machine has ever been in this conversation, so there is no door" do
    ticket = ticket_for(@alice, message: "Hola")

    assert_no_match(/I’d rather talk to a person/, support_human_door(ticket))
  end

  test "a machine is in play: the door is a button on this case" do
    configure_assistant!
    ticket = ticket_for(@alice, message: "Hola")

    door = support_human_door(ticket)

    assert_match "I’d rather talk to a person", door
    assert_match "/messages/support/tickets/#{ticket.id}/request_human", door
  end

  test "once somebody has asked, the door becomes the promise" do
    configure_assistant!
    ticket = ticket_for(@alice, message: "Hola")
    ticket.request_human!(by: @alice)

    door = support_human_door(ticket)

    assert_match "Somebody from the team will take it from here", door
    assert_no_match(/I’d rather talk to a person/, door)
    assert_no_match(/<form/, door)
  end

  test "a case nobody can write to shows nothing at all" do
    configure_assistant!
    ticket = ticket_for(@alice, message: "Hola")
    with_support_config(closed_tickets: :locked) do
      ticket.close!(by: @lucia)

      assert_no_match(/I’d rather talk to a person/, support_human_door(ticket.reload))
    end
  end

  test "the door survives an assistant a host has switched off since" do
    # `assistant_in_play?` counts HISTORY as well as configuration: a live
    # conversation must not lose its way out because somebody edited an
    # initializer this morning.
    configure_assistant!(autonomy: :reply)
    ticket = ticket_for(@alice, message: "Hola")
    respond_as(support_assistant, ticket, "Te ayudo con eso")

    SupportDesk.config.desk(:default).assistant = nil

    assert_nil ticket.reload.assistant
    assert_operator ticket.assistant_turns_count, :>, 0
    assert_match "I’d rather talk to a person", support_human_door(ticket)
  end
end
