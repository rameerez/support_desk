# frozen_string_literal: true

require "test_helper"

class RequesterIntegrityTest < ActionDispatch::IntegrationTest
  test "requester upload form actually posts file bytes" do
    user = create_user
    login_as user
    get "/messages/support/new", params: { topic: "other" }
    assert_response :success
    assert_select "form input[type=file]"
    assert_select "form[enctype='multipart/form-data']", count: 1
  end

  test "rehydrated topic is resolved from its ticket desk" do
    user = create_user
    SupportDesk.config.topics { other label: "General support" }
    SupportDesk.config.desk(:billing) { |d| d.topics { other label: "Private billing" } }
    ticket = SupportDesk::Ticket.open!(requester: user, message: "Help", topic: :other, desk: SupportDesk.desk(:billing))
    assert_equal "Private billing", SupportDesk::Ticket.find(ticket.id).topic.label
  end

  test "a nondefault wizard files on its own desk and shows that desk's promise" do
    user = create_user
    SupportDesk.config.desk(:billing) do |desk|
      desk.topics { other label: "Private billing" }
      desk.reply_within = 1.hour
    end
    desk = SupportDesk.desk(:billing)
    wizard = SupportDesk::Wizard.new(user, { topic: "other" }, desk: desk)
    assert_equal desk, wizard.target_desk
    assert_equal 1.hour, wizard.promise_within
    ticket = wizard.open!("Billing question")
    assert_equal desk, ticket.reload.desk
    assert_equal "Private billing", ticket.topic.label
  end

  test "support and ordinary chat share the same sender budget" do
    user = create_user
    login_as user
    ticket = user.ask_support!("Help", topic: :other)
    controllers = [ SupportDesk::TicketsController, Chats::MessagesController ]
    stores = controllers.map(&:cache_store)
    store = ActiveSupport::Cache::MemoryStore.new
    controllers.each { |controller| controller.cache_store = store }
    Chats.config.send_rate_limit = { to: 2, within: 1.minute }

    post "/messages/#{ticket.conversation.id}/messages", params: { message: { body: "One" } }
    assert_response :redirect
    post "/messages/support/tickets", params: { topic: "other", message: "Two" }
    assert_response :redirect
    post "/messages/#{ticket.conversation.id}/messages", params: { message: { body: "Three" } }
    assert_response :too_many_requests
    post "/messages/support/tickets", params: { topic: "other", message: "Four" }
    assert_response :too_many_requests
  ensure
    controllers&.zip(stores)&.each { |controller, previous| controller.cache_store = previous }
  end
end
