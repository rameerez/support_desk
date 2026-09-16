# frozen_string_literal: true

require "test_helper"

# `link_to_support` where hosts actually call it: on a host page, outside the
# engine, resolving URLs through the mounted route proxy.
class DoorsTest < ActionDispatch::IntegrationTest
  setup do
    @alice = create_user(name: "Alice", onboarded: true)
    @lucia = create_agent(name: "Lucía")
    @order = create_order(user: @alice, number: "SO1")
  end

  test "a door on a host page links into the wizard, with the subject signed" do
    login_as @alice
    get "/doors/#{@order.id}"

    assert_response :success
    assert_select "#subject-door a[href^=?]", "/messages/support/new?about="
    assert_select "#subject-door a", text: "Need help with Order SO1?"
    assert_no_match(/about=#{@order.id}\b/, response.body)
  end

  test "a door takes the host's own words and classes" do
    login_as @alice
    get "/doors/#{@order.id}"

    assert_select "#custom-door a.btn", text: "Reportar un problema"
  end

  test "a door with no subject is the plain way in" do
    login_as @alice
    get "/doors"

    assert_select "#plain-door a[href=?]", "/messages/support/new", text: "Need help?"
  end

  test "once a case is open about it, the door leads there instead" do
    ticket = ticket_for(@alice, about: @order)
    login_as @alice
    get "/doors/#{@order.id}"

    assert_select "#subject-door a[href=?]", "/messages/#{ticket.conversation.id}",
                  text: I18n.t("support_desk.doors.existing")
  end

  test "a closed case opens a new door rather than leading back into it" do
    ticket = ticket_for(@alice, about: @order)
    ticket.close!(by: @lucia)
    login_as @alice
    get "/doors/#{@order.id}"

    assert_select "#subject-door a[href^=?]", "/messages/support/new?about="
  end

  test "doors render nothing at all for a record that isn't the viewer's" do
    login_as create_user(name: "Mallory")
    get "/doors/#{@order.id}"

    assert_response :success
    assert_select "#subject-door a", count: 0
    assert_select "#plain-door a", count: 1
  end

  test "the unread badge counts what the desk has said and they haven't read" do
    ticket = ticket_for(@alice, about: @order)
    reply_as @lucia, ticket, "Lo estamos mirando"

    login_as @alice
    get "/doors"

    # Two: the answer, and the "Lucía is taking care of your request" line
    # that the first assignment posts into the conversation.
    assert_select "#badge .chats-badge", text: "2"
  end

  test "the unread badge renders nothing when there is nothing unread" do
    login_as @alice
    get "/doors"

    assert_select "#badge .chats-badge", count: 0
  end
  test "many doors on one page cost one query, not one each" do
    orders = 5.times.map { |i| create_order(user: @alice, number: "SO#{i}") }
    ticket_for(@alice, about: orders.first)
    login_as @alice
    get "/doors/#{orders.first.id}"

    one_door = count_queries { get "/doors/#{orders.first.id}" }
    # The page draws three doors over the same record; a list screen in a
    # host draws one per card. Either way the lookup happens once.
    door_lookups = one_door.grep(/support_desk_tickets.*subject_id/m)

    assert_equal 1, door_lookups.size, "each door ran its own lookup:\n#{one_door.join("\n")}"
  end
end
