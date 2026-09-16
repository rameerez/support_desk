# frozen_string_literal: true

require "test_helper"
require "generators/support_desk/console_generator"

# The generated view set, RENDERED from a host's controller.
#
# Everything else about the generator checks the files: that they exist,
# that they are byte-identical to the engine's, that they compile. None of
# that catches the failure that actually matters — a template that renders
# inside the mounted engine and breaks in a host app, because the engine
# has `main_app`, its own route proxy and its own view lookup prefix and a
# host has none of them. The dummy's madmin console deliberately ships its
# own minimal views, so without this test the generated ones never run
# under a host controller at all.
#
# So: generate into a scratch directory, point the host controller's view
# path at it, and drive the real console through real requests.
class ConsoleGeneratedViewsTest < ActionDispatch::IntegrationTest
  GENERATED_ROOT = File.expand_path("../tmp/generated_console", __dir__)

  ONE_PIXEL_PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  ).freeze

  # Generate ONCE, at load time — not in `setup`. Rails' generator
  # machinery reaches into the application while it boots its own, which
  # from inside a test's transaction leaves the request looking at a
  # database with none of the fixture rows in it.
  FileUtils.rm_rf(GENERATED_ROOT)
  FileUtils.mkdir_p(GENERATED_ROOT)
  SupportDesk::Generators::ConsoleGenerator.start(
    [ "madmin", "--force", "--quiet" ], destination_root: GENERATED_ROOT
  )

  setup do
    @alice = create_user(name: "Alice")
    @lucia = create_agent(name: "Lucía")
    @pedro = create_agent(name: "Pedro")
    @order = create_order(user: @alice, number: "SO1")
    @ticket = ticket_for(@alice, about: @order)

    @original_view_paths = Madmin::SupportTicketsController.view_paths.to_a
    Madmin::SupportTicketsController.prepend_view_path(File.join(GENERATED_ROOT, "app/views"))

    login_as @lucia
  end

  teardown do
    Madmin::SupportTicketsController.view_paths = @original_view_paths
  end

  test "the generated queue renders under a host namespace" do
    get "/madmin/support_tickets"

    assert_response :success
    assert_select "h1", "Support queue"

    # Tabs, and the paths behind them, resolved against the HOST's routes.
    assert_select "nav a", /Needs a reply/
    assert_select "nav a[href=?]", "/madmin/support_tickets?tab=mine"
    assert_select "a[href=?]", "/madmin/support_tickets/next"

    # A row, linking to the host's show route.
    assert_select "li a[href=?]", "/madmin/support_tickets/#{@ticket.id}" do
      assert_select "span", "Order SO1"
    end
  end

  test "the generated case page renders every panel under a host namespace" do
    @ticket.note!("Cliente VIP", by: @lucia)

    get "/madmin/support_tickets/#{@ticket.id}"

    assert_response :success
    assert_select "h1", "Order SO1"

    # Context card: the host's own supportable methods.
    assert_match(/Requester/, response.body)
    assert_match(/Alice/, response.body)
    assert_match(/Total/, response.body)

    # Transcript, through `support_transcript` on a host controller.
    assert_match(/Necesito ayuda/, response.body)

    # Composer, with the host's reply path and the multipart fix.
    assert_select "form[action=?][enctype=?]",
                  "/madmin/support_tickets/#{@ticket.id}/reply", "multipart/form-data"

    # Holder line, picker, header actions and the timeline.
    assert_select "form[action=?]", "/madmin/support_tickets/#{@ticket.id}/take"
    assert_select "form[action=?] select[name=?]", "/madmin/support_tickets/#{@ticket.id}/assign", "agent_id"
    assert_select "form[action=?] select[name=?]", "/madmin/support_tickets/#{@ticket.id}/change_topic", "topic"
    assert_select "details summary", "Timeline"
    assert_select "details li", /Internal note/
  end

  test "the generated composer tabs link through the host's show path" do
    get "/madmin/support_tickets/#{@ticket.id}", params: { compose: "note" }

    assert_response :success
    assert_select "nav a[href=?]", "/madmin/support_tickets/#{@ticket.id}?compose=reply"
    assert_select "form[action=?]", "/madmin/support_tickets/#{@ticket.id}/note"
  end

  test "an attachment in the generated transcript links through the main app" do
    file = { io: StringIO.new(ONE_PIXEL_PNG), filename: "captura.png",
             content_type: "image/png" }
    @ticket.reply!("Aquí lo tienes", by: @lucia, files: [ file ])

    get "/madmin/support_tickets/#{@ticket.id}"

    assert_response :success
    # `main_app` doesn't exist in a host controller, so the transcript has
    # to reach Active Storage a way that works in both places.
    assert_select "a", "captura.png"
    assert_match(%r{/rails/active_storage/blobs}, response.body)
  end

  test "a verb pressed from the generated markup goes through" do
    get "/madmin/support_tickets/#{@ticket.id}"

    form = css_select("form").find { |candidate| candidate["action"].to_s.end_with?("/take") }

    post form["action"]

    assert_assigned_to @ticket, @lucia
  end
end
