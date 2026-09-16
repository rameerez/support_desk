# frozen_string_literal: true

require "test_helper"

# `config.reply_policy` decides what happens when somebody who isn't the
# assignee answers. The model owns the rule; what these tests pin is that
# the console SURFACES it correctly — the right buttons, the right flash,
# and never a 500 — under all three values.
class ConsoleReplyPoliciesTest < ActionDispatch::IntegrationTest
  setup do
    @alice = create_user(name: "Alice")
    @lucia = create_agent(name: "Lucía")
    @pedro = create_agent(name: "Pedro")
    @order = create_order(user: @alice, number: "SO1")
    @ticket = ticket_for(@alice, about: @order)

    login_as @lucia
  end

  # --- :anyone (the default) ------------------------------------------------------

  test "anyone: answering an unheld case takes it" do
    with_support_config(reply_policy: :anyone) do
      post "/madmin/support_tickets/#{@ticket.id}/reply", params: { body: "Lo miramos" }
    end

    assert_equal "Answer sent.", flash[:notice]
    assert_assigned_to @ticket, @lucia
    assert_ticket_event @ticket, :assigned
    refute_ticket_event @ticket, :drop_in
  end

  test "anyone: a drop-in posts, signed, and leaves ownership alone" do
    @ticket.assign!(to: @pedro, by: @pedro)

    with_support_config(reply_policy: :anyone) do
      post "/madmin/support_tickets/#{@ticket.id}/reply", params: { body: "Yo lo cojo un momento" }
    end

    assert_equal "Answer sent.", flash[:notice]
    assert_assigned_to @ticket, @pedro
    assert_ticket_event @ticket, :drop_in

    message = @ticket.conversation.messages.order(:created_at).last

    assert_equal @lucia, message.author, "a drop-in is signed by whoever wrote it"
  end

  test "anyone: the composer is offered even on somebody else's case" do
    @ticket.assign!(to: @pedro, by: @pedro)

    with_support_config(reply_policy: :anyone) do
      get "/admin/support/#{@ticket.id}"
    end

    assert_select "form textarea[name=?]", "body"
    assert_match(/Held by Pedro/, response.body)
  end

  # --- :take_over ------------------------------------------------------------------

  test "take_over: replying to somebody else's case reassigns it" do
    @ticket.assign!(to: @pedro, by: @pedro)

    with_support_config(reply_policy: :take_over) do
      post "/madmin/support_tickets/#{@ticket.id}/reply", params: { body: "Sigo yo" }
    end

    assert_equal "Answer sent.", flash[:notice]
    assert_assigned_to @ticket, @lucia
    assert_equal "drop_in_takeover", @ticket.assignments.open.first.reason
    refute_ticket_event @ticket, :drop_in
  end

  test "take_over: an unheld case is still taken by whoever answers" do
    with_support_config(reply_policy: :take_over) do
      post "/madmin/support_tickets/#{@ticket.id}/reply", params: { body: "Lo miramos" }
    end

    assert_assigned_to @ticket, @lucia
  end

  # --- :assignee_only -----------------------------------------------------------------

  test "assignee_only: a drop-in is a flash, not a 500 and not a message" do
    @ticket.assign!(to: @pedro, by: @pedro)

    with_support_config(reply_policy: :assignee_only) do
      post "/madmin/support_tickets/#{@ticket.id}/reply", params: { body: "Me meto yo" }
    end

    assert_response :redirect
    assert_predicate flash[:alert], :present?
    assert_assigned_to @ticket, @pedro
    # Two messages: Alice's question and "Pedro is taking care of your
    # request". The refused reply is not one of them.
    assert_not_includes @ticket.conversation.messages.map(&:body), "Me meto yo"
  end

  test "assignee_only: an unheld case refuses the reply rather than taking it" do
    with_support_config(reply_policy: :assignee_only) do
      post "/madmin/support_tickets/#{@ticket.id}/reply", params: { body: "Hola" }
    end

    assert_response :redirect
    assert_predicate flash[:alert], :present?
    assert_unassigned @ticket
    assert_not_includes @ticket.conversation.messages.map(&:body), "Hola"
  end

  test "assignee_only: take then reply is the path through, and the console offers it" do
    with_support_config(reply_policy: :assignee_only) do
      get "/admin/support/#{@ticket.id}"

      # No composer while nobody holds it — the Take button is the way in.
      assert_select "form textarea[name=?]", "body", false
      assert_select "button", "Take"

      post "/madmin/support_tickets/#{@ticket.id}/take"

      assert_assigned_to @ticket, @lucia

      get "/admin/support/#{@ticket.id}"

      assert_select "form textarea[name=?]", "body"

      post "/madmin/support_tickets/#{@ticket.id}/reply", params: { body: "Ya lo tengo" }

      assert_equal "Answer sent.", flash[:notice]
    end

    assert_awaiting_requester @ticket
  end

  test "assignee_only: an internal note is still allowed to anyone on the desk" do
    @ticket.assign!(to: @pedro, by: @pedro)

    with_support_config(reply_policy: :assignee_only) do
      post "/madmin/support_tickets/#{@ticket.id}/note", params: { body: "Ojo con este" }
    end

    assert_equal "Note saved.", flash[:notice]
    assert_equal [ "Ojo con este" ], @ticket.notes.map(&:note)
  end

  # --- Closed cases ---------------------------------------------------------------------

  test "a closed case offers reopen instead of a composer" do
    @ticket.close!(by: @lucia)

    get "/admin/support/#{@ticket.id}"

    assert_select "form textarea[name=?]", "body", false
    assert_match(/This case is closed/, response.body)
    assert_select "button", "Reopen"
  end

  test "replying into a case whose desk locks closed tickets is a flash" do
    @ticket.close!(by: @lucia)

    with_support_config(closed_tickets: :locked) do
      post "/madmin/support_tickets/#{@ticket.id}/reply", params: { body: "Una cosa más" }
    end

    assert_response :redirect
    assert_predicate flash[:alert], :present?
    assert_ticket_closed @ticket
    assert_not_includes @ticket.conversation.messages.map(&:body), "Una cosa más"
  end
end
