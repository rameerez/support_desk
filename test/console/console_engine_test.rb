# frozen_string_literal: true

require "test_helper"

# The turnkey console (Layer 4), mounted at /admin/support in the dummy.
#
# It runs the SAME two concerns a host includes and renders the SAME views
# the generator copies, so these tests are doing double duty: they prove the
# mounted engine works, and they prove the generated view set renders every
# piece of the console UX contract from 06.
class ConsoleEngineTest < ActionDispatch::IntegrationTest
  # chats accepts images only by default, and an attachment has to be a real
  # one for Active Storage to mint the blob URL the transcript links to.
  ONE_PIXEL_PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  ).freeze

  setup do
    @alice = create_user(name: "Alice")
    @lucia = create_agent(name: "Lucía")
    @pedro = create_agent(name: "Pedro")
    @order = create_order(user: @alice, number: "SO1")
    @ticket = ticket_for(@alice, about: @order)

    login_as @lucia
  end

  # --- The queue -----------------------------------------------------------------

  test "the queue renders tabs, counts and a row per case" do
    get "/admin/support"

    assert_response :success
    assert_select "h1", "Support queue"
    assert_select "nav a", /Needs a reply/
    assert_select "nav a span", "1"
    assert_select "li a", /Order SO1/
  end

  test "a row carries the requester, the status pill, the preview and the wait" do
    @ticket.reply!("Lo miramos", by: @lucia)

    get "/admin/support", params: { tab: "open" }

    assert_response :success
    assert_select "li" do
      assert_select "span", "Open"
      # The speaker prefix: an agent's answer is SENT by the desk and
      # AUTHORED by the human, so the row names the human.
      assert_select "span", "Lucía:"
    end
    assert_match(/Lo miramos/, response.body)
    assert_match(/Unassigned|Lucía/, response.body)
    assert_match(/in app/, response.body)
  end

  test "the queue subscribes to the desk's stream" do
    get "/admin/support"

    assert_equal Turbo::StreamsChannel.signed_stream_name([ SupportDesk.desk, :queue ]),
                 css_select("turbo-cable-stream-source").first["signed-stream-name"]
  end

  test "an empty tab says so instead of rendering nothing" do
    get "/admin/support", params: { tab: "closed" }

    assert_response :success
    assert_select "p", "Nothing here right now."
  end

  # --- One case --------------------------------------------------------------------

  test "the case renders the context card, the transcript, the composer and the timeline" do
    @ticket.note!("Cliente VIP", by: @lucia)

    get "/admin/support/#{@ticket.id}"

    assert_response :success
    assert_select "h1", "Order SO1"

    # Context card: the host's own `support_context` pairs, verbatim.
    assert_select "section", /Context/
    assert_match(/Requester/, response.body)
    assert_match(/Alice/, response.body)
    assert_match(/Total/, response.body)

    # Transcript.
    assert_select "section", /Conversation/
    assert_match(/Necesito ayuda/, response.body)

    # Composer, both tabs.
    assert_select "nav a", "Reply"
    assert_select "nav a", "Internal note"
    assert_select "form textarea[name=?]", "body"
    assert_select "input[type=file][name=?]", "files[]"

    # Holder line and the pickers.
    assert_match(/Nobody has picked this up yet/, response.body)
    assert_select "form select[name=?]", "agent_id"

    # Timeline, collapsed, with the note in it.
    assert_select "details summary", "Timeline"
    assert_select "details li", /Internal note/
    assert_match(/Cliente VIP/, response.body)
  end

  test "the case subscribes to its own console stream" do
    get "/admin/support/#{@ticket.id}"

    assert_equal Turbo::StreamsChannel.signed_stream_name([ @ticket, :console ]),
                 css_select("turbo-cable-stream-source").first["signed-stream-name"]
  end

  test "the composer tab lives in the URL, so it needs no JavaScript" do
    get "/admin/support/#{@ticket.id}", params: { compose: "note" }

    assert_response :success
    assert_select "form textarea[placeholder=?]", "Something only the desk should know"
    assert_select "input[type=submit][value=?]", "Save note"
  end

  test "the header offers close and refile on an open case, reopen on a closed one" do
    get "/admin/support/#{@ticket.id}"

    assert_select "button", "Close"
    assert_select "select[name=?]", "topic"
    assert_select "button", text: "Reopen", count: 0

    @ticket.close!(by: @lucia)
    get "/admin/support/#{@ticket.id}"

    assert_select "button", "Reopen"
    assert_select "button", text: "Close", count: 0
  end

  test "the composer is replaced by a reason when this agent may not answer" do
    @ticket.assign!(to: @pedro, by: @pedro)

    with_support_config(reply_policy: :assignee_only) do
      get "/admin/support/#{@ticket.id}"
    end

    assert_response :success
    assert_select "form textarea[name=?]", "body", false
    assert_match(/Pedro is handling this case/, response.body)
  end

  test "the hand-off form appears for the holder and the take button for everyone else" do
    get "/admin/support/#{@ticket.id}"

    assert_select "button", "Take"
    assert_select "input[name=?]", "note", false

    @ticket.assign!(to: @lucia, by: @lucia)
    get "/admin/support/#{@ticket.id}"

    assert_select "button", text: "Take", count: 0
    assert_select "input[type=submit][value=?]", "Hand off"
    assert_select "input[name=?]", "note"
  end

  test "an attachment links through the main app, not the engine's routes" do
    file = { io: StringIO.new(ONE_PIXEL_PNG), filename: "captura.png", content_type: "image/png" }
    @ticket.reply!("Aquí lo tienes", by: @lucia, files: [ file ])

    get "/admin/support/#{@ticket.id}"

    assert_response :success
    assert_select "a", "captura.png"
    assert_match(%r{/rails/active_storage/blobs}, response.body)
  end

  # --- The verbs, through the engine ------------------------------------------------

  test "every verb works from the mounted engine and lands back on the case" do
    post "/admin/support/#{@ticket.id}/take"

    assert_redirected_to "/admin/support/#{@ticket.id}"
    assert_assigned_to @ticket, @lucia

    post "/admin/support/#{@ticket.id}/reply", params: { body: "Ya está" }

    assert_redirected_to "/admin/support/#{@ticket.id}"

    post "/admin/support/#{@ticket.id}/note", params: { body: "ojo" }
    post "/admin/support/#{@ticket.id}/change_topic", params: { topic: "billing/invoice" }
    post "/admin/support/#{@ticket.id}/hand_off", params: { agent_id: @pedro.id, note: "turno" }
    post "/admin/support/#{@ticket.id}/release"
    post "/admin/support/#{@ticket.id}/assign", params: { agent_id: @pedro.id }
    post "/admin/support/#{@ticket.id}/close"
    post "/admin/support/#{@ticket.id}/reopen"

    assert_equal %w[opened assigned note topic_changed handed_off released assigned closed reopened],
                 @ticket.events.chronological.map(&:kind),
                 "every verb should have written exactly one event, in the order they were pressed"
    assert_open @ticket
  end

  test "next walks the queue from the engine's own collection route" do
    get "/admin/support/next"

    assert_redirected_to "/admin/support/#{@ticket.id}"
  end

  test "a refusal from the engine is a flash, not a 500" do
    @ticket.assign!(to: @pedro, by: @pedro)

    post "/admin/support/#{@ticket.id}/hand_off", params: { agent_id: @lucia.id }

    assert_response :redirect
    assert_predicate flash[:alert], :present?
    assert_assigned_to @ticket, @pedro
  end

  test "Turbo Stream answers the same way from the engine" do
    post "/admin/support/#{@ticket.id}/close", headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_match(/<turbo-stream action="refresh">/, response.body)
  end

  # --- The nav badge -----------------------------------------------------------------

  test "the nav badge counts what this agent should feel responsible for" do
    assert_equal 1, SupportDesk::Queue.for(@lucia).badge

    rendered = ApplicationController.render(
      partial: "support_desk/console/tickets/nav_badge", locals: { agent: @lucia }
    )

    assert_match(/Support/, rendered)
    assert_match(/>1</, rendered)
  end

  test "the nav badge renders nothing for somebody who isn't an agent" do
    rendered = ApplicationController.render(
      partial: "support_desk/console/tickets/nav_badge", locals: { agent: @alice }
    )

    assert_equal "", rendered.strip
  end
end
