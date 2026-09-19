# frozen_string_literal: true

require "test_helper"

# `config.visible_desks_for` has to hold on the QUEUE, not just on one
# ticket. The member actions were scoped from the start; the index, `next`,
# the tab counts and the badge all hang off the desk `?desk=` names, and for
# a while that parameter was read without ever asking what this agent may
# see. A 200 with a reference, a requester's name and a summary on it is a
# leak even when the member action behind it would have 404ed — and a
# `next` that redirects to an id which then 404s is an existence oracle,
# which is worse, because it answers about ONE case.
class ConsoleDeskScopingTest < ActionDispatch::IntegrationTest
  setup do
    @alice = create_user(name: "Alice")
    @lucia = create_agent(name: "Lucía")
    @order = create_order(user: @alice, number: "SO1")
    @ticket = ticket_for(@alice, about: @order)

    @bea = create_user(name: "Bea")
    SupportDesk.config.desk(:billing) { |desk| desk.name = "Facturación" }
    @billing = SupportDesk::Ticket.open!(requester: @bea, desk: SupportDesk.desk(:billing),
                                         topic: "other", message: "Una factura rara")

    login_as @lucia
  end

  # --- No desks at all ---------------------------------------------------------

  test "an agent with no visible desks gets 403, not a queue" do
    SupportDesk.config.visible_desks_for = ->(_agent) { [] }

    get "/madmin/support_tickets"

    assert_response :forbidden
  end

  test "?desk= cannot conjure a queue an agent may not see" do
    SupportDesk.config.visible_desks_for = ->(_agent) { [] }

    get "/madmin/support_tickets", params: { desk: "billing" }

    assert_response :forbidden
    assert_no_match(/Facturación/, response.body)
    assert_no_match(/#{@billing.reference}/, response.body)
    assert_no_match(/Bea/, response.body)
  end

  test "next cannot become an existence oracle for an invisible case" do
    SupportDesk.config.visible_desks_for = ->(_agent) { [] }

    get "/madmin/support_tickets/next", params: { desk: "billing" }

    assert_response :forbidden
    assert_no_match(/#{@billing.id}/, response.body)
  end

  test "the mounted engine refuses the same way" do
    SupportDesk.config.visible_desks_for = ->(_agent) { [] }

    get "/admin/support", params: { desk: "billing" }

    assert_response :forbidden
  end

  # --- Some desks, but not that one ------------------------------------------------

  test "?desk= naming an invisible desk falls back to a visible one" do
    SupportDesk.config.visible_desks_for = ->(_agent) { [ :default ] }

    get "/madmin/support_tickets", params: { desk: "billing", tab: "open" }

    assert_response :success
    assert_no_match(/#{@billing.reference}/, response.body)
    assert_no_match(/Bea/, response.body)
    assert_match(/#{@ticket.reference}/, response.body)
  end

  test "the tab counts and the badge only count visible desks" do
    SupportDesk.config.visible_desks_for = ->(_agent) { [ :default ] }

    get "/madmin/support_tickets", params: { desk: "billing" }

    assert_response :success
    assert_select "#badge", "1"
    assert_select "#tab-awaiting", /\(1\)/
    assert_select "#tab-open", /\(1\)/
  end

  test "next never hands out a case from an invisible desk" do
    # Only the billing case is awaiting, so an unscoped `next` would reach
    # for it; a scoped one has nothing to offer and says so.
    @ticket.close!(by: @lucia)
    SupportDesk.config.visible_desks_for = ->(_agent) { [ :default ] }

    get "/madmin/support_tickets/next", params: { desk: "billing" }

    assert_redirected_to "/madmin/support_tickets"
    assert_equal "Nothing is waiting for you.", flash[:notice]
  end

  test "a visible desk is still reachable through ?desk=" do
    SupportDesk.config.visible_desks_for = ->(_agent) { %i[default billing] }

    get "/madmin/support_tickets", params: { desk: "billing", tab: "open" }

    assert_response :success
    assert_match(/#{@billing.reference}/, response.body)
    assert_no_match(/#{@ticket.reference}/, response.body)
  end

  test "a case on an invisible desk is still a 404 on the member actions" do
    SupportDesk.config.visible_desks_for = ->(_agent) { [ :default ] }

    get "/madmin/support_tickets/#{@billing.id}"

    assert_response :not_found

    post "/madmin/support_tickets/#{@billing.id}/close"

    assert_response :not_found
    assert_ticket_open @billing
  end

  # --- The assign target ---------------------------------------------------------------

  test "assign resolves the agent against the TICKET's desk, not ?desk=" do
    # A billing-only agent, and a default-desk ticket. Resolving the target
    # from `?desk=` let one be assigned to the other.
    pedro = create_agent(name: "Pedro")
    SupportDesk.config.desk(:billing) { |desk| desk.agents = -> { User.where(id: pedro.id) } }
    SupportDesk.config.agents { User.where(id: @lucia.id) }

    post "/madmin/support_tickets/#{@ticket.id}/assign", params: { desk: "billing", agent_id: pedro.id }

    assert_equal "Choose an agent from this desk.", flash[:alert]
    assert_unassigned @ticket
  end

  test "hand_off resolves the agent against the TICKET's desk too" do
    pedro = create_agent(name: "Pedro")
    SupportDesk.config.desk(:billing) { |desk| desk.agents = -> { User.where(id: pedro.id) } }
    SupportDesk.config.agents { User.where(id: @lucia.id) }
    @ticket.assign!(to: @lucia, by: @lucia)

    post "/madmin/support_tickets/#{@ticket.id}/hand_off", params: { desk: "billing", agent_id: pedro.id }

    assert_equal "Choose an agent from this desk.", flash[:alert]
    assert_assigned_to @ticket, @lucia
  end

  test "the picker and the server agree about who is assignable" do
    pedro = create_agent(name: "Pedro")
    SupportDesk.config.agents { User.where(id: [ @lucia.id, pedro.id ]) }

    get "/admin/support/#{@ticket.id}"

    offered = css_select("select[name=agent_id] option").map { |option| option["value"] }.reject(&:blank?)

    # Actor KEYS, not ids: the pool can hold people and a machine from two
    # different tables, and "3" would name either of them.
    assert_equal [ SupportDesk.actor_key(pedro) ], offered

    post "/madmin/support_tickets/#{@ticket.id}/assign", params: { agent_id: offered.first }

    assert_assigned_to @ticket, pedro
  end
end
