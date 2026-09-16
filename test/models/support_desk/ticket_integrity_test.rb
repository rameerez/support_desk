# frozen_string_literal: true

require "test_helper"

class TicketIntegrityTest < ActiveSupport::TestCase
  setup do
    @requester = create_user
    @agent = create_agent
    @ticket = ticket_for(@requester, topic: :other)
  end

  test "a rejected opening message rolls back the ticket and all of its events" do
    opened = []
    SupportDesk.on(:ticket_opened) { |ticket| opened << ticket.id }
    counts = -> { [ SupportDesk::Ticket.count, SupportDesk::Event.count, Chats::Conversation.count ] }
    before = counts.call
    assert_raises(ActiveRecord::RecordInvalid) do
      @requester.ask_support!("x" * (Chats.config.max_message_length + 1), topic: :account)
    end
    assert_equal before, counts.call
    assert_empty opened
  end

  test "reopening older history preserves both active conversations and notifies agents" do
    @ticket.close!(by: @agent)
    newer = @requester.ask_support!("Another problem", topic: :other)
    replies = []
    SupportDesk.on(:requester_replied) { |ticket, message| replies << [ ticket.id, message.id ] }
    message = @requester.message!(@ticket.conversation, "This still needs help")
    assert_predicate @ticket.reload, :open?
    assert_predicate newer.reload, :open?
    assert_includes replies, [ @ticket.id, message.id ]
    assert_equal 2, @requester.support_tickets.not_closed.count
    assert_includes [ @ticket.id, newer.id ], @requester.ask_support!("A followup", topic: :other).id
    assert_equal 2, @requester.support_tickets.not_closed.count
  end

  test "manual reopening also preserves newer history" do
    @ticket.close!(by: @agent)
    newer = @requester.ask_support!("New case", topic: :other)
    @ticket.reopen!(by: @agent)
    assert_predicate @ticket.reload, :open?
    assert_predicate newer.reload, :open?
  end

  test "a reopened case is reused by the wizard and a new submission" do
    @ticket.close!(by: @agent)
    @ticket.reopen!(by: @requester)
    wizard = SupportDesk::Wizard.new(@requester, { topic: "other" })
    assert_equal @ticket, wizard.existing_ticket
    assert_equal @ticket, @requester.ask_support!("Followup", topic: :other)
  end

  test "assignment checks the actor as well as the recipient" do
    assert_raises(SupportDesk::NotAnAgent) { @ticket.assign!(to: @agent, by: @requester) }
    assert_empty @ticket.assignments
  end

  test "stale state cannot assign or release a closed case" do
    stale = SupportDesk::Ticket.find(@ticket.id)
    @ticket.close!(by: @agent)
    assert_raises(SupportDesk::InvalidTransition) { stale.assign!(to: @agent, by: @agent) }
    assert_raises(SupportDesk::InvalidTransition) { stale.release!(by: @agent) }
    assert_empty @ticket.assignments.open
  end

  test "stale assignees cannot answer or hand off after reassignment" do
    @ticket.assign!(to: @agent, by: @agent)
    stale = SupportDesk::Ticket.find(@ticket.id)
    replacement = create_agent
    @ticket.assign!(to: replacement, by: replacement)
    SupportDesk.config.reply_policy = :assignee_only
    assert_raises(SupportDesk::NotAllowed) { stale.reply!("Too late", by: @agent) }
    assert_raises(SupportDesk::NotTheAssignee) { stale.hand_off!(to: @agent, by: @agent) }
    assert_equal replacement, @ticket.reload.assignee
  end

  test "delayed requester registration cannot reverse a newer answer" do
    delayed = nil
    travel 1.second do
      SupportDesk::Ticket.stub(:for_conversation, nil) do
        delayed = @requester.message!(@ticket.conversation, "Earlier followup")
      end
    end
    travel 2.seconds do
      @ticket.reply!("Answer", by: @agent)
    end
    @ticket.reload.register!(delayed)
    assert_predicate @ticket.reload, :awaiting_requester?
    assert_equal @ticket.last_agent_message_at, @ticket.waiting_since
  end

  test "a delayed message sent before closure cannot reopen the case" do
    delayed = nil
    travel 1.second do
      SupportDesk::Ticket.stub(:for_conversation, nil) do
        delayed = @requester.message!(@ticket.conversation, "Earlier followup")
      end
    end
    travel 2.seconds do
      @ticket.close!(by: @agent)
    end
    @ticket.register!(delayed)
    assert_predicate @ticket.reload, :closed?
    assert_equal "none", @ticket.awaiting
    assert_nil @ticket.waiting_since
  end
end
