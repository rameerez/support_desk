require 'test_helper'
require 'timeout'

class AdversarialConcurrencyReviewTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test 'a requester commit after reconciliation prevents a stale answer' do
    alice = create_user(name: 'Race Alice')
    rose = configure_assistant!(autonomy: :reply)
    ticket = ticket_for(alice, message: 'Original question')
    held = ticket.assistant_turn
    committed = Queue.new
    finish_callback = Queue.new
    original = SupportDesk::Ticket.instance_method(:reconcile_unregistered_messages!)
    writer = nil
    SupportDesk::Ticket.define_method(:reconcile_unregistered_messages!) do
      original.bind_call(self)
      writer = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          # Pause the after-commit host notification, not the message write.
          Chats::Message.transaction do
            msg = User.find(alice.id).message!(Chats::Conversation.find(ticket.conversation_id), 'New question')
            msg.define_singleton_method(:notify_host) do
              committed << true
              finish_callback.pop
              super()
            end
          end
        end
      end
      Timeout.timeout(8) { committed.pop }
    end
    begin
      result = ticket.respond!('Answer based on old question', by: rose, turn: held)
    ensure
      finish_callback << true
      writer&.join(10)
      SupportDesk::Ticket.define_method(:reconcile_unregistered_messages!, original)
    end
    messages = ticket.conversation.messages.where(kind: 'text').order(:created_at, :id).pluck(:body)
    puts "RACE MESSAGE ORDER: #{messages.inspect}"
    assert_includes messages, "New question", "barrier must actually execute"
    refute result&.sent?, 'assistant answered after the unseen requester message committed'
  end
  test 'a requester commit after reconciliation prevents an unseen draft approval' do
    alice = create_user(name: 'Race Alice')
    rose = configure_assistant!(autonomy: :reply)
    ticket = ticket_for(alice, message: 'Original question')
    human = create_agent(name: 'Reviewer')
    draft = ticket.draft!('Proposed answer', by: rose, turn: ticket.assistant_turn)
    ticket = draft.ticket
    held = ticket.assistant_turn
    committed = Queue.new
    finish_callback = Queue.new
    original = SupportDesk::Ticket.instance_method(:reconcile_unregistered_messages!)
    writer = nil
    SupportDesk::Ticket.define_method(:reconcile_unregistered_messages!) do
      original.bind_call(self)
      writer = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          # Pause the after-commit host notification, not the message write.
          Chats::Message.transaction do
            msg = User.find(alice.id).message!(Chats::Conversation.find(ticket.conversation_id), 'New question')
            msg.define_singleton_method(:notify_host) do
              committed << true
              finish_callback.pop
              super()
            end
          end
        end
      end
      Timeout.timeout(8) { committed.pop }
    end
    begin
      result = draft.send!(by: human, seen_turn: held)
    ensure
      finish_callback << true
      writer&.join(10)
      SupportDesk::Ticket.define_method(:reconcile_unregistered_messages!, original)
    end
    messages = ticket.conversation.messages.where(kind: 'text').order(:created_at, :id).pluck(:body)
    puts "RACE MESSAGE ORDER: #{messages.inspect}"
    assert_includes messages, "New question", "barrier must actually execute"
    assert_nil result, 'reviewer sent a draft without seeing the committed new requester message'
  end
end
