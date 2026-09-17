# frozen_string_literal: true

require "test_helper"

# The dummy app runs with forgery protection off, the way most engine dummy
# apps do — which means nothing in the suite could tell the difference
# between a console that is CSRF-protected and one that isn't. Every console
# verb is a POST through `button_to` or `form_with`, so the tokens are
# there; this turns the check back on for one example so a regression that
# removed them (a bare link, a `method: :get` verb) would fail here.
class ConsoleCsrfTest < ActionDispatch::IntegrationTest
  setup do
    @alice = create_user(name: "Alice")
    @lucia = create_agent(name: "Lucía")
    @ticket = ticket_for(@alice, about: create_order(user: @alice, number: "SO1"))

    login_as @lucia

    @forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @forgery_protection
  end

  test "a verb posted without a token changes nothing" do
    post "/madmin/support_tickets/#{@ticket.id}/close"

    assert_ticket_open @ticket, "a tokenless POST must not close a case"
    assert_not_equal "Case closed.", flash[:notice]
  end

  test "every verb the console renders carries a token" do
    get "/admin/support/#{@ticket.id}"

    assert_response :success

    forms = css_select("form")

    assert_predicate forms, :any?

    forms.each do |form|
      action = form["action"]
      next unless form["method"].to_s.casecmp("post").zero?

      assert_predicate form.css("input[name=authenticity_token]"), :any?,
                       "the form posting to #{action} has no CSRF token"
    end
  end

  test "a verb posted WITH the rendered token goes through" do
    get "/admin/support/#{@ticket.id}"

    form = css_select("form").find { |candidate| candidate["action"].to_s.end_with?("/take") }
    token = form.css("input[name=authenticity_token]").first["value"]

    post "/admin/support/#{@ticket.id}/take", params: { authenticity_token: token }

    assert_assigned_to @ticket, @lucia
  end

  test "writing first without a token writes nothing" do
    post "/madmin/support_tickets/open_conversation",
         params: { requester: @alice.to_global_id.to_s, body: "Vimos que…" }

    assert_equal 1, SupportDesk::Ticket.count, "only the one from setup"
  end

  test "the compose form carries a token" do
    get "/madmin/support_tickets/new", params: { requester: @alice.to_global_id.to_s }

    assert_response :success
    form = css_select("form").find { |candidate| candidate["action"].to_s.include?("/open_conversation") }

    assert_not_nil form, "the compose form is missing"
    assert_predicate form.css("input[name=authenticity_token]"), :any?
  end
end
