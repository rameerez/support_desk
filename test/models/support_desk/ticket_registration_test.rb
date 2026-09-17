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

      assert_ticket_open @ticket
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
      assert_ticket_closed @ticket
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

    test "replaying an older message never rewinds the case" do
      old_message = @ticket.conversation.messages.order(:created_at).first
      @ticket.reply!("vamos", by: @lucia)
      before = @ticket.reload.attributes.slice("awaiting", "waiting_since", "last_requester_message_at",
                                               "last_agent_message_at")

      @ticket.register!(old_message)

      assert_equal before, @ticket.reload.attributes.slice("awaiting", "waiting_since",
                                                           "last_requester_message_at", "last_agent_message_at")
      assert_awaiting_requester @ticket
    end

    test "replaying the message that reopened a case doesn't reopen it twice" do
      @ticket.close!(by: @lucia)
      @alice.message!(@ticket.conversation, "sigo con el problema")
      reply = @ticket.conversation.messages.order(:created_at).last
      @ticket.reload.close!(by: @lucia)

      @ticket.register!(reply)

      assert_ticket_closed @ticket
      assert_equal 1, @ticket.reopen_count
      assert_equal 1, @ticket.events.of_kind(:reopened).count
    end

    test "an agent's parting word on a closed case doesn't resurrect it" do
      @ticket.close!(by: @lucia)

      @ticket.reply!("una última cosa", by: @lucia)

      assert_ticket_closed @ticket
      assert_equal "none", @ticket.reload.awaiting
      assert_nil @ticket.waiting_since
      assert_not_includes Ticket.awaiting_requester, @ticket
      assert_not_nil @ticket.last_agent_message_at, "the clocks still tell the truth"
    end

    test "maintenance survives a chats reset, because re-subscribing really subscribes" do
      Chats.reset!
      Chats.configure { |config| config.messager_class = "User" }
      SupportDesk.subscribe_to_chats!

      @ticket.reply!("vamos", by: @lucia)

      assert_awaiting_requester @ticket
    end

    test "registration is what the queue's waiting clock reads" do
      @ticket.update!(waiting_since: 3.hours.ago)

      assert_includes Ticket.waiting_over(2.hours), @ticket

      @ticket.reply!("vamos", by: @lucia)

      assert_not_includes Ticket.waiting_over(2.hours), @ticket.reload
    end
    # --- What registration must never fold in ------------------------------------

    test "system messages are never folded into the clocks" do
      @ticket.reply!("vamos", by: @lucia)
      before = clocks

      # Both ways in: the real chats path (which never delivers a system
      # message here at all) and a hand-written replay, which is where an
      # import or a console can still reach #register!.
      notice = @ticket.conversation.post_system_message!("Hemos vuelto a abrir esta conversación.")
      @ticket.reload.register!(notice)

      assert_equal before, clocks
      assert_not_equal notice.id.to_s, @ticket.reload.last_registered_message_id.to_s
    end

    test "a stranger's message leaves the clocks and the last-registered marker alone" do
      stranger = create_user
      @ticket.conversation.add_participant!(stranger)
      before = clocks

      message = stranger.message!(@ticket.conversation, "me colé")
      @ticket.reload.register!(message)

      assert_equal before, clocks
      assert_not_equal message.id.to_s, @ticket.reload.last_registered_message_id.to_s
    end

    test "the opening line never makes the first real message look like a reply" do
      SupportDesk.config.opening_line = "Has abierto una conversación sobre «%{label}»."
      ticket = nil

      events = capture_support_events(:requester_replied, :agent_replied, :ticket_opened) do
        ticket = create_user(name: "Bea").ask_support!("no me llega", topic: :account)
      end

      assert_equal [ :ticket_opened ], events.map(&:first)
      assert_equal %w[system text], ticket.messages.oldest_first.pluck(:kind)
      assert_equal ticket.messages.where(kind: "text").sole.created_at, ticket.last_requester_message_at
    end

    test "first_agent_reply_at waits for a requester message" do
      # The old API: a case opened with nothing said yet. An agent writing
      # into it is not answering anything, but it IS a reply — the requester
      # opened this one — so the desk still hears about it.
      empty = SupportDesk::Ticket.open!(requester: @alice, topic: :account)
      replied = []
      SupportDesk.on(:agent_replied) { |_ticket, message| replied << message.id }

      empty.reply!("¿en qué te ayudamos?", by: @lucia)

      assert_nil empty.reload.first_agent_reply_at
      assert_equal 1, replied.size

      ask_again empty, "pues mira"
      empty.reload.reply!("vamos a ello", by: @lucia)

      assert_equal empty.reload.last_agent_message_at, empty.first_agent_reply_at
    end

    test "replaying an agent message that is older than the requester's can't fabricate a first answer" do
      @ticket.reply!("vamos", by: @lucia)
      agent_message = @ticket.conversation.messages.where(kind: "text").order(:created_at).last
      @ticket.reload.update!(first_agent_reply_at: nil, last_agent_message_at: nil,
                             last_registered_message_id: nil)
      @ticket.update!(last_requester_message_at: agent_message.created_at + 1.minute)

      @ticket.register!(agent_message)

      assert_nil @ticket.reload.first_agent_reply_at
    end

    # --- The desk's own first word ------------------------------------------------

    test "the requester's first answer to outreach is a reply, and says so once" do
      bea = create_user(name: "Bea")
      ticket = @lucia.open_support_conversation_with!(bea, "Vimos que tu pedido no llegó")
      replied = []
      SupportDesk.on(:requester_replied) { |_ticket, message| replied << message.id }

      message = ask_again(ticket, "ah, no lo sabía")

      assert_equal [ message.id ], replied
      assert_awaiting_reply ticket
      # And a redelivery of the same message doesn't say it twice.
      ticket.reload.register!(message)

      assert_equal [ message.id ], replied
    end

    test "a message folded in inside the opening transaction is not folded in again after it" do
      ticket = @lucia.open_support_conversation_with!(create_user(name: "Bea"), "Vimos que…")
      message = ticket.messages.where(kind: "text").sole
      before = ticket.reload.attributes.slice("awaiting", "waiting_since", "last_agent_message_at",
                                              "last_registered_message_id", "updated_at")

      ticket.register!(message)

      assert_equal before, ticket.reload.attributes.slice("awaiting", "waiting_since", "last_agent_message_at",
                                                          "last_registered_message_id", "updated_at")
    end

    private

    def clocks
      @ticket.reload.attributes.slice("awaiting", "waiting_since", "last_requester_message_at",
                                      "last_agent_message_at", "first_agent_reply_at")
    end
  end
end
