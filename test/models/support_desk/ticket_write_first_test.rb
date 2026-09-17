# frozen_string_literal: true

require "test_helper"

module SupportDesk
  # The desk writing first, from the outside in: the direction the host's own
  # messaging policy is asked about, what a blank message does, what a failure
  # leaves behind, and the order the first two messages end up in.
  class TicketWriteFirstTest < ActiveSupport::TestCase
    setup do
      @alice = create_user(name: "Alice")
      @lucia = create_agent(name: "Lucía")
      @order = create_order(user: @alice, number: "SO1")
    end

    # --- The host's messaging policy ---------------------------------------------

    test "a conversation the desk opens is asked about as the desk writing, not as the requester" do
      # A host where strangers may not write to people, but the desk may
      # write to anyone: the shape every marketplace has, and the one a
      # symmetric pair identity gets wrong.
      Chats.config.can_message = ->(sender, _recipient) { sender.is_a?(SupportDesk::Desk) }

      ticket = @lucia.open_support_conversation_with!(@alice, "Vimos que tu pedido no llegó", about: @order)

      assert_predicate ticket, :opened_by_support?
      assert_raises(Chats::NotAllowedError) { @alice.ask_support!("y esto?", topic: :account) }
    end

    test "and the inverse host keeps working the inbound way round" do
      Chats.config.can_message = ->(sender, _recipient) { !sender.is_a?(SupportDesk::Desk) }

      assert_nothing_raised { @alice.ask_support!("no llega", about: @order) }
      assert_raises(Chats::NotAllowedError) do
        @lucia.open_support_conversation_with!(create_user(name: "Bea"), "Vimos que…")
      end
    end

    # --- What the desk has to say ------------------------------------------------

    test "the desk writing first with nothing to say writes nothing at all" do
      assert_no_difference [ -> { Ticket.count }, -> { Chats::Conversation.count } ] do
        assert_raises(ActiveRecord::RecordInvalid) { @lucia.open_support_conversation_with!(@alice, "  ") }
        assert_raises(ActiveRecord::RecordInvalid) { @lucia.open_support_conversation_with!(@alice, nil) }
      end
    end

    test "a blank reply into an existing case is refused the same way" do
      existing = @alice.ask_support!("no llega", about: @order)

      assert_raises(ActiveRecord::RecordInvalid) do
        @lucia.open_support_conversation_with!(@alice, "", about: @order)
      end

      assert_equal 1, existing.reload.messages.where(kind: "text").count
      assert_predicate existing, :unassigned?, "a refused reply takes no seat"
    end

    # --- Nothing left behind -----------------------------------------------------

    test "a caller who rescues the failure and commits its own transaction commits nothing of ours" do
      sentinel = nil

      ActiveRecord::Base.transaction do
        assert_raises(ActiveRecord::RecordInvalid) do
          @lucia.open_support_conversation_with!(@alice, "x" * (Chats.config.max_message_length + 1),
                                                 about: @order)
        end
        sentinel = create_user(name: "Sentinel")
      end

      assert_predicate sentinel.reload, :persisted?
      assert_equal 0, Ticket.count
      assert_equal 0, Chats::Conversation.count
      assert_equal 0, Chats::Participant.count
      assert_equal 0, Chats::Message.count
      assert_equal 0, Assignment.count
      assert_equal 0, Event.count
    end

    test "an attachment the host refuses rolls the case back too, and says nothing on the way out" do
      Chats.config.attachments = false
      events = []
      SupportDesk.on(:ticket_opened) { |ticket| events << ticket.id }

      ActiveRecord::Base.transaction do
        assert_raises(ActiveRecord::RecordInvalid) do
          @lucia.open_support_conversation_with!(@alice, "mira esto", files: [ attachment ])
        end
        create_user(name: "Sentinel")
      end

      assert_equal 0, Ticket.count
      assert_equal 0, Chats::Conversation.count
      assert_empty events
    end

    test "a reply into an existing case rolls back its drop-in as well as its message" do
      existing = create_user(name: "Bea").ask_support!("hola", topic: :account)
      pedro = create_agent(name: "Pedro")

      with_support_config(reply_policy: :take_over) do
        existing.assign!(to: pedro, by: pedro)

        assert_raises(ActiveRecord::RecordInvalid) do
          @lucia.open_support_conversation_with!(existing.requester,
                                                 "x" * (Chats.config.max_message_length + 1), topic: :account)
        end
      end

      assert_assigned_to existing, pedro
      assert_equal 1, existing.reload.assignments.count
      refute_ticket_event existing, :drop_in
    end

    test "losing the insert race and then failing leaves the winner's case exactly as it was" do
      skip_unless_partial_indexes

      winner = @alice.ask_support!("primera", about: @order)
      before = winner.reload.attributes.slice("awaiting", "waiting_since", "assignee_id",
                                              "last_registered_message_id")

      original = Ticket.method(:open_ticket_for)
      checks = 0
      blind_once = lambda do |**arguments|
        checks += 1
        checks == 1 ? nil : original.call(**arguments)
      end

      Ticket.stub(:open_ticket_for, blind_once) do
        assert_raises(ActiveRecord::RecordInvalid) do
          @lucia.open_support_conversation_with!(@alice, "x" * (Chats.config.max_message_length + 1),
                                                 about: @order)
        end
      end

      assert_equal 1, Ticket.count
      assert_equal before, winner.reload.attributes.slice("awaiting", "waiting_since", "assignee_id",
                                                          "last_registered_message_id")
      assert_equal [ "primera" ], winner.messages.where(kind: "text").map(&:body)
    end

    test "losing the insert race turns the desk's opener into a reply into the winner's case" do
      skip_unless_partial_indexes

      opened = []
      SupportDesk.on(:ticket_opened) { |ticket| opened << ticket.id }
      winner = @alice.ask_support!("primera", about: @order)

      original = Ticket.method(:open_ticket_for)
      checks = 0
      blind_once = lambda do |**arguments|
        checks += 1
        checks == 1 ? nil : original.call(**arguments)
      end

      loser = Ticket.stub(:open_ticket_for, blind_once) do
        @lucia.open_support_conversation_with!(@alice, "lo estamos mirando", about: @order)
      end

      assert_equal winner.id, loser.id
      assert_equal [ winner.id ], opened, "the loser announces nothing: it opened nothing"
      assert_predicate loser, :opened_by_requester?, "provenance stays the winner's"
      # It went in as an ordinary reply: the drop-in took the unheld case.
      assert_assigned_to winner, @lucia
      assert_equal "taken", winner.assignments.order(:assigned_at).last.reason
      assert_equal [ "primera", "lo estamos mirando" ],
                   winner.reload.messages.where(kind: "text").oldest_first.map(&:body)
    end

    # --- The order the thread reads in -------------------------------------------

    test "the opening line sorts above the message it introduces, even at frozen time" do
      SupportDesk.config.opening_line = "Has abierto una conversación sobre «%{label}»."

      travel_to Time.utc(2026, 9, 17, 12, 0, 0) do
        asked = @alice.ask_support!("no llega", about: @order)
        written = @lucia.open_support_conversation_with!(create_user(name: "Bea"), "Vimos que…")

        [ asked, written ].each do |ticket|
          notice, message = ticket.conversation.messages.oldest_first.to_a

          assert_equal %w[system text], [ notice.kind, message.kind ]
          # Strictly before, read back from the database: with UUID ids
          # there is nothing useful to break a tie with, so the timestamps
          # have to do the whole job themselves.
          assert_operator notice.reload.created_at, :<, message.reload.created_at
          assert_equal message.id, ticket.conversation.reload.last_message_id
          assert_equal message.created_at, ticket.conversation.last_message_at
        end
      end
    end

    test "a case opened with nothing to say still has its line, one tick before the clock" do
      SupportDesk.config.opening_line = :"support_desk.thread.opened_by_support"

      travel_to Time.utc(2026, 9, 17, 12, 0, 0) do
        ticket = Ticket.open!(requester: @alice, topic: :account)
        notice = ticket.conversation.messages.sole

        assert_equal "system", notice.kind
        assert_operator notice.reload.created_at, :<, ticket.opened_at
        assert_equal "agent", ticket.awaiting
        assert_equal ticket.opened_at, ticket.waiting_since

        # And the first reply still lands after it.
        message = ticket.reply!("¿en qué te ayudamos?", by: @lucia)

        assert_operator notice.reload.created_at, :<, message.created_at
      end
    end

    private

    # An ActiveStorage upload the way a controller hands one over.
    def attachment
      ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("not a real image"), filename: "note.txt", content_type: "text/plain"
      ).signed_id
    end
  end
end
