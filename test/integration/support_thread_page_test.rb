# frozen_string_literal: true

require "test_helper"

# `config.thread_page = :support`: support as a place of its own. The host
# keeps support conversations out of its chats inbox (`inbox_scope`), and a
# case is read on this engine's ticket page, which renders chats' own thread.
#
# The dummy mounts this engine at /messages/support and chats at /messages,
# so the ticket page is /messages/support/tickets/T-…, and chats' endpoints
# the thread posts to are /messages/:id/….
class SupportThreadPageTest < ActionDispatch::IntegrationTest
  # What a host writes to keep support out of its inbox: a conversation about
  # nothing (a DM) has a NULL subject, so `where.not` alone would hide it too.
  WITHOUT_SUPPORT = lambda do |relation, _viewer|
    relation.where(subject_type: nil).or(relation.where.not(subject_type: "SupportDesk::Ticket"))
  end

  setup do
    SupportDesk.config.thread_page = :support
    Chats.config.inbox_scope = WITHOUT_SUPPORT

    @alice = create_user(name: "Alice", onboarded: true)
    @lucia = create_agent(name: "Lucía")
    @ticket = ticket_for(@alice, topic: :other, message: "My order never arrived")
  end

  test "the ticket page is chats' thread, with its way back leading to the support list" do
    reply_as @lucia, @ticket, "We are looking into it"
    login_as @alice

    get "/messages/support/tickets/#{@ticket.reference}"

    assert_response :success
    assert_no_missing_translations
    assert_select ".chats-thread .chats-message__text", text: "My order never arrived"
    assert_select ".chats-thread .chats-message__text", text: "We are looking into it"
    assert_select ".chats-thread__title", text: /Soporte/
    assert_select "a.chats-thread__back[href=?]", "/messages/support/"
    # Everything the thread talks to is chats', under chats' mount.
    assert_select "form[action=?]", "/messages/#{@ticket.conversation_id}/messages"
    assert_select "[data-chats--thread-read-url-value=?]", "/messages/#{@ticket.conversation_id}/read"
  end

  test "opening the page reads the case, and a hover prefetch does not" do
    reply_as @lucia, @ticket, "We are looking into it"
    login_as @alice
    unread = @alice.unread_support_count
    assert_operator unread, :>, 0

    get "/messages/support/tickets/#{@ticket.reference}", headers: { "X-Sec-Purpose" => "prefetch" }
    assert_response :success
    assert_equal unread, @alice.unread_support_count, "a pointer resting on a link is not somebody reading"

    get "/messages/support/tickets/#{@ticket.reference}"
    assert_equal 0, @alice.unread_support_count
  end

  test "the page reads the acknowledgement too, even when it was pinned a tick ahead of the clock" do
    with_support_config(acknowledgement: "Got it") do
      freeze_time do
        ticket = ticket_for(@alice, topic: :account, message: "Hello")
        login_as @alice
        get "/messages/support/tickets/#{ticket.reference}"

        assert_response :success
        assert_equal 0, ticket.conversation.participant_for(@alice).reload.unread_count
      end
    end
  end

  test "under the default thread page, chats' own thread shows the acknowledgement read, even with the clock frozen" do
    SupportDesk.config.thread_page = :chats
    Chats.config.inbox_scope = ->(relation, _viewer) { relation }
    with_support_config(acknowledgement: "Got it") do
      freeze_time do
        ticket = ticket_for(@alice, topic: :account, message: "Hello")
        login_as @alice
        get "/messages/#{ticket.conversation_id}"

        assert_response :success
        assert_select ".chats-thread", text: /Got it/
        assert_equal 0, ticket.conversation.participant_for(@alice).reload.unread_count
      end
    end
  end

  test "a layer of the host's that refuses a case on purpose is final" do
    controller = Chats::ApplicationController
    original = controller.instance_method(:find_conversation)
    original = original.super_method until original.owner == controller
    # The host's own find_conversation, as a class_eval would leave it: support_desk only adds a
    # lookup scope, so whatever this decides stands.
    controller.define_method(:find_conversation) do |id = params[:id]|
      raise ActiveRecord::RecordNotFound if SupportDesk::Ticket.exists?(conversation_id: id)

      original.bind_call(self, id)
    end
    controller.send(:private, :find_conversation)
    login_as @alice

    get "/messages/#{@ticket.conversation_id}"
    assert_response :not_found
    get "/messages/support/tickets/#{@ticket.reference}"
    assert_response :not_found, "the ticket page asks chats the same question"
  ensure
    controller.define_method(:find_conversation, original)
    controller.send(:private, :find_conversation)
  end

  test "a host that opens nothing for a viewer is final: support adds no scope beside none" do
    controller = Chats::ApplicationController
    # chats' own method, the one the class owns (support_desk's is prepended above it).
    original = controller.instance_method(:conversation_lookup_scopes)
    original = original.super_method until original.owner == controller
    # The host's own rule, as a class_eval would leave it: a suspended viewer opens nothing.
    controller.define_method(:conversation_lookup_scopes) { [] }
    controller.send(:protected, :conversation_lookup_scopes)
    login_as @alice

    get "/messages/#{@ticket.conversation_id}"
    assert_response :not_found
    post "/messages/#{@ticket.conversation_id}/messages", params: { message: { body: "hi" } }, as: :turbo_stream
    assert_response :not_found
    get "/messages/support/tickets/#{@ticket.reference}"
    assert_response :not_found
  ensure
    controller.define_method(:conversation_lookup_scopes, original)
    controller.send(:protected, :conversation_lookup_scopes)
  end

  test "the access is a lookup scope chats asks after its own, and nothing else" do
    login_as @alice
    get "/messages/#{@ticket.conversation_id}"
    assert_response :success
    scopes = @controller.send(:conversation_lookup_scopes)

    assert_equal 2, scopes.size
    assert_equal @ticket.conversation, scopes.last.find_by(id: @ticket.conversation_id)
    assert_nil scopes.first.find_by(id: @ticket.conversation_id), "precondition: the host's inbox hides it"
  end

  test "a case mislinked to a group or to another conversation opens nothing" do
    bob = create_user(name: "Bob")
    group = Chats::Conversation.create!(kind: "group", title: "Not support")
    group.add_participant!(@alice)
    group.add_participant!(bob)
    @ticket.update_columns(conversation_id: group.id)
    assert_nil SupportDesk::Ticket.requester_conversation(@alice, group.id)

    elsewhere = @alice.chat_with(bob)
    @ticket.update_columns(conversation_id: elsewhere.id)
    assert_nil SupportDesk::Ticket.requester_conversation(@alice, elsewhere.id)

    # And through chats: neither is reachable as a support case, under a scope that hides both.
    Chats.config.inbox_scope = ->(relation, _viewer) { relation.where.not(id: [ group.id, elsewhere.id ]) }
    login_as @alice
    get "/messages/#{elsewhere.id}"
    assert_response :not_found
  end

  test "a case mislinked to a group about that very case is no case page, even where the host's inbox lists it" do
    Chats.config.inbox_scope = ->(relation, _viewer) { relation } # the group is in her inbox
    group = Chats::Conversation.create!(kind: "group", title: "About the case", subject: @ticket)
    group.add_participant!(@alice)
    group.add_participant!(create_user(name: "Bob"))
    @ticket.update_columns(conversation_id: group.id)
    login_as @alice

    get "/messages/support/tickets/#{@ticket.reference}"

    assert_response :not_found
  end

  test "owning the case is not enough once the seat in its conversation is gone" do
    @ticket.conversation.participant_for(@alice).update_columns(left_at: Time.current)
    login_as @alice

    get "/messages/support/tickets/#{@ticket.reference}"

    assert_response :not_found
  end

  test "a case hidden from the inbox still answers its requester at every chats endpoint" do
    login_as @alice
    assert_empty @alice.chats.where(id: @ticket.conversation_id), "precondition: the inbox leaves support out"

    post "/messages/#{@ticket.conversation_id}/messages", params: { message: { body: "Any news?" } }, as: :turbo_stream
    assert_response :success
    assert_equal "Any news?", @ticket.conversation.messages.order(:created_at).last.body
    assert_predicate @ticket.reload, :awaiting_reply?

    post "/messages/#{@ticket.conversation_id}/read"
    assert_response :no_content

    get "/messages/#{@ticket.conversation_id}"
    assert_response :success
  end

  test "the fallback finds only your own case, and nothing the inbox hides for another reason" do
    bob = create_user(name: "Bob")
    login_as bob
    get "/messages/#{@ticket.conversation_id}"
    assert_response :not_found
    post "/messages/#{@ticket.conversation_id}/messages", params: { message: { body: "hi" } }, as: :turbo_stream
    assert_response :not_found

    # A conversation the host hides that is not a support case stays hidden.
    carol = create_user(name: "Carol")
    conversation = bob.chat_with(carol)
    Chats.config.inbox_scope = ->(relation, _viewer) { relation.where.not(id: conversation.id) }
    get "/messages/#{conversation.id}"
    assert_response :not_found
  end

  test "opening a case lands on its ticket page, and the list links there" do
    login_as @alice
    post "/messages/support/tickets", params: { topic: "other", message: "And another thing" }

    ticket = @alice.support_tickets.newest_first.first
    assert_redirected_to "/messages/support/tickets/#{ticket.reference}"

    get "/messages/support"
    assert_select "a.chats-row__link[href=?]", "/messages/support/tickets/#{ticket.reference}"
  end

  test "the page needs a signed-in requester, and somebody else's case is a 404" do
    get "/messages/support/tickets/#{@ticket.reference}"
    assert_response :unauthorized

    login_as create_user(name: "Bob")
    get "/messages/support/tickets/#{@ticket.reference}"
    assert_response :not_found
  end

  test "under :chats the ticket URL is still a redirect into the inbox's thread" do
    SupportDesk.config.thread_page = :chats
    Chats.config.inbox_scope = ->(relation, _viewer) { relation }
    login_as @alice

    get "/messages/support/tickets/#{@ticket.reference}"

    assert_redirected_to "/messages/#{@ticket.conversation_id}"
  end
end
