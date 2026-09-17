# frozen_string_literal: true

require "test_helper"

class ConsoleConversationInputsTest < ActionDispatch::IntegrationTest
  setup do
    @requester = create_user(name: "Alice")
    @agent = create_agent
    SupportDesk.desk
    login_as @agent
  end

  test "malformed uploads refuse new and reused cases without losing the draft or mutating anything" do
    [ false, true ].each do |reuse|
      @requester.ask_support!("question", topic: :other) if reuse
      [ { bad: "input" }, [ {} ], [ [] ], [ { bad: "input" } ], [ [ "nested" ] ], [ "invalid-signed-blob" ] ].each do |files|
        assert_no_difference counts do
          post "/madmin/support_tickets/open_conversation", params: draft.merge(files: files), as: :json
        end
        assert_response :unprocessable_entity
        assert_select "#body", "A draft to preserve"
        assert_select "#requester", "Alice"
        assert_select "#topic option[selected][value=other]"
      end
    end
  end

  test "valid signed blobs work and missing blobs are input refusals" do
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("hello"), filename: "note.txt", content_type: "text/plain")
    token = blob.signed_id
    Chats.config.attachments = :any
    post "/madmin/support_tickets/open_conversation", params: draft.merge(body: "", files: [ token ])
    assert_response :see_other
    assert_equal blob, SupportDesk::Ticket.sole.messages.where(kind: "text").sole.files.sole.blob

    # A once-valid direct-upload token can outlive its blob.
    missing = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("gone"), filename: "gone.txt")
    token = missing.signed_id
    missing.purge
    assert_no_difference counts do
      post "/madmin/support_tickets/open_conversation", params: draft.merge(files: [ token ])
    end
    assert_response :unprocessable_entity
  end

  test "an explicitly unavailable desk never becomes the default sender" do
    SupportDesk.config.desk(:billing) { |desk| desk.name = "Billing" }
    SupportDesk.desk(:billing)
    SupportDesk.config.visible_desks_for = ->(_agent) { [ :default ] }
    [ "billing", "removed", "", { billing: "yes" }, [ "billing" ] ].each do |desk|
      assert_no_difference counts do
        post "/madmin/support_tickets/open_conversation", params: draft.merge(desk: desk)
      end
      assert_response :unprocessable_entity
      assert_select "#body", "A draft to preserve"
      assert_select "#send", false
    end
  end

  test "malformed scalar fields preserve the other valid draft fields" do
    %i[topic requester_query].each do |field|
      post "/madmin/support_tickets/open_conversation", params: draft.merge(field => { bad: "input" })
      assert_response :unprocessable_entity
      assert_select "#body", "A draft to preserve"
      assert_select "#requester", "Alice"
    end
  end

  test "missing token classes are refused but host lookup bugs propagate" do
    post "/madmin/support_tickets/open_conversation", params: draft.merge(requester: "gid://#{GlobalID.app}/NeverDeclaredRequester/1")
    assert_response :unprocessable_entity
    [ NameError, NoMethodError, ArgumentError ].each do |error|
      User.stub(:find, ->(*) { raise error, "host finder failed" }) do
        assert_raises(error) { post "/madmin/support_tickets/open_conversation", params: draft }
      end
    end
  end

  test "an unavailable recipient is explained on GET without offering send" do
    @requester.update!(support_blocked: true)
    get "/madmin/support_tickets/new", params: draft
    assert_response :unprocessable_entity
    assert_select "#requester", "Alice"
    assert_select "#flash-alert", "That account can't receive support messages."
    assert_select "#send", false
  end

  private

  def draft
    { requester: @requester.to_global_id.to_s, topic: "other", body: "A draft to preserve" }
  end

  def counts
    [ SupportDesk::Ticket, SupportDesk::Assignment, SupportDesk::Event, Chats::Message, Chats::Conversation ].map do |model|
      -> { model.count }
    end
  end
end
