# frozen_string_literal: true

require "test_helper"

module SupportDesk
  class TicketTest < ActiveSupport::TestCase
    setup do
      @alice = create_user(name: "Alice")
      @lucia = create_agent(name: "Lucía")
      @order = create_order(user: @alice, number: "SO1")
    end

    # --- Opening ---------------------------------------------------------------

    test "ask_support! opens a ticket, a conversation and the first message" do
      ticket = @alice.ask_support!("No me ha llegado", about: @order)

      assert_predicate ticket, :persisted?
      assert_equal @alice, ticket.requester
      assert_equal @order, ticket.subject
      assert_equal "order", ticket.topic.path
      assert_equal "open", ticket.status
      assert_equal "in_app", ticket.opened_via
      assert_not_nil ticket.conversation
      assert_equal "No me ha llegado", ticket.messages.first.body
      assert ticket.conversation.participant?(@alice)
      assert ticket.conversation.participant?(ticket.desk)
    end

    test "the topic comes from the subject when it isn't given" do
      invoice = create_invoice(user: @alice)

      assert_equal "billing/invoice", @alice.ask_support!("dudas", about: invoice).topic.path
    end

    test "a subject-less ticket lands on the free-form leaf" do
      assert_equal "other", @alice.ask_support!("una duda").topic.path
    end

    test "an explicit topic wins" do
      assert_equal "account", @alice.ask_support!("una duda", topic: :account).topic.path
    end

    test "an unknown topic raises and names the ones that exist" do
      error = assert_raises(UnknownTopic) { @alice.ask_support!("hola", topic: :nope) }

      assert_match(/no topic :nope/, error.message)
      assert_match(/order/, error.message)
    end

    test "a desk with no free-form leaf says so instead of guessing" do
      SupportDesk.config.topics { topic :order, about: "Order" }

      error = assert_raises(UnknownTopic) { @alice.ask_support!("hola") }

      assert_match(/no free-form topic/, error.message)
    end

    test "a record that isn't supportable is refused with the fix" do
      error = assert_raises(NotSupportable) { @alice.ask_support!("hola", about: create_user) }

      assert_match(/supportable topic:/, error.message)
    end

    test "a requester may not open a ticket about someone else's record" do
      other_order = create_order(user: create_user)

      assert_raises(NotAllowed) { @alice.ask_support!("hola", about: other_order) }
    end

    test "opening twice about the same record returns the same open ticket, with the new message" do
      first = @alice.ask_support!("primera", about: @order)
      second = @alice.ask_support!("segunda", about: @order)

      assert_equal first.id, second.id
      assert_equal [ "primera", "segunda" ], second.messages.reload.map(&:body)
      assert_equal 1, Ticket.where(requester: @alice).count
    end

    test "a second free-form ticket on the same topic is the same ticket" do
      first = @alice.ask_support!("una duda")

      assert_equal first.id, @alice.ask_support!("otra duda").id
    end

    test "a closed ticket doesn't block a new one about the same record" do
      first = @alice.ask_support!("primera", about: @order)
      first.close!(by: @lucia)

      second = @alice.ask_support!("otra vez", about: @order)

      assert_not_equal first.id, second.id
    end

    test "one_open_ticket: false lets a requester hold several about one record" do
      Order.stub(:one_open_support_ticket?, false) do
        first = @alice.ask_support!("primera", about: @order)
        second = @alice.ask_support!("segunda", about: @order)

        assert_not_equal first.id, second.id
      end
    end

    test "a concurrent open loses the race and reads the winner's ticket" do
      winner = @alice.ask_support!("primera", about: @order)

      # Simulate the other request having committed between our check and our
      # INSERT: the unique index (PostgreSQL) or the pre-check (elsewhere)
      # hands us the ticket that already exists.
      Ticket.stub(:open_ticket_for, ->(**) { nil }) do
        Ticket.stub(:insert_ticket!, ->(**) { winner }) do
          assert_equal winner.id, @alice.ask_support!("segunda", about: @order).id
        end
      end
    end

    test "the open rate limit is per requester and says what it counted" do
      SupportDesk.config.open_rate_limit = { to: 1, within: 1.hour }
      SupportDesk.config.max_open_tickets = nil
      @alice.ask_support!("una", topic: :account)

      error = assert_raises(RateLimited) { @alice.ask_support!("dos", about: @order) }

      assert_match(/limit 1/, error.message)
      assert_nothing_raised { create_user.ask_support!("mía", topic: :account) }
    end

    test "max_open_tickets walls a requester with too many cases" do
      SupportDesk.config.max_open_tickets = 1
      SupportDesk.config.open_rate_limit = nil
      @alice.ask_support!("una", topic: :account)

      assert_raises(TooManyOpenTickets) { @alice.ask_support!("dos", about: @order) }
    end

    # --- References ------------------------------------------------------------

    test "references are Crockford base32 and unique" do
      ticket = ticket_for(@alice)

      assert_match(/\AT-[0-9A-HJKMNP-TV-Z]{6}\z/, ticket.reference)
      assert_equal 10, 10.times.map { Ticket.generate_reference }.uniq.size
    end

    test "find_by_reference is forgiving about case and the prefix" do
      ticket = ticket_for(@alice)
      body = ticket.reference.delete_prefix("T-")

      assert_equal ticket, Ticket.find_by_reference(ticket.reference)
      assert_equal ticket, Ticket.find_by_reference(ticket.reference.downcase)
      assert_equal ticket, Ticket.find_by_reference(body)
      assert_nil Ticket.find_by_reference("T-ZZZZZZ")
      assert_nil Ticket.find_by_reference(nil)
      assert_raises(ActiveRecord::RecordNotFound) { Ticket.find_by_reference!("T-ZZZZZZ") }
    end

    # --- Readers ---------------------------------------------------------------

    test "label prefers the title, then the subject, then the topic" do
      ticket = ticket_for(@alice, about: @order)

      assert_equal "Order SO1", ticket.label

      ticket.update!(title: "Pedido perdido")

      assert_equal "Pedido perdido", ticket.label

      assert_equal "Something else", ticket_for(create_user).label
    end

    test "chat_subject_label is the label chats shows as the context line" do
      ticket = ticket_for(@alice, about: @order)

      assert_equal ticket.label, ticket.conversation.subject_label
    end

    test "chat_locked? only when the desk locks closed tickets" do
      ticket = ticket_for(@alice)
      ticket.close!(by: @lucia)

      assert_not_predicate ticket, :chat_locked?

      SupportDesk.config.closed_tickets = :locked

      assert_predicate ticket, :chat_locked?
      assert_predicate ticket.chat_locked_notice, :present?
    end

    test "predicates read the way you'd say them" do
      ticket = ticket_for(@alice, about: @order)

      assert_predicate ticket, :open?
      assert_predicate ticket, :unassigned?
      assert_predicate ticket, :awaiting_reply?
      assert_not_predicate ticket, :reopened?
      assert ticket.about?(@order)
      assert_not ticket.about?(create_order(user: @alice))
      assert_not ticket.assigned_to?(@lucia)
    end

    test "waiting_for and the SLA clocks measure what they say" do
      ticket = ticket_for(@alice)
      ticket.update!(waiting_since: 90.minutes.ago, opened_at: 2.hours.ago)

      assert_in_delta 90.minutes.to_i, ticket.waiting_for.to_i, 5
      assert_nil ticket.time_to_first_reply
      assert_nil ticket.time_to_close

      ticket.update!(first_agent_reply_at: 1.hour.ago)

      assert_in_delta 1.hour.to_i, ticket.time_to_first_reply.to_i, 5

      ticket.close!(by: @lucia)

      assert_in_delta 2.hours.to_i, ticket.reload.time_to_close.to_i, 5
    end

    test "at_risk? and overdue? come from the desk's thresholds and don't overlap" do
      ticket = ticket_for(@alice)
      SupportDesk.config.at_risk_after = 1.hour
      SupportDesk.config.reply_within = 4.hours

      ticket.update!(waiting_since: 30.minutes.ago)

      assert_not_predicate ticket, :at_risk?
      assert_not_predicate ticket, :overdue?

      ticket.update!(waiting_since: 2.hours.ago)

      assert_predicate ticket, :at_risk?
      assert_not_predicate ticket, :overdue?

      ticket.update!(waiting_since: 5.hours.ago)

      assert_not_predicate ticket, :at_risk?
      assert_predicate ticket, :overdue?
    end

    test "channels and the summary of them" do
      ticket = ticket_for(@alice)

      assert_equal [ :in_app ], ticket.channels
      assert_equal "in app", ticket.channels_summary
    end

    test "agents_to_notify is the holder, or the whole on-duty pool" do
      ticket = ticket_for(@alice)
      other = create_agent

      assert_equal [ @lucia, other ].sort_by(&:id), ticket.agents_to_notify.sort_by(&:id)

      ticket.assign!(to: @lucia, by: @lucia)

      assert_equal [ @lucia ], ticket.agents_to_notify
    end

    test "notification copy keeps the detail out of the title" do
      ticket = ticket_for(@alice, about: @order)

      assert_equal "Soporte · new message", ticket.notification_title
      assert_equal "Order SO1", ticket.notification_body
    end

    test "inspect says everything you need in a console" do
      ticket = ticket_for(@alice, about: @order)
      ticket.assign!(to: @lucia, by: @lucia)

      assert_match(/#<SupportDesk::Ticket T-\w+ order "Order SO1" open → Lucía \(awaiting reply/, ticket.inspect)
    end

    test "export is the requester's own story, without the internal parts" do
      ticket = ticket_for(@alice, about: @order, message: "No ha llegado")
      ticket.reply!("Lo miramos", by: @lucia)
      ticket.note!("cliente VIP", by: @lucia)

      export = ticket.export

      assert_equal ticket.reference, export[:reference]
      assert_equal "Order SO1", export[:label]
      assert_equal %w[you support], export[:messages].map { |message| message[:from] }.uniq
      assert_not_includes export[:messages].map { |message| message[:body] }, "cliente VIP"
      assert_not_includes export[:events].map { |event| event[:kind] }, "note"
    end

    # --- Scopes ----------------------------------------------------------------

    test "status scopes" do
      open_ticket = ticket_for(@alice)
      closed = ticket_for(create_user)
      closed.close!(by: @lucia)

      assert_includes Ticket.open, open_ticket
      assert_includes Ticket.not_closed, open_ticket
      assert_includes Ticket.closed, closed
      assert_not_includes Ticket.not_closed, closed
    end

    test "assignment scopes" do
      mine = ticket_for(@alice)
      theirs = ticket_for(create_user)
      mine.assign!(to: @lucia, by: @lucia)

      assert_includes Ticket.assigned, mine
      assert_includes Ticket.assigned_to(@lucia), mine
      assert_includes Ticket.unassigned, theirs
      assert_not_includes Ticket.assigned_to(@lucia), theirs
    end

    test "awaiting scopes follow the transcript" do
      ticket = ticket_for(@alice)

      assert_includes Ticket.awaiting_reply, ticket

      ticket.reply!("vamos", by: @lucia)

      assert_includes Ticket.awaiting_requester, ticket.reload
      assert_not_includes Ticket.awaiting_reply, ticket
    end

    test "waiting_over, at_risk and overdue" do
      ticket = ticket_for(@alice)
      SupportDesk.config.at_risk_after = 1.hour
      SupportDesk.config.reply_within = 4.hours
      ticket.update!(waiting_since: 2.hours.ago)

      assert_includes Ticket.waiting_over(1.hour), ticket
      assert_not_includes Ticket.waiting_over(3.hours), ticket
      assert_includes Ticket.at_risk, ticket
      assert_not_includes Ticket.overdue, ticket

      ticket.update!(waiting_since: 5.hours.ago)

      assert_includes Ticket.overdue, ticket
      assert_not_includes Ticket.at_risk, ticket
    end

    test "subject and topic scopes" do
      about_order = ticket_for(@alice, about: @order)
      invoice = ticket_for(create_user, topic: :"billing/invoice")

      assert_includes Ticket.about(@order), about_order
      assert_includes Ticket.about_any(Order), about_order
      assert_not_includes Ticket.about_any(Invoice), about_order
      assert_includes Ticket.on_topic(:billing), invoice
      assert_includes Ticket.on_topic(:"billing/invoice"), invoice
      assert_not_includes Ticket.on_topic(:order), invoice
    end

    test "desk, channel and period scopes" do
      ticket = ticket_for(@alice)

      assert_includes Ticket.for_desk(:default), ticket
      assert_includes Ticket.opened_via(:in_app), ticket
      assert_includes Ticket.opened_between(1.hour.ago..1.hour.from_now), ticket
      assert_empty Ticket.opened_between(3.hours.ago..2.hours.ago)
    end

    test "ordering scopes" do
      first = ticket_for(@alice)
      second = ticket_for(create_user)
      first.update!(priority: 2)

      assert_equal first, Ticket.most_urgent_first.first
      assert_equal second, Ticket.newest_first.first
      assert_equal first, Ticket.oldest_first.first
      assert_equal 2, Ticket.recent_activity_first.count
    end

    test "for_conversation is how a chats message finds its case" do
      ticket = ticket_for(@alice)

      assert_equal ticket, Ticket.for_conversation(ticket.conversation)
      assert_nil Ticket.for_conversation(nil)
    end
  end
end
