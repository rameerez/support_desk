# frozen_string_literal: true

require "test_helper"

# Every console verb, through LAYER 2 — a host's own controller in a host's
# own namespace, with host-owned views. If these pass, `include
# SupportDesk::Console` really is all a host has to write.
class ConsoleActionsTest < ActionDispatch::IntegrationTest
  setup do
    @alice = create_user(name: "Alice")
    @lucia = create_agent(name: "Lucía")
    @pedro = create_agent(name: "Pedro")
    @order = create_order(user: @alice, number: "SO1")
    @ticket = ticket_for(@alice, about: @order)

    login_as @lucia
  end

  # --- The queue ----------------------------------------------------------------

  test "the index renders the queue, its tabs and the badge" do
    get "/madmin/support_tickets"

    assert_response :success
    assert_select "#scope", "awaiting"
    assert_select "#badge", "1"
    assert_select "#tab-awaiting", /Needs a reply \(1\)/
    assert_select "#tab-closed", /Closed \(0\)/
    assert_select "#tickets li", 1
  end

  test "the tab comes from params and falls back when it isn't a real tab" do
    get "/madmin/support_tickets", params: { tab: "closed" }

    assert_response :success
    assert_select "#scope", "closed"
    assert_select "#tickets li", 0

    get "/madmin/support_tickets", params: { tab: "nonsense" }

    assert_response :success
    assert_select "#scope", "awaiting"
  end

  test "the default tab is mine once nothing is awaiting" do
    @ticket.reply!("Lo miramos", by: @lucia)
    register_last_message(@ticket)

    get "/madmin/support_tickets"

    assert_response :success
    assert_select "#scope", "mine"
  end

  test "next opens the most urgent case, and says so when there is none" do
    get "/madmin/support_tickets/next"

    assert_redirected_to "/madmin/support_tickets/#{@ticket.id}"

    @ticket.close!(by: @lucia)
    get "/madmin/support_tickets/next"

    assert_redirected_to "/madmin/support_tickets"
    assert_equal "Nothing is waiting for you.", flash[:notice]
  end

  # --- One case -----------------------------------------------------------------

  test "the show page renders the case, its context and its actions" do
    get "/madmin/support_tickets/#{@ticket.id}"

    assert_response :success
    assert_select "#reference", @ticket.reference
    assert_select "#status", "open"
    assert_select "#assignee", "-"
    assert_select "#context", /Order SO1 · Alice/
    assert_select "#transcript li", 1
    assert_select "#actions", /reply/
  end

  # --- The verbs ------------------------------------------------------------------

  test "reply answers the requester and takes the unheld case" do
    post "/madmin/support_tickets/#{@ticket.id}/reply", params: { body: "Lo estamos revisando" }

    assert_redirected_to "/madmin/support_tickets/#{@ticket.id}"
    assert_equal "Answer sent.", flash[:notice]
    assert_assigned_to @ticket, @lucia

    register_last_message(@ticket)
    assert_awaiting_requester @ticket
    assert_equal "Lo estamos revisando", @ticket.conversation.messages.order(:created_at).last.body
  end

  test "an empty reply is a flash, not a message and not a 500" do
    post "/madmin/support_tickets/#{@ticket.id}/reply", params: { body: "   " }

    assert_redirected_to "/madmin/support_tickets/#{@ticket.id}"
    assert_equal "Write something before sending.", flash[:alert]
    assert_equal 1, @ticket.conversation.messages.count
    assert_unassigned @ticket
  end

  test "take assigns the case to whoever pressed it" do
    post "/madmin/support_tickets/#{@ticket.id}/take"

    assert_equal "This case is yours.", flash[:notice]
    assert_assigned_to @ticket, @lucia
    assert_ticket_event @ticket, :assigned, by: @lucia
  end

  test "assign hands the case to somebody else in the pool" do
    post "/madmin/support_tickets/#{@ticket.id}/assign", params: { agent_id: @pedro.id }

    assert_equal "Assigned to Pedro.", flash[:notice]
    assert_assigned_to @ticket, @pedro
  end

  test "assigning to somebody who isn't on this desk is a flash" do
    outsider = create_user(name: "Outsider")

    post "/madmin/support_tickets/#{@ticket.id}/assign", params: { agent_id: outsider.id }

    assert_equal "Choose an agent from this desk.", flash[:alert]
    assert_unassigned @ticket
  end

  test "hand_off passes the case on, with a note that stays internal" do
    @ticket.assign!(to: @lucia, by: @lucia)

    post "/madmin/support_tickets/#{@ticket.id}/hand_off",
         params: { agent_id: @pedro.id, note: "me voy de turno" }

    assert_equal "Handed off to Pedro.", flash[:notice]
    assert_assigned_to @ticket, @pedro

    event = assert_ticket_event @ticket, :handed_off, from: @lucia, to: @pedro

    assert_equal "me voy de turno", event.payload["note"]
    assert_not_includes @ticket.conversation.messages.map(&:body), "me voy de turno"
  end

  test "handing off a case you don't hold is a flash, never a 500" do
    @ticket.assign!(to: @pedro, by: @pedro)

    post "/madmin/support_tickets/#{@ticket.id}/hand_off", params: { agent_id: @lucia.id }

    assert_response :redirect
    assert_match(/doesn't hold ticket #{@ticket.reference}/, flash[:alert])
    assert_match(/Pedro/, flash[:alert])
    assert_assigned_to @ticket, @pedro
  end

  test "release puts the case back in the pile" do
    @ticket.assign!(to: @lucia, by: @lucia)

    post "/madmin/support_tickets/#{@ticket.id}/release"

    assert_equal "Back in the unassigned pile.", flash[:notice]
    assert_unassigned @ticket
  end

  test "close and reopen" do
    post "/madmin/support_tickets/#{@ticket.id}/close"

    assert_equal "Case closed.", flash[:notice]
    assert_closed @ticket

    post "/madmin/support_tickets/#{@ticket.id}/reopen"

    assert_equal "Case reopened.", flash[:notice]
    assert_open @ticket
  end

  test "note writes to the timeline and never to the conversation" do
    post "/madmin/support_tickets/#{@ticket.id}/note", params: { body: "Cliente VIP" }

    assert_equal "Note saved.", flash[:notice]
    assert_equal [ "Cliente VIP" ], @ticket.notes.map(&:note)
    assert_equal 1, @ticket.conversation.messages.count
  end

  test "an empty note is a flash" do
    post "/madmin/support_tickets/#{@ticket.id}/note", params: { body: " " }

    assert_equal "A note needs something to say.", flash[:alert]
    assert_empty @ticket.notes
  end

  test "change_topic refiles the case" do
    post "/madmin/support_tickets/#{@ticket.id}/change_topic", params: { topic: "billing/invoice" }

    assert_equal "Refiled.", flash[:notice]
    assert_equal "billing/invoice", @ticket.reload.topic.path
  end

  test "a topic that isn't in the tree is a flash" do
    post "/madmin/support_tickets/#{@ticket.id}/change_topic", params: { topic: "nope" }

    assert_equal "That topic isn't in this desk's tree.", flash[:alert]
    assert_equal "order", @ticket.reload.topic.path
  end

  test "an empty topic is a flash" do
    post "/madmin/support_tickets/#{@ticket.id}/change_topic", params: { topic: "" }

    assert_equal "Choose a topic.", flash[:alert]
  end

  # --- Turbo ------------------------------------------------------------------------

  test "every verb answers a Turbo Stream request with a page refresh" do
    post "/madmin/support_tickets/#{@ticket.id}/take",
         headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_match(/<turbo-stream action="refresh">/, response.body)
    # The flash is a real flash, so it survives the refetch the refresh triggers.
    assert_equal "This case is yours.", flash[:notice]
  end

  test "a refused verb answers Turbo the same way, with the alert" do
    @ticket.assign!(to: @pedro, by: @pedro)

    post "/madmin/support_tickets/#{@ticket.id}/hand_off",
         params: { agent_id: @lucia.id },
         headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_match(/<turbo-stream action="refresh">/, response.body)
    assert_predicate flash[:alert], :present?
  end

  test "the show page subscribes to the ticket stream and the index to the queue's" do
    get "/madmin/support_tickets/#{@ticket.id}"

    assert_select "turbo-cable-stream-source[signed-stream-name]"
    assert_equal Turbo::StreamsChannel.signed_stream_name([ @ticket, :console ]),
                 css_select("turbo-cable-stream-source").first["signed-stream-name"]

    get "/madmin/support_tickets"

    assert_equal Turbo::StreamsChannel.signed_stream_name([ SupportDesk.desk, :queue ]),
                 css_select("turbo-cable-stream-source").first["signed-stream-name"]
  end

  # --- Attribution --------------------------------------------------------------------

  test "the console sets Current.actor, so a transition without by: is still signed" do
    post "/madmin/support_tickets/#{@ticket.id}/take"

    assert_equal @lucia, @ticket.events.of_kind(:assigned).first.actor
  end

  test "the request reaches the transitioned event's subscribers" do
    seen = nil
    SupportDesk.on(:ticket_transitioned) { |_ticket, kind, by:, request:, payload:| seen = [ kind, by, request, payload ] }

    post "/madmin/support_tickets/#{@ticket.id}/close"

    kind, by, request, = seen

    assert_equal :closed, kind
    assert_equal @lucia, by
    assert_kind_of ActionDispatch::Request, request
  end
end
