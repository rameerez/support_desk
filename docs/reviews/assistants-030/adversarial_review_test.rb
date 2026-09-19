require 'test_helper'

class AdversarialReviewTest < ActiveSupport::TestCase
  setup do
    @alice = create_user(name: 'Alice')
    @human = create_agent(name: 'Human')
    @rose = configure_assistant!(autonomy: :reply, responds_within: 60)
    @ticket = ticket_for(@alice, message: 'Question')
  end

  test 'equal timestamp messages allow an answer after both have been registered' do
    travel_to(1.minute.from_now.change(usec: 0)) do
      ask_again(@ticket, 'First')
      ask_again(@ticket, 'Second')
    end
    @ticket.reload
    @ticket.respond!('Answer to both', by: @rose, turn: @ticket.assistant_turn)
    assert_predicate @ticket.reload, :awaiting_requester?
  end

  test 'silent sweep rechecks a candidate after an answer wins the race' do
    @ticket.assign!(to: @rose, by: @human)
    @ticket.update!(waiting_since: 1.hour.ago)
    original = SupportDesk::Ticket.instance_method(:escalate!)
    ticket_id = @ticket.id
    human = @human
    SupportDesk::Ticket.define_method(:escalate!) do |**args|
      SupportDesk::Ticket.find(ticket_id).reply!('A human answered', by: human)
      original.bind_call(self, **args)
    end
    begin
      SupportDesk.release_silent_assistants!
      refute @ticket.reload.human_required?, 'sweep escalated a case that was already answered'
    ensure
      SupportDesk::Ticket.define_method(:escalate!, original)
    end
  end

  test 'deactivation releases held cases even with no silent timeout' do
    SupportDesk.config.assistant(:rose).responds_within = nil
    @ticket.assign!(to: @rose, by: @human)
    @rose.deactivate!(by: @human)
    SupportDesk.release_silent_assistants!
    assert @ticket.reload.unassigned?, 'inactive assistant retains case forever'
  end

  test 'redispatch repairs a committed requester message whose callback was lost' do
    SupportDesk::Ticket.stub(:for_conversation, nil) { ask_again(@ticket, 'New question') }
    @ticket.reload
    old_turn = @ticket.assistant_turn
    assert_raises(SupportDesk::StaleTurn) { @ticket.respond!('Old answer', by: @rose, turn: old_turn) }
    travel 10.minutes do
      SupportDesk.redispatch_assistant_turns!
    end
    refute_equal old_turn, @ticket.reload.assistant_turn, 'redispatch keeps retrying the same stale token forever'
  end
  test 'a stale assistant instance cannot take a case from a human' do
    stale = SupportDesk::Ticket.find(@ticket.id)
    @ticket.assign!(to: @human, by: @human)
    begin
      stale.assign!(to: @rose, by: @rose)
    rescue SupportDesk::AssistantNotAllowed
      # Correct refusal.
    end
    assert @ticket.reload.assigned_to?(@human), 'assistant stole the human seat using stale pre-lock checks'
  end

  test 'max turn escalation publishes the human alert event' do
    SupportDesk.config.assistant(:rose).max_turns = 1
    @ticket.respond!('First answer', by: @rose, turn: @ticket.assistant_turn)
    ask_again(@ticket, 'Still need help')
    @ticket.reload
    seen = []
    SupportDesk.on(:ticket_escalated) { |*args, **kwargs| seen << kwargs }
    result = @ticket.respond!('Last proposal', by: @rose, turn: @ticket.assistant_turn)
    assert_equal :max_turns, result.reason
    assert @ticket.reload.human_required?
    assert_equal 1, seen.size, 'max-turns handoff never notifies the host escalation subscriber'
  end

  test 'a committed kill switch is checked after waiting for the ticket lock' do
    @ticket.assign!(to: @rose, by: @human)
    original = @ticket.method(:with_lock)
    rose_id = @rose.id
    human = @human
    @ticket.define_singleton_method(:with_lock) do |*args, **kwargs, &block|
      SupportDesk::Assistant.find(rose_id).deactivate!(by: human)
      original.call(*args, **kwargs, &block)
    end
    result = nil
    begin
      result = @ticket.respond!('After kill switch', by: @rose, turn: @ticket.assistant_turn)
    rescue SupportDesk::NotAnAgent, SupportDesk::AssistantNotAllowed
    end
    refute result&.sent?, 'assistant wrote after deactivation committed while acquiring the case lock'
  end

  test 'removing config preserves historical disclosed signatures' do
    message = @ticket.respond!('Autonomous answer', by: @rose, turn: @ticket.assistant_turn).message
    signature = Chats.message_signature_for(message)
    SupportDesk.reset!
    configure_support_desk!
    assert_equal signature, Chats.message_signature_for(message.reload), 'flag off rewrites existing assistant disclosure'
  end

end
