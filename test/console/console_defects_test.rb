# frozen_string_literal: true

require "test_helper"

# The rest of the adversarial review: an upload that silently wasn't one, a
# queue that queried per row, a console that accepted what it refused to
# offer, and a policy hook that could 500 the screen it was guarding.
class ConsoleDefectsTest < ActionDispatch::IntegrationTest
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

  # --- Attachments ------------------------------------------------------------

  test "the reply form is multipart, or an attachment arrives as its filename" do
    # `form_with` sets enctype for the FORM BUILDER's file_field only. This
    # composer uses file_field_tag, so without an explicit html: option the
    # browser posts the filename as a String and `reply!` stores nothing.
    get "/admin/support/#{@ticket.id}"

    assert_select "form[enctype=?]", "multipart/form-data"
  end

  test "an agent's screenshot actually reaches the message" do
    upload = Rack::Test::UploadedFile.new(StringIO.new(ONE_PIXEL_PNG), "image/png", original_filename: "captura.png")

    post "/madmin/support_tickets/#{@ticket.id}/reply",
         params: { body: "Aquí lo tienes", files: [ upload ] }

    assert_equal "Answer sent.", flash[:notice]

    message = @ticket.conversation.messages.order(:created_at).last

    assert_predicate message, :attachments?
    assert_equal [ "captura.png" ], message.files.map { |file| file.filename.to_s }
  end

  # --- The queue's query count --------------------------------------------------

  test "the queue renders a page of rows without a query per row" do
    5.times do |index|
      requester = create_user(name: "Requester #{index}")
      ticket_for(requester, about: create_order(user: requester, number: "SO#{index + 2}"))
    end

    # Every row prints `ticket.label`, which reads the SUBJECT. Warm the
    # request path first so one-off lookups don't count as row cost.
    get "/madmin/support_tickets"

    queries = capture_sql { get "/madmin/support_tickets" }

    assert_response :success
    assert_select "#tickets li", 6
    assert_operator queries.grep(/FROM ["`]orders["`]/).size, :<=, 1,
                    "the subject should be preloaded, not fetched once per row"
  end

  # --- Never accept what you would not offer --------------------------------------

  test "a closed case refuses a reply instead of quietly posting one" do
    # `actions_for` drops :reply once a case is closed, so the composer is
    # gone — but the endpoint used to accept the POST anyway and flash
    # success. A console that refuses what it renders, or renders what it
    # refuses, teaches people to ignore it.
    @ticket.close!(by: @lucia)

    post "/madmin/support_tickets/#{@ticket.id}/reply", params: { body: "Una cosa más" }

    assert_response :redirect
    assert_equal "This case is closed. Reopen it first.", flash[:alert]
    assert_not_includes @ticket.conversation.messages.map(&:body), "Una cosa más"
    assert_closed @ticket
  end

  test "assignee_only refuses a drop-in at the door, naming who holds it" do
    @ticket.assign!(to: @pedro, by: @pedro)

    with_support_config(reply_policy: :assignee_only) do
      post "/madmin/support_tickets/#{@ticket.id}/reply", params: { body: "Me meto yo" }
    end

    assert_match(/Pedro/, flash[:alert])
    assert_not_includes @ticket.conversation.messages.map(&:body), "Me meto yo"
  end

  test "assignee_only tells an agent to take an unheld case rather than naming nobody" do
    with_support_config(reply_policy: :assignee_only) do
      post "/madmin/support_tickets/#{@ticket.id}/reply", params: { body: "Hola" }

      assert_equal "Take this case first — this desk only lets the assignee reply.", flash[:alert]

      get "/admin/support/#{@ticket.id}"
    end

    # The composer says the same thing, and doesn't claim somebody is on it.
    assert_match(/Take this case first/, response.body)
    assert_no_match(/ is handling this case/, response.body)
  end

  test "handing off a case you don't hold is refused before the model sees it" do
    @ticket.assign!(to: @pedro, by: @pedro)

    post "/madmin/support_tickets/#{@ticket.id}/hand_off", params: { agent_id: @lucia.id }

    assert_match(/Pedro/, flash[:alert])
    assert_assigned_to @ticket, @pedro
  end

  test "closing an already closed case is refused, because the button isn't there" do
    @ticket.close!(by: @lucia)

    post "/madmin/support_tickets/#{@ticket.id}/close"

    assert_equal "This case is closed. Reopen it first.", flash[:alert]
  end

  # --- The policy hook can't take the screen down ---------------------------------

  test "an authorize_console hook that raises denies, and doesn't 500" do
    SupportDesk.config.authorize_console = ->(_agent, _ticket, _action) { raise "policy blew up" }

    get "/madmin/support_tickets"

    assert_response :forbidden

    post "/madmin/support_tickets/#{@ticket.id}/close"

    assert_response :forbidden
    assert_open @ticket
  end

  # `Rails.error.subscribe` takes an object that responds to #report, not a
  # proc — and subscribers are process-wide, so this one only collects while
  # it is switched on.
  class ErrorCollector
    attr_reader :reports

    def initialize = @reports = []

    def collecting = (@collecting = true) && self

    def report(error, handled:, source: nil, context: {}, **)
      @reports << { message: error.message, handled: handled, source: source, context: context } if @collecting
    end

    def stop = @collecting = false
  end

  test "a raising hook is reported, not swallowed" do
    collector = ErrorCollector.new
    Rails.error.subscribe(collector)
    collector.collecting
    SupportDesk.config.authorize_console = ->(_agent, _ticket, _action) { raise "policy blew up" }

    get "/madmin/support_tickets"

    report = collector.reports.find { |entry| entry[:message] == "policy blew up" }

    assert report, "a raising authorize_console hook should reach Rails.error"
    assert report[:handled], "it is handled: the console denied and carried on"
    assert_equal "support_desk", report[:source]
    assert_equal :authorize_console, report[:context][:hook]
  ensure
    collector.stop
  end

  # --- A refusal the agent can see -------------------------------------------------

  test "a forbidden verb answers Turbo with something it will actually render" do
    # Turbo only renders an error response it can read as HTML, so a
    # text/plain 403 to a form submission is dropped and the button just
    # looks broken. The stream branch carries the reason instead.
    SupportDesk.config.authorize_console = ->(_agent, _ticket, action) { action != :close }

    post "/madmin/support_tickets/#{@ticket.id}/close",
         headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_match(/<turbo-stream action="refresh">/, response.body)
    assert_equal "You don't have access to the support console.", flash[:alert]
    assert_open @ticket
  end

  test "a plain request still gets a plain 403" do
    SupportDesk.config.authorize_console = ->(_agent, _ticket, action) { action != :close }

    post "/madmin/support_tickets/#{@ticket.id}/close"

    assert_response :forbidden
    assert_equal "You don't have access to the support console.", response.body
    assert_open @ticket
  end

  # --- Locale --------------------------------------------------------------------

  test "a Spanish desk gets Spanish refusals, not the model's English" do
    @ticket.assign!(to: @pedro, by: @pedro)

    I18n.with_locale(:es) do
      post "/madmin/support_tickets/#{@ticket.id}/hand_off", params: { agent_id: @lucia.id }
    end

    assert_match(/Lo lleva Pedro/, flash[:alert])
    assert_no_match(/doesn't hold/, flash[:alert])
  end

  test "every console error key is translated in both locales" do
    en = I18n.t("support_desk.console.errors", locale: :en)
    es = I18n.t("support_desk.console.errors", locale: :es)

    assert_equal en.keys.sort, es.keys.sort

    en.each do |key, english|
      spanish = es[key]

      next if english =~ /\A%\{\w+\}\z/ # a bare interpolation is language-free

      assert_not_equal english, spanish, "support_desk.console.errors.#{key} is untranslated"
    end
  end

  private

  def capture_sql(&block)
    queries = []
    counter = lambda do |_name, _start, _finish, _id, payload|
      next if payload[:name].to_s.match?(/SCHEMA|TRANSACTION/) || payload[:cached]

      queries << payload[:sql]
    end

    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    queries
  end
end
