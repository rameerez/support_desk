# frozen_string_literal: true

require "test_helper"

# Who gets in, and what they can reach once they are in. Three gates, and
# they answer with different status codes on purpose:
#
#   not an agent            403 — you may not use the console
#   authorize_console false 403 — the host's policy said no
#   a desk you can't work   404 — that case is none of your business, and
#                                 saying "403" would confirm it exists
class ConsoleAuthorizationTest < ActionDispatch::IntegrationTest
  setup do
    @alice = create_user(name: "Alice")
    @lucia = create_agent(name: "Lucía")
    @order = create_order(user: @alice, number: "SO1")
    @ticket = ticket_for(@alice, about: @order)
  end

  # --- Being an agent at all --------------------------------------------------

  test "a signed-out visitor gets 403 everywhere" do
    get "/madmin/support_tickets"

    assert_response :forbidden

    get "/madmin/support_tickets/#{@ticket.id}"

    assert_response :forbidden

    post "/madmin/support_tickets/#{@ticket.id}/close"

    assert_response :forbidden
    assert_open @ticket
  end

  test "somebody who isn't an agent gets 403, with a reason" do
    login_as @alice

    get "/madmin/support_tickets"

    assert_response :forbidden
    assert_equal "You don't have access to the support console.", response.body
  end

  test "an agent whose `if:` has gone false loses access without losing their account" do
    login_as @lucia
    get "/madmin/support_tickets"

    assert_response :success

    @lucia.update!(admin: false)
    get "/madmin/support_tickets"

    assert_response :forbidden
  end

  test "the mounted engine gates the same way" do
    login_as @alice

    get "/admin/support"

    assert_response :forbidden

    post "/admin/support/#{@ticket.id}/take"

    assert_response :forbidden
    assert_unassigned @ticket
  end

  # --- The host's own policy ---------------------------------------------------

  test "authorize_console is asked before every action, index included" do
    asked = []
    SupportDesk.config.authorize_console = lambda do |agent, ticket, action|
      asked << [ agent, ticket&.reference, action ]
      true
    end
    login_as @lucia

    get "/madmin/support_tickets"
    get "/madmin/support_tickets/#{@ticket.id}"
    post "/madmin/support_tickets/#{@ticket.id}/close"

    assert_equal [ [ @lucia, nil, :index ],
                   [ @lucia, @ticket.reference, :show ],
                   [ @lucia, @ticket.reference, :close ] ], asked
  end

  test "authorize_console returning false is a 403 and writes nothing" do
    SupportDesk.config.authorize_console = ->(_agent, _ticket, action) { action != :close }
    login_as @lucia

    get "/madmin/support_tickets/#{@ticket.id}"

    assert_response :success

    post "/madmin/support_tickets/#{@ticket.id}/close"

    assert_response :forbidden
    assert_open @ticket
  end

  test "the hook is consulted by the mounted engine too" do
    SupportDesk.config.authorize_console = ->(_agent, _ticket, _action) { false }
    login_as @lucia

    get "/admin/support"

    assert_response :forbidden
  end

  # --- Which desks --------------------------------------------------------------

  test "every desk is visible by default" do
    login_as @lucia

    get "/madmin/support_tickets/#{@ticket.id}"

    assert_response :success
  end

  test "a case on a desk this agent may not work is a 404, not a 403" do
    billing = billing_ticket
    SupportDesk.config.visible_desks_for = ->(_agent) { [ :default ] }
    login_as @lucia

    get "/madmin/support_tickets/#{@ticket.id}"

    assert_response :success

    get "/madmin/support_tickets/#{billing.id}"

    assert_response :not_found

    post "/madmin/support_tickets/#{billing.id}/close"

    assert_response :not_found
    assert_open billing
  end

  test "visible_desks_for accepts desk records as readily as keys" do
    billing = billing_ticket
    SupportDesk.config.visible_desks_for = ->(_agent) { [ SupportDesk.desk(:billing) ] }
    login_as @lucia

    get "/madmin/support_tickets/#{billing.id}"

    assert_response :success

    get "/madmin/support_tickets/#{@ticket.id}"

    assert_response :not_found
  end

  test "the engine scopes the same way" do
    billing = billing_ticket
    SupportDesk.config.visible_desks_for = ->(_agent) { [] }
    login_as @lucia

    get "/admin/support/#{billing.id}"

    assert_response :not_found
  end

  # --- Finding the agent ----------------------------------------------------------

  test "config.current_agent_method is what the engine uses when nobody wrote current_agent" do
    # The engine's controller defines no `current_agent` of its own, so this
    # is the only thing pointing the console at a logged-in person.
    assert_equal :current_user, SupportDesk.config.current_agent_method
    login_as @lucia

    get "/admin/support"

    assert_response :success
  end

  test "a current_agent_method that doesn't exist fails loudly, with the fix in the message" do
    SupportDesk.config.current_agent_method = :whoever_is_around

    # Straight at the controller: through HTTP this is a 500 page like any
    # other unhandled error, and what matters is what a developer reads.
    error = assert_raises(SupportDesk::ConfigurationError) do
      SupportDesk::Console::TicketsController.new.send(:current_agent)
    end

    assert_match(/can't find #whoever_is_around/, error.message)
    assert_match(/config\.current_agent_method/, error.message)
  end

  private

  # A case on a second desk, so "which desks may I work" has an answer that
  # isn't "all of them".
  def billing_ticket
    SupportDesk.config.desk(:billing) { |desk| desk.name = "Facturación" }
    SupportDesk::Ticket.open!(requester: create_user(name: "Bea"), desk: SupportDesk.desk(:billing),
                              topic: "other", message: "Una factura rara")
  end
end
