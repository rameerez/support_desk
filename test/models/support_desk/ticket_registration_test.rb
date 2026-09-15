# frozen_string_literal: true

require "test_helper"

module SupportDesk
  # #register! is what keeps `awaiting`, the SLA clocks and reopen-on-reply
  # true. It hangs off chats' :message_created, so a message typed in the
  # app, mirrored in by email or posted by a bot all move the same clock.
  class TicketRegistrationTest < ActiveSupport::TestCase
    setup do
      @alice = create_user(name: "Alice")
      @lucia = create_agent(name: "Lucía")
      @ticket = ticket_for(@alice)
    end

    test "the opening message leaves the desk owing the next word" do
      assert_awaiting_reply @ticket
      assert_not_nil @ticket.last_requester_message_at
      assert_equal @ticket.last_requester_message_at, @ticket.waiting_since
      assert_nil @ticket.last_agent_message_at
    end

    test "an agent's answer flips awaiting and starts the first-reply clock" do
      message = @ticket.reply!("vamos", by: @lucia)
      @ticket.reload

      assert_awaiting_requester @ticket
      assert_equal message.created_at, @ticket.last_agent_message_at
      assert_equal message.created_at, @ticket.first_agent_reply_at
      assert_equal message.created_at, @ticket.waiting_since
    end

    test "the first-reply clock is only set once" do
      @ticket.reply!("una", by: @lucia)
      first = @ticket.reload.first_agent_reply_at
      @ticket.reply!("dos", by: @lucia)

      assert_equal first, @ticket.reload.first_agent_reply_at
    end

    test "a requester's next message flips it back" do
      @ticket.reply!("vamos", by: @lucia)
      @alice.message!(@ticket.conversation, "gracias, pero…")

      assert_awaiting_reply @ticket
    end

    test "system messages move nothing" do
      @ticket.reply!("vamos", by: @lucia)
      before = @ticket.reload.attributes.slice("awaiting", "waiting_since", "last_agent_message_at")

      @ticket.conversation.post_system_message!("Lucía se ocupa de tu consulta")

      after = @ticket.reload.attributes.slice("awaiting", "waiting_since", "last_agent_message_at")

      assert_equal before, after
    end

    test "register! is idempotent on the message id" do
      message = @ticket.reply!("vamos", by: @lucia)
      @ticket.reload

      assert_no_difference -> { @ticket.events.count } do
        3.times { @ticket.register!(message) }
      end

      assert_equal message.id.to_s, @ticket.reload.last_registered_message_id.to_s
    end

    test "a redelivered message never emits its event twice" do
      seen = []
      SupportDesk.on(:agent_replied) { |_ticket, message| seen << message.id }
      message = @ticket.reply!("vamos", by: @lucia)

      @ticket.reload.register!(message)

      assert_equal 1, seen.size
    end

    test "a requester writing into a closed ticket reopens it" do
      @ticket.reply!("vamos", by: @lucia)
      @ticket.close!(by: @lucia)

      @alice.message!(@ticket.conversation, "sigo con el problema")

      assert_open @ticket
      assert_equal 1, @ticket.reopen_count
      assert_awaiting_reply @ticket
      assert_ticket_event @ticket, :reopened
      assert_equal "requester_reply", @ticket.events.of_kind(:reopened).first.payload["via"]
    end

    test "reopening on a reply emits ticket_reopened" do
      @ticket.close!(by: @lucia)
      seen = []
      SupportDesk.on(:ticket_reopened) { |ticket, by:| seen << [ ticket.reference, by ] }

      @alice.message!(@ticket.conversation, "sigo")

      assert_equal [ [ @ticket.reference, @alice ] ], seen
    end

    test "closed_tickets :locked keeps a closed case closed" do
      SupportDesk.config.closed_tickets = :locked
      @ticket.close!(by: @lucia)

      assert_raises(ActiveRecord::RecordInvalid) { @alice.message!(@ticket.conversation, "hola?") }
      assert_closed @ticket
    end

    test "a reopened case goes back to whoever handled it" do
      @ticket.assign!(to: @lucia, by: @lucia)
      @ticket.close!(by: @lucia)

      @alice.message!(@ticket.conversation, "sigo")

      assert_assigned_to @ticket, @lucia
      assert_equal "reopened", @ticket.assignments.open.first.reason
    end

    test "a message from somebody who is neither party is treated as system noise" do
      stranger = create_user
      @ticket.conversation.add_participant!(stranger)
      before = @ticket.reload.awaiting

      stranger.message!(@ticket.conversation, "me colé")

      assert_equal before, @ticket.reload.awaiting
    end

    test "registration is what the queue's waiting clock reads" do
      @ticket.update!(waiting_since: 3.hours.ago)

      assert_includes Ticket.waiting_over(2.hours), @ticket

      @ticket.reply!("vamos", by: @lucia)

      assert_not_includes Ticket.waiting_over(2.hours), @ticket.reload
    end
  end
end
