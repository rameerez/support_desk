# frozen_string_literal: true

require "test_helper"

module SupportDesk
  # `has_support_tickets if:` is a WRITE rule, not a screen rule. A closed
  # account can't ask and can't be written to, and everything that already
  # happened stays exactly where it is: the transcript, the notes, the events
  # and the row in the queue.
  class TicketEligibilityTest < ActiveSupport::TestCase
    setup do
      @alice = create_user(name: "Alice")
      @lucia = create_agent(name: "Lucía")
      @ticket = @alice.ask_support!("no me llega", topic: :account)
      @ticket.reply!("lo estamos mirando", by: @lucia)
    end

    test "an account closed after the case was opened stops every way of writing into it" do
      @alice.update!(support_blocked: true)

      # The console's way in…
      assert_raises(Locked) { @ticket.reload.reply!("¿sigues ahí?", by: @lucia) }
      # …the desk writing first into the same case…
      assert_raises(NotARequester) { @lucia.open_support_conversation_with!(@alice, "¿sigues ahí?") }
      # …and chats directly, from either seat.
      assert_raises(ActiveRecord::RecordInvalid) { @alice.message!(@ticket.conversation, "hola?") }
      assert_raises(ActiveRecord::RecordInvalid) do
        @ticket.desk.message!(@ticket.conversation, "hola?", author: @lucia)
      end

      assert_equal 2, @ticket.reload.messages.where(kind: "text").count
    end

    test "and leaves the case readable, listed, and closeable" do
      @alice.update!(support_blocked: true)
      @ticket.reload

      assert_equal [ "no me llega", "lo estamos mirando" ],
                   @ticket.messages.where(kind: "text").oldest_first.map(&:body)
      assert_includes Ticket.awaiting_requester, @ticket
      assert_includes @ticket.export[:messages].map { |message| message[:body] }, "lo estamos mirando"
      assert_nothing_raised { @ticket.summary.to_s }

      # Lifecycle notices are still allowed through — chats exempts system
      # messages from the lock precisely so a closed case can say so.
      assert_nothing_raised { @ticket.conversation.post_system_message!("Hemos cerrado esta conversación.") }

      actions = @ticket.actions_for(@lucia)

      assert_not_includes actions, :reply
      assert_includes actions, :note
      assert_includes actions, :close
      assert_nothing_raised { @ticket.note!("cuenta cerrada", by: @lucia) }
      assert_nothing_raised { @ticket.close!(by: @lucia) }
    end

    test "the notice says which of the two reasons it is" do
      assert_not_predicate @ticket, :chat_locked?

      @alice.update!(support_blocked: true)

      assert_predicate @ticket, :chat_locked?
      assert_equal I18n.t("support_desk.thread.unavailable_notice"), @ticket.chat_locked_notice

      # An unavailable requester outranks a closed case: it is the truer
      # reason, and the one the refusal gives too.
      @alice.update!(support_blocked: false)
      SupportDesk.config.closed_tickets = :locked
      @ticket.close!(by: @lucia)

      assert_equal I18n.t("support_desk.thread.closed_notice"), @ticket.chat_locked_notice

      @alice.update!(support_blocked: true)

      assert_equal I18n.t("support_desk.thread.unavailable_notice"), @ticket.chat_locked_notice
    end

    test "eligibility is re-read, never remembered" do
      # The association is loaded BEFORE the account closes, which is the
      # state a long-lived request or a preloaded queue row is really in.
      @ticket.requester

      User.find(@alice.id).update!(support_blocked: true)

      assert_predicate @ticket, :requester_unavailable?
      assert_raises(Locked) { @ticket.reply!("¿sigues ahí?", by: @lucia) }
    end

    test "a requester whose record is gone is unavailable for writes and readable for everything else" do
      @ticket.update_columns(requester_id: 0)
      @ticket.reload

      assert_predicate @ticket, :requester_unavailable?
      assert_raises(Locked) { @ticket.reply!("¿hola?", by: @lucia) }
      assert_nothing_raised { @ticket.summary.to_s }
      assert_equal 2, @ticket.messages.where(kind: "text").count
    end

    test "a requester class that never declared the macro has no opinion to honour" do
      assert_not_predicate @ticket, :requester_unavailable?

      # An Order is not a requester model; a row that points at one (an
      # import, a legacy host) reads as available rather than crashing.
      @ticket.update_columns(requester_type: "Order", requester_id: create_order(user: @alice).id)

      assert_not_predicate @ticket.reload, :requester_unavailable?
    end
  end
end
