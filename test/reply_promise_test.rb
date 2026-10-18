# frozen_string_literal: true

require "test_helper"

# The answer promise a requester reads (`reply_within`), and the line that
# answers "did that go through?" under their first message
# (`acknowledgement`).
class ReplyPromiseTest < ActiveSupport::TestCase
  setup do
    @alice = create_user(name: "Alice", onboarded: true)
    @lucia = create_agent(name: "Lucía")
  end

  # --- The promise, in its own unit ---------------------------------------------

  test "a promise is said in the unit the desk wrote it in" do
    I18n.with_locale(:en) do
      assert_equal "72 hours", SupportDesk.humanize_promise(72.hours)
      assert_equal "3 days", SupportDesk.humanize_promise(3.days)
      assert_equal "1 hour", SupportDesk.humanize_promise(1.hour)
      assert_equal "90 minutes", SupportDesk.humanize_promise(90.minutes)
      # The default is stored in seconds, and a day of them is a day.
      assert_equal "1 day", SupportDesk.humanize_promise(ActiveSupport::Duration.build(24 * 60 * 60))
    end

    I18n.with_locale(:es) { assert_equal "72 horas", SupportDesk.humanize_promise(72.hours) }
  end

  test "a promise no single unit says is said the way a wait is" do
    I18n.with_locale(:en) do
      assert_equal SupportDesk.humanize_duration(1.day + 2.hours), SupportDesk.humanize_promise(1.day + 2.hours)
      assert_equal SupportDesk.humanize_duration(1.5.hours), SupportDesk.humanize_promise(1.5.hours)
    end
  end

  test "the door, the composer and every line that promises say the same thing" do
    with_support_config(reply_within: 72.hours) do
      I18n.with_locale(:en) do
        promise = "We usually reply in under 72 hours"

        assert_equal promise, SupportDesk.config.desk.reply_promise
        assert_equal promise, SupportDesk::Wizard.new(@alice, { topic: "other" }).promise

        ticket = ticket_for(@alice, topic: :other)
        assert_equal "72 hours", SupportDesk.config.desk.line_interpolations(ticket)[:reply_within]
      end
    end
  end

  test "a desk that promises nothing says nothing" do
    with_support_config(reply_within: nil) do
      assert_nil SupportDesk.config.desk.reply_promise
      assert_nil SupportDesk::Wizard.new(@alice, { topic: "other" }).promise
    end
  end

  # --- The acknowledgement ------------------------------------------------------

  test "the acknowledgement sits under the requester's first message, and is what the case previews" do
    with_support_config(acknowledgement: :"support_desk.thread.acknowledgement", reply_within: 72.hours) do
      ticket = I18n.with_locale(:en) { ticket_for(@alice, topic: :other, message: "My order never arrived") }
      transcript = ticket.conversation.messages.oldest_first.to_a

      assert_equal [ "My order never arrived", "Thanks, we got it. We usually reply in under 72 hours." ],
                   transcript.map(&:body)
      assert_predicate transcript.last, :system?
      assert_equal transcript.last.id, ticket.conversation.reload.last_message_id
    end
  end

  test "the acknowledgement wins the tie when the clock did not move between the two inserts" do
    with_support_config(acknowledgement: "Got it") do
      freeze_time do
        ticket = ticket_for(@alice, topic: :other, message: "Hello")
        first, last = ticket.conversation.messages.oldest_first.to_a

        assert_equal "Hello", first.body
        assert_equal "Got it", last.body
        assert_operator last.created_at, :>, first.created_at
      end
    end
  end

  test "the acknowledgement neither moves the clocks nor answers the requester" do
    with_support_config(acknowledgement: "Got it") do
      ticket = ticket_for(@alice, topic: :other, message: "Hello")

      assert_awaiting_reply ticket
      assert_nil ticket.reload.first_agent_reply_at
    end
  end

  test "only a case the requester opened is acknowledged, and only once" do
    with_support_config(acknowledgement: "Got it", opening_line_from_support: nil) do
      order = create_order(user: @alice)
      written = open_support_ticket(for: @alice, by: @lucia, about: order, message: "We saw your refund bounce")
      assert_equal [ "We saw your refund bounce" ], written.conversation.messages.map(&:body)

      ticket = ticket_for(@alice, topic: :other, message: "Hello")
      ask_again(ticket, "Hello again")
      @alice.ask_support!("And once more", topic: :other)

      assert_equal 1, ticket.conversation.messages.where(body: "Got it").count
    end
  end

  test "a desk that promises nothing acknowledges without a promise" do
    with_support_config(acknowledgement: :"support_desk.thread.acknowledgement", reply_within: nil) do
      ticket = I18n.with_locale(:en) { ticket_for(@alice, topic: :other, message: "Hello") }

      assert_equal "Thanks, we got it.", ticket.conversation.messages.oldest_first.last.body
    end
    with_support_config(acknowledgement: :"support_desk.thread.acknowledgement", reply_within: nil) do
      ticket = I18n.with_locale(:es) { ticket_for(@alice, topic: :account, message: "Hola") }

      assert_equal "Gracias, lo hemos recibido.", ticket.conversation.messages.oldest_first.last.body
    end
  end

  test "the acknowledgement is never news to the requester: their read horizon moves through it" do
    with_support_config(acknowledgement: "Got it") do
      freeze_time do
        ticket = ticket_for(@alice, topic: :other, message: "Hello")

        assert_equal 0, ticket.conversation.participant_for(@alice).reload.unread_count
        # Her receipt is hers: the case she opened is still news on the desk's side.
        assert_predicate ticket.conversation.participant_for(ticket.desk).reload, :unread?
      end
    end
  end

  test "no acknowledgement is configured by default" do
    ticket = ticket_for(@alice, topic: :other, message: "Hello")

    assert_equal [ "Hello" ], ticket.conversation.messages.map(&:body)
  end

  test "an acknowledgement that cannot be interpolated is a boot failure" do
    error = assert_raises(SupportDesk::ConfigurationError) do
      SupportDesk.config.acknowledgement = "Got it, %{labe}"
    end

    assert_match(/acknowledgement/, error.message)
  end

  # --- The closed notice ----------------------------------------------------------

  test "the closed notice can say the promise too" do
    store = { en: { support_desk: { thread: { closed_notice: "Closed. Open a new one: we answer within %{reply_within}." } } } }
    I18n.backend.store_translations(:en, store[:en])
    with_support_config(closed_tickets: :locked, reply_within: 72.hours) do
      ticket = ticket_for(@alice, topic: :other)
      ticket.close!(by: @lucia)

      I18n.with_locale(:en) { assert_equal "Closed. Open a new one: we answer within 72 hours.", ticket.chat_locked_notice }
    end
  ensure
    I18n.reload!
  end
end
