# frozen_string_literal: true

require "test_helper"

# "Escribir a alguien": the two collection actions that have no ticket yet —
# the form, and the send behind it — driven through LAYER 2, a host's own
# controller in a host's own namespace with host-owned views.
#
# The refusals matter more than the happy path here. Every one of them has to
# come back as the form with the draft still in it, and write nothing at all.
class ConsoleConversationsTest < ActionDispatch::IntegrationTest
  ONE_PIXEL_PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  ).freeze

  setup do
    @alice = create_user(name: "Alice", email: "alice@example.com")
    @lucia = create_agent(name: "Lucía")
    @pedro = create_agent(name: "Pedro")
    @order = create_order(user: @alice, number: "SO1")
    # The console works the desks that EXIST, and a desk row is written
    # the first time anybody asks for one. These examples open no case
    # first, so they ask here.
    SupportDesk.desk

    login_as @lucia
  end

  # --- The form -----------------------------------------------------------------

  test "new renders with the requester from a GlobalID" do
    get "/madmin/support_tickets/new", params: { requester: @alice.to_global_id.to_s }

    assert_response :success
    assert_select "#requester", "Alice"
    assert_select "#new_conversation"
    assert_no_missing_translations
  end

  test "new with a typed query goes through config.find_requester" do
    SupportDesk.config.find_requester { |query| User.find_by(email: query.to_s.strip.downcase) }

    get "/madmin/support_tickets/new", params: { requester_query: "  Alice@Example.com " }

    assert_response :success
    assert_select "#requester", "Alice"
  end

  test "a blank form is an empty form, not an unknown-requester error" do
    SupportDesk.config.find_requester { |query| User.find_by(email: query) }

    get "/madmin/support_tickets/new"

    assert_response :success
    assert_select "#requester_query"
    assert_nil flash[:alert]
  end

  test "with no requester and no way to look one up, the form says so instead of pretending" do
    get "/madmin/support_tickets/new"

    assert_response :success
    assert_select "#requester_hint", /find_requester/
    assert_select "#send", false, "a form that can't reach anybody offers no send button"
  end

  test "an invalid token is the same refusal on the form as on the send" do
    get "/madmin/support_tickets/new", params: { requester: "gid://dummy/User/999999" }

    assert_response :unprocessable_entity
    assert_select "#flash-alert", "That link doesn't point at anybody we can write to."

    post "/madmin/support_tickets/open_conversation",
         params: { requester: "gid://dummy/User/999999", body: "hola" }

    assert_response :unprocessable_entity
    assert_select "#flash-alert", "That link doesn't point at anybody we can write to."
    assert_equal 0, SupportDesk::Ticket.count
  end

  # --- Sending -------------------------------------------------------------------

  test "open_conversation sends and redirects to the case" do
    post "/madmin/support_tickets/open_conversation",
         params: { requester: @alice.to_global_id.to_s, topic: "other", body: "Vimos que tu pedido no llegó" }

    ticket = SupportDesk::Ticket.sole

    assert_response :see_other
    assert_redirected_to "/madmin/support_tickets/#{ticket.id}"
    assert_equal "Message sent to Alice.", flash[:notice]
    assert_predicate ticket, :opened_by_support?
    assert_equal @lucia, ticket.opened_by
    assert_assigned_to ticket, @lucia
    assert_equal "Vimos que tu pedido no llegó", ticket.messages.where(kind: "text").sole.body
  end

  test "a case that already exists is a reply into it, and says the same true thing" do
    existing = @alice.ask_support!("no llega", about: @order)

    post "/madmin/support_tickets/open_conversation",
         params: { requester: @alice.to_global_id.to_s, about: @order.to_global_id.to_s,
                   body: "lo estamos mirando" }

    assert_response :see_other
    assert_redirected_to "/madmin/support_tickets/#{existing.id}"
    assert_equal "Message sent to Alice.", flash[:notice]
    assert_equal 1, SupportDesk::Ticket.count
    assert_equal [ "no llega", "lo estamos mirando" ],
                 existing.reload.messages.where(kind: "text").oldest_first.map(&:body)
  end

  test "the subject comes through the form and brings its topic with it" do
    post "/madmin/support_tickets/open_conversation",
         params: { requester: @alice.to_global_id.to_s, about: @order.to_global_id.to_s, body: "una cosa" }

    ticket = SupportDesk::Ticket.sole

    assert_equal @order, ticket.subject
    assert_equal "order", ticket.topic.path
  end

  # --- Refusals ------------------------------------------------------------------

  test "an unknown person, an empty message and a body chats refuses all come back as the form" do
    SupportDesk.config.find_requester { |query| User.find_by(email: query) }

    post "/madmin/support_tickets/open_conversation",
         params: { requester_query: "nobody@example.com", body: "hola" }

    assert_response :unprocessable_entity
    assert_select "#flash-alert", "We can't find that person."
    assert_select "#body", "hola"

    post "/madmin/support_tickets/open_conversation",
         params: { requester: @alice.to_global_id.to_s, body: "   " }

    assert_response :unprocessable_entity
    assert_select "#requester", "Alice"

    post "/madmin/support_tickets/open_conversation",
         params: { requester: @alice.to_global_id.to_s, body: "x" * (Chats.config.max_message_length + 1) }

    assert_response :unprocessable_entity
    assert_select "#flash-alert"

    assert_equal 0, SupportDesk::Ticket.count
    assert_equal 0, Chats::Conversation.count
  end

  test "an account that can't be written to is refused by name, not as 'not found'" do
    @alice.update!(support_blocked: true)

    post "/madmin/support_tickets/open_conversation",
         params: { requester: @alice.to_global_id.to_s, body: "hola" }

    assert_response :unprocessable_entity
    assert_select "#flash-alert", "That account can't receive support messages."
    assert_equal 0, SupportDesk::Ticket.count
  end

  test "a supplied GlobalID is authoritative: a conflicting typed query never changes the target" do
    SupportDesk.config.find_requester { |_query| @pedro }
    bea = create_user(name: "Bea", email: "bea@example.com")

    post "/madmin/support_tickets/open_conversation",
         params: { requester: bea.to_global_id.to_s, requester_query: "alice@example.com", body: "hola" }

    assert_response :see_other
    assert_equal bea, SupportDesk::Ticket.sole.requester
  end

  test "a GlobalID outside the registered classes resolves to nothing" do
    post "/madmin/support_tickets/open_conversation",
         params: { requester: @order.to_global_id.to_s, body: "hola" }

    assert_response :unprocessable_entity
    assert_select "#flash-alert", "That link doesn't point at anybody we can write to."

    # And the same the other way round: a subject has to be supportable.
    post "/madmin/support_tickets/open_conversation",
         params: { requester: @alice.to_global_id.to_s, about: @lucia.to_global_id.to_s, body: "hola" }

    assert_response :unprocessable_entity
    assert_select "#flash-alert", "That link doesn't point at anything we can open a conversation about."
    assert_equal 0, SupportDesk::Ticket.count
  end

  test "a subject somebody else owns is refused" do
    theirs = create_order(user: create_user(name: "Bea"))

    post "/madmin/support_tickets/open_conversation",
         params: { requester: @alice.to_global_id.to_s, about: theirs.to_global_id.to_s, body: "hola" }

    assert_response :unprocessable_entity
    assert_select "#flash-alert", "That link doesn't point at anything we can open a conversation about."
    assert_equal 0, SupportDesk::Ticket.count
  end

  test "a Hash where a string belongs is an input error, not a lookup" do
    post "/madmin/support_tickets/open_conversation",
         params: { requester: @alice.to_global_id.to_s, body: { evil: "yes" } }

    assert_response :unprocessable_entity
    assert_select "#flash-alert", "Something in the form didn't come through. Try again."

    get "/madmin/support_tickets/new", params: { requester: [ "gid://dummy/User/1" ] }

    assert_response :unprocessable_entity
    assert_equal 0, SupportDesk::Ticket.count
  end

  test "an agent can't open a support conversation with themselves" do
    post "/madmin/support_tickets/open_conversation",
         params: { requester: @lucia.to_global_id.to_s, body: "hola" }

    assert_response :unprocessable_entity
    assert_select "#flash-alert", /yourself/
    assert_equal 0, SupportDesk::Ticket.count
  end

  test "an off-duty agent gets a form with no send button, and a crafted POST writes nothing" do
    off_duty do
      get "/madmin/support_tickets/new", params: { requester: @alice.to_global_id.to_s }

      assert_response :success
      assert_select "#off_duty"
      assert_select "#send", false

      post "/madmin/support_tickets/open_conversation",
           params: { requester: @alice.to_global_id.to_s, body: "hola" }

      assert_response :unprocessable_entity
      assert_select "#flash-alert", "You're off duty, so you can't write to anybody right now."
    end

    assert_equal 0, SupportDesk::Ticket.count
  end

  # --- The host's policy, on the case this turned out to be ------------------------

  test "a host that allows writing but refuses THIS case writes nothing" do
    existing = @alice.ask_support!("no llega", about: @order)
    SupportDesk.config.authorize_console = lambda do |_agent, ticket, action|
      !(action == :reply && ticket&.id == existing.id)
    end

    post "/madmin/support_tickets/open_conversation",
         params: { requester: @alice.to_global_id.to_s, about: @order.to_global_id.to_s, body: "lo miramos" }

    assert_response :unprocessable_entity
    assert_equal 1, existing.reload.messages.where(kind: "text").count
    assert_predicate existing, :unassigned?, "a refusal takes no seat either"
  end

  test "and refuses the case this call lost the insert race to, just the same" do
    skip_unless_partial_indexes

    winner = @alice.ask_support!("no llega", about: @order)
    SupportDesk.config.authorize_console = ->(_agent, ticket, action) { !(action == :reply && ticket) }

    # The row the other request committed a millisecond ago wasn't visible to
    # our pre-check, so the INSERT is what catches it — and the authorization
    # hook still runs, under the winner's lock.
    original = SupportDesk::Ticket.method(:existing_for)
    checks = 0
    blind_once = lambda do |**arguments|
      checks += 1
      checks == 1 ? nil : original.call(**arguments)
    end

    SupportDesk::Ticket.stub(:existing_for, blind_once) do
      post "/madmin/support_tickets/open_conversation",
           params: { requester: @alice.to_global_id.to_s, about: @order.to_global_id.to_s, body: "lo miramos" }
    end

    assert_response :unprocessable_entity
    assert_equal 1, SupportDesk::Ticket.count
    assert_equal [ "no llega" ], winner.reload.messages.where(kind: "text").map(&:body)
  end

  test "a host authorization callback that raises fails closed" do
    @alice.ask_support!("no llega", about: @order)
    SupportDesk.config.authorize_console = lambda do |_agent, _ticket, action|
      raise "policy is down" if action == :reply

      true
    end

    post "/madmin/support_tickets/open_conversation",
         params: { requester: @alice.to_global_id.to_s, about: @order.to_global_id.to_s, body: "lo miramos" }

    assert_response :unprocessable_entity
    assert_equal 1, SupportDesk::Ticket.sole.messages.where(kind: "text").count
  end

  # --- Turbo ----------------------------------------------------------------------

  test "Turbo gets the same 303 to the case, and the same 422 form back" do
    turbo = { "Accept" => "text/vnd.turbo-stream.html, text/html, application/xhtml+xml" }

    post "/madmin/support_tickets/open_conversation",
         params: { requester: @alice.to_global_id.to_s, body: "Vimos que…" }, headers: turbo

    ticket = SupportDesk::Ticket.sole

    assert_response :see_other
    assert_redirected_to "/madmin/support_tickets/#{ticket.id}"

    post "/madmin/support_tickets/open_conversation",
         params: { requester: @alice.to_global_id.to_s, body: "" }, headers: turbo

    assert_response :unprocessable_entity
    assert_equal "text/html", response.media_type, "a stream refresh would throw the draft away"
    assert_select "#requester", "Alice"
  end

  test "the draft that comes back carries the desk, the topic, the query and the message" do
    SupportDesk.config.desk(:billing) { |desk| desk.name = "Billing" }
    SupportDesk.desk(:billing)
    SupportDesk.config.find_requester { |_query| nil }

    post "/madmin/support_tickets/open_conversation",
         params: { desk: "billing", requester_query: "nobody@example.com", topic: "account",
                   body: "un mensaje que no quiero volver a escribir" }

    assert_response :unprocessable_entity
    assert_select "h1", "Escribir por Billing"
    assert_select "#requester_query[value=?]", "nobody@example.com"
    assert_select "#body", "un mensaje que no quiero volver a escribir"
    assert_select "#topic option[selected][value=?]", "account"
    assert_select "#attachments_hint"
  end

  # --- Attachments -----------------------------------------------------------------

  test "an attachment rides along, and an attachment-only message is a message" do
    post "/madmin/support_tickets/open_conversation",
         params: { requester: @alice.to_global_id.to_s, body: "",
                   files: [ uploaded_png ] }

    ticket = SupportDesk::Ticket.sole
    message = ticket.messages.where(kind: "text").sole

    assert_response :see_other
    assert_predicate message.files, :attached?
    assert_equal @lucia, message.author
  end

  test "an attachment of a type this host does not take is a flash, and nothing is left behind" do
    # chats takes images only by default; a text file is the ordinary way an
    # agent trips this.
    note = Rack::Test::UploadedFile.new(StringIO.new("not an image"), "text/plain", original_filename: "note.txt")

    post "/madmin/support_tickets/open_conversation",
         params: { requester: @alice.to_global_id.to_s, body: "mira esto", files: [ note ] }

    assert_response :unprocessable_entity
    assert_equal 0, SupportDesk::Ticket.count
    assert_equal 0, Chats::Conversation.count
  end

  test "an attachment this host forbids is a flash, and nothing is left behind" do
    Chats.config.attachments = false

    post "/madmin/support_tickets/open_conversation",
         params: { requester: @alice.to_global_id.to_s, body: "mira esto", files: [ uploaded_png ] }

    assert_response :unprocessable_entity
    assert_equal 0, SupportDesk::Ticket.count
    assert_equal 0, Chats::Conversation.count
  end

  # --- Eligibility is a write rule -------------------------------------------------

  test "an account closed after the case was opened blocks the console's reply and keeps the transcript" do
    ticket = @alice.ask_support!("no llega", about: @order)
    ticket.reply!("lo miramos", by: @lucia)
    @alice.update!(support_blocked: true)

    post "/madmin/support_tickets/#{ticket.id}/reply", params: { body: "¿sigues ahí?" }

    assert_equal 2, ticket.reload.messages.where(kind: "text").count

    get "/madmin/support_tickets/#{ticket.id}"

    assert_response :success
    assert_match(/no llega/, response.body)
    assert_match(/lo miramos/, response.body)
  end

  private

  # The console asks `on_duty?` of the agent IT loaded, which is a
  # different object from the one this test holds — so the answer has to
  # change on the class.
  def off_duty
    User.define_method(:on_duty?) { false }
    yield
  ensure
    User.remove_method(:on_duty?)
  end

  def uploaded_png
    Rack::Test::UploadedFile.new(StringIO.new(ONE_PIXEL_PNG), "image/png", original_filename: "pixel.png")
  end
end
