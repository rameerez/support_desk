# frozen_string_literal: true

require "test_helper"

class RegistrationRegressionTest < ActiveSupport::TestCase
  setup do
    @alice = create_user(name: "Alice")
    @human = create_agent(name: "Human")
    @rose = configure_assistant!(autonomy: :resolve)
    @ticket = ticket_for(@alice, message: "Question")
  end

  test "recovery reopens a closed case with an unregistered requester reply" do
    @ticket.close!(by: @human)
    SupportDesk::Ticket.stub(:for_conversation, nil) { ask_again(@ticket, "Still broken") }
    SupportDesk.redispatch_assistant_turns!
    assert @ticket.reload.open?, "committed requester reply remains on a closed case forever"
  end

  test "a new lower ordered tied message still invalidates the observed turn" do
    travel_to(1.minute.from_now.change(usec: 0)) do
      @ticket.conversation.messages.create!(id: 90002, sender: @alice, body: "First commit")
      seen = @ticket.reload.assistant_turn
      @ticket.conversation.messages.create!(id: 90001, sender: @alice, body: "Second commit needs a human")
      refute_equal seen, @ticket.reload.assistant_turn, "new committed input is mistaken for replay"
    end
  end

  test "public release cannot bypass turn check with internal current sentinel" do
    @ticket.assign!(to: @rose, by: @human)
    ask_again(@ticket, "Case changed")
    assert_raises(SupportDesk::StaleTurn, ArgumentError) do
      @ticket.release!(by: @rose, turn: :current)
    end
  end

  test "switching disclosure mode preserves old message disclosure" do
    message = @ticket.respond!("Answer", by: @rose, turn: @ticket.assistant_turn).message
    before = Chats.message_signature_for(message)
    SupportDesk.config.assistant(:rose).disclosure = :none
    SupportDesk.assistant(:rose)
    assert_equal before, Chats.message_signature_for(message.reload)
  end

  test "flag off still registers each new requester message and notification" do
    SupportDesk.reset!
    configure_support_desk!
    SupportDesk.subscribe_to_chats!
    replies = []
    SupportDesk.on(:requester_replied) { |*args| replies << args }
    travel_to(1.minute.from_now.change(usec: 0)) do
      @ticket.conversation.messages.create!(id: 91002, sender: @alice, body: "First commit")
      @ticket.conversation.messages.create!(id: 91001, sender: @alice, body: "Second commit")
    end
    assert_equal 2, replies.size, "flag-off mode drops the second requester notification too"
  end

  test "an unseen earlier timestamp invalidates the turn without rewinding clocks" do
    @ticket.respond!("First answer", by: @rose, turn: @ticket.assistant_turn)
    @ticket.reload
    clock = @ticket.last_requester_message_at
    seen = @ticket.assistant_turn
    message = @ticket.conversation.messages.create!(sender: @alice, body: "Late input",
                                                     created_at: clock - 1.second)
    @ticket.reload
    refute_equal seen, @ticket.assistant_turn
    assert_equal clock, @ticket.last_requester_message_at
    assert @ticket.awaiting_reply?
    after = @ticket.assistant_turn
    @ticket.register!(message)
    assert_equal after, @ticket.reload.assistant_turn
  end

  test "a late tied phrase requests a human exactly once" do
    SupportDesk.config.assistant(:rose).hand_off_when = ->(_ticket, message) { message.body == "human please" }
    events = []
    SupportDesk.on(:human_requested) { |*args, **kwargs| events << kwargs }
    travel_to(1.minute.from_now.change(usec: 0)) do
      @ticket.conversation.messages.create!(id: 92002, sender: @alice, body: "First")
      message = @ticket.conversation.messages.create!(id: 92001, sender: @alice, body: "human please")
      @ticket.reload.register!(message)
    end
    assert @ticket.reload.human_required?
    assert_equal 1, events.size
  end

  test "repairing a locked closed case records the input without reopening or dispatch" do
    SupportDesk.config.closed_tickets = :locked
    @ticket.close!(by: @human)
    # Simulate a committed imported message whose registration was lost.
    message = Chats::Message.new(conversation: @ticket.conversation, sender: @alice, body: "human please")
    SupportDesk::Ticket.stub(:for_conversation, nil) { message.save!(validate: false) }
    turns = []
    SupportDesk.on(:assistant_turn) { |*args, **kwargs| turns << kwargs }
    SupportDesk.redispatch_assistant_turns!
    assert @ticket.reload.closed?
    assert @ticket.message_registrations.exists?(message_id: message.id)
    assert_empty turns
  end

  test "registration receipts roll back with a failed operation" do
    message = nil
    before = @ticket.message_registrations.count
    @ticket.with_lock do
      message = ask_again(@ticket, "rolled back")
      @ticket.send(:record_registration!, message)
      raise ActiveRecord::Rollback
    end
    assert_equal before, @ticket.message_registrations.count
    refute Chats::Message.exists?(message.id)
  end

  test "public assistant reply and assignment reject the internal sentinel" do
    assert_raises(SupportDesk::StaleTurn) { @ticket.reply!("late", by: @rose, turn: :current) }
    assert_raises(SupportDesk::StaleTurn) { @ticket.assign!(to: @rose, by: @rose, turn: :current) }
    assert @ticket.reload.unassigned?
  end

  test "human and human-approved draft signatures remain human" do
    draft = @ticket.draft!("Proposal", by: @rose, turn: @ticket.assistant_turn)
    message = draft.send!(by: @human, seen_turn: @ticket.reload.assistant_turn)
    expected = I18n.t("chats.message.signature", name: Chats.display_name_for(@human))
    assert_equal expected, Chats.message_signature_for(message)
    assert_equal expected, Chats.message_signature_for(@ticket.reply!("Human", by: @human))
  end

  test "host custom signature hook is honored and legacy snapshots survive flag off" do
    message = @ticket.respond!("Answer", by: @rose, turn: @ticket.assistant_turn).message
    before = Chats.message_signature_for(message)
    @rose.update_columns(settings: {}) # a 0.3.0 row without the 0.3.1 row snapshot
    SupportDesk.reset!
    configure_support_desk!
    assert_equal before, Chats.message_signature_for(message.reload)
    Chats.config.message_signature = ->(_message) { "Custom signature" }
    assert_equal "Custom signature", Chats.message_signature_for(message)
  end
end
