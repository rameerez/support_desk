# frozen_string_literal: true

require "test_helper"

module SupportDesk
  class TicketRevocationTest < ActiveSupport::TestCase
    test "stale revoked and deleted agents cannot open reuse reply or assign" do
      %i[revoke delete].each do |change|
        agent = create_agent
        requester = create_user
        existing = requester.ask_support!("question", topic: :other)
        change == :revoke ? User.find(agent.id).update!(admin: false) : User.where(id: agent.id).delete_all
        counts = [ Ticket, Assignment, Event, Chats::Message, Chats::Conversation ].map { |model| -> { model.count } }

        [
          -> { agent.open_support_conversation_with!(requester, "new", topic: :account) },
          -> { agent.open_support_conversation_with!(requester, "reuse", topic: :other) },
          -> { existing.reply!("reply", by: agent) },
          -> { existing.assign!(to: agent, by: create_agent) }
        ].each do |operation|
          assert_no_difference counts do
            assert_raises(NotAnAgent, &operation)
          end
        end
        assert_predicate existing.reload, :unassigned?
      end
    end

    test "legacy NULL provenance preserves requester quotas and reply metrics before backfill" do
      requester = create_user
      ticket = requester.ask_support!("question", topic: :other)
      ticket.update_columns(opened_by_type: nil, opened_by_id: nil)
      SupportDesk.config.max_open_tickets = 1
      assert_raises(TooManyOpenTickets) { requester.ask_support!("second", topic: :account) }
      SupportDesk.config.max_open_tickets = nil
      SupportDesk.config.open_rate_limit = { to: 1, within: 1.hour }
      assert_raises(RateLimited) { requester.ask_support!("second", topic: :account) }
      travel 1.minute do
        ticket.reply!("answer", by: create_agent)
      end
      assert_in_delta 60, ticket.reload.time_to_first_reply, 1
      assert_predicate ticket, :opened_by_requester?
      assert_nil ticket.opened_by
    end
  end
end
