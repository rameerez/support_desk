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
      assert_equal :in_app, ticket.opened_via
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

    test "the database refuses a second open ticket about the same thing" do
      skip_unless_partial_indexes

      first = ticket_for(@alice, about: @order)
      duplicate = Ticket.new(first.attributes.except("id", "reference", "conversation_id", "created_at",
                                                     "updated_at"))
      duplicate.reference = Ticket.generate_reference

      assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
    end

    test "a closed ticket is exempt from the cardinality index" do
      skip_unless_partial_indexes

      first = ticket_for(@alice, about: @order)
      first.close!(by: @lucia)

      assert_nothing_raised { @alice.ask_support!("otra vez", about: @order) }
    end

    test "a concurrent open loses the race and reads the winner's ticket" do
      winner = ticket_for(@alice, about: @order)

      # The real race: the other request's row wasn't visible when our
      # pre-check ran, so the INSERT is what has to catch it. Calling the
      # private inserter directly is exactly that state, with no stubs to
      # make it pass for the wrong reason.
      loser, inserted = Ticket.send(
        :insert_ticket!,
        requester: @alice, desk: SupportDesk.desk, node: SupportDesk.find_topic("order"), about: @order,
        via: :in_app, requester_role: nil, title: nil, metadata: {},
        cardinality_key: winner.cardinality_key, opened_by: @alice
      )

      assert_equal winner.id, loser.id
      assert_not inserted, "the loser found the ticket, it didn't open one"
      assert_equal 1, Ticket.where(requester: @alice, subject: @order).count
    end

    test "losing the insert race announces nothing" do
      skip_unless_partial_indexes

      opened = []
      SupportDesk.on(:ticket_opened) { |ticket| opened << ticket.id }
      winner = @alice.ask_support!("primera", about: @order)

      # Blind only the PRE-CHECK, the way a row committed by another request
      # a millisecond ago is invisible to it. The insert then collides, and
      # the loser ends up holding the winner's ticket — which it must not
      # announce: a host subscriber that pages every agent, or appends to a
      # hash-chained audit log, would do it twice for one case.
      original = Ticket.method(:open_ticket_for)
      checks = 0
      blind_once = lambda do |**arguments|
        checks += 1
        checks == 1 ? nil : original.call(**arguments)
      end

      loser = Ticket.stub(:open_ticket_for, blind_once) do
        @alice.ask_support!("segunda", about: @order)
      end

      assert_equal winner.id, loser.id
      assert_equal [ winner.id ], opened, "exactly one ticket_opened for one ticket"
      assert_equal 1, Ticket.where(requester: @alice, subject: @order).count
      assert_equal 1, winner.reload.events.of_kind(:opened).count
      assert_equal [ "primera", "segunda" ], winner.messages.reload.map(&:body),
                   "the second requester's words still land in the ticket they landed in"
    end

    test "the open-ticket cap is advisory, and the cardinality short-circuit comes first" do
      SupportDesk.config.max_open_tickets = 1
      SupportDesk.config.open_rate_limit = nil
      first = @alice.ask_support!("primera", about: @order)

      # Being handed back the ticket you already have can't trip a cap: you
      # are not opening anything.
      assert_equal first.id, @alice.ask_support!("otra vez", about: @order).id
      assert_raises(TooManyOpenTickets) { @alice.ask_support!("y otra cosa", topic: :account) }
    end

    test "a deep link into a topic the requester may not use is refused" do
      fresh = create_user(onboarded: false)

      error = assert_raises(NotAllowed) { fresh.ask_support!("hola", topic: :account) }

      assert_match(/only:/, error.message)
      assert_nothing_raised { @alice.ask_support!("hola", topic: :account) }
    end

    test "a hidden topic can't be reached through a supportable's own topic either" do
      SupportDesk.config.topics do
        topic :order, about: "Order", only: ->(requester) { requester.onboarded? }
        other
      end
      fresh = create_user(onboarded: false)
      their_order = create_order(user: fresh)

      assert_raises(NotAllowed) { fresh.ask_support!("hola", about: their_order) }
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

    test "a topic that requires a subject can't be opened without one" do
      SupportDesk.config.topics do
        topic :order, about: "Order", subject: :required
        other
      end

      error = assert_raises(NotAllowed) { @alice.ask_support!("hola", topic: :order) }

      assert_match(/needs something to be about/, error.message)
      assert_nothing_raised { @alice.ask_support!("hola", about: @order) }
    end

    test "opened_via is a Symbol, and the channel summary comes from the locale" do
      ticket = ticket_for(@alice)

      assert_equal :in_app, ticket.opened_via
      assert_equal [ :in_app ], ticket.channels
      assert_equal "in app", ticket.channels_summary

      ticket.update!(opened_via: "email")

      assert_equal :email, ticket.reload.opened_via
      assert_equal "email", ticket.channels_summary
      assert_includes Ticket.opened_via(:email), ticket
    end

    test "every channel has copy in both languages" do
      Ticket::CHANNELS.each do |channel|
        %i[es en].each do |locale|
          assert I18n.exists?("support_desk.channels.#{channel}", locale),
                 "no #{locale} copy for the #{channel} channel"
        end
      end
    end

    # --- References ------------------------------------------------------------

    test "references are Crockford base32 and unique" do
      ticket = ticket_for(@alice)

      assert_match(/\AT-[0-9A-HJKMNP-TV-Z]{6}\z/, ticket.reference)
      assert_equal 10, 10.times.map { Ticket.generate_reference }.uniq.size
    end

    test "find_by_reference is forgiving about case, the prefix and Crockford's lookalikes" do
      ticket = ticket_for(@alice)
      body = ticket.reference.delete_prefix("T-")

      assert_equal ticket, Ticket.find_by_reference(ticket.reference)
      assert_equal ticket, Ticket.find_by_reference(ticket.reference.downcase)
      assert_equal ticket, Ticket.find_by_reference(body)
      # The alphabet has no O, I or L precisely so these can be read back.
      assert_equal ticket, Ticket.find_by_reference(ticket.reference.tr("01", "OI"))
      assert_equal ticket, Ticket.find_by_reference(ticket.reference.tr("1", "L"))
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
    # --- Writing first ----------------------------------------------------------

    test "open! by an agent writes the case, the seat and the message in one transaction, or nothing at all" do
      too_long = "x" * (Chats.config.max_message_length + 1)

      assert_no_difference [ -> { Ticket.count }, -> { Chats::Conversation.count },
                             -> { Assignment.count }, -> { Event.count } ] do
        assert_raises(ActiveRecord::RecordInvalid) do
          @lucia.open_support_conversation_with!(@alice, too_long, about: @order)
        end
      end
    end

    test "a case the desk opened is waiting on the requester from its first committed state" do
      ticket = @lucia.open_support_conversation_with!(@alice, "Vimos que tu pedido no llegó", about: @order)

      # No reload, on purpose: the row that committed is already true, and
      # the clocks were folded in on THIS instance inside the transaction.
      # (assert_awaiting_requester would reload and prove nothing.)
      assert_equal "requester", ticket.awaiting
      assert_equal ticket.last_agent_message_at, ticket.waiting_since
      assert_nil ticket.last_requester_message_at
      assert_equal "requester", Ticket.find(ticket.id).awaiting

      # And again once chats' after-commit subscriber has had its go: it
      # finds the message already registered and changes nothing.
      assert_equal "requester", ticket.reload.awaiting
      assert_equal ticket.messages.last.id.to_s, ticket.last_registered_message_id.to_s
    end

    test "the limits are on asking, not on being asked" do
      SupportDesk.config.max_open_tickets = 2
      SupportDesk.config.open_rate_limit = { to: 2, within: 1.hour }
      hers = @alice.ask_support!("una", topic: :account)
      @alice.ask_support!("dos", about: @order)

      assert_raises(RateLimited) { @alice.ask_support!("tres", topic: :other) }

      assert_nothing_raised do
        @lucia.open_support_conversation_with!(@alice, "Vimos que…", topic: :other)
        @lucia.open_support_conversation_with!(@alice, "Y otra cosa", about: create_invoice(user: @alice))
      end

      # Three open cases and a cap of two — but only ONE of them is hers, so
      # she still has room to ask. Outreach never spends an allowance that
      # exists to stop somebody hammering the button.
      SupportDesk.config.open_rate_limit = nil
      hers.close!(by: @lucia)

      assert_equal 3, Ticket.not_closed.where(requester: @alice).count
      assert_nothing_raised { @alice.ask_support!("otra pregunta", topic: :account) }
    end

    test "opened_by records the requester or agent; automation follows decision 17" do
      asked = @alice.ask_support!("no llega", about: @order)
      written = @lucia.open_support_conversation_with!(@alice, "Vimos que…", topic: :other)

      assert_equal @alice, asked.opened_by
      assert_equal @lucia, written.opened_by

      error = assert_raises(NotAnAgent) do
        Ticket.open!(requester: @alice, message: "hola", topic: :account, by: :system)
      end

      assert_match(/automation/, error.message)
      assert_equal 2, Ticket.count
    end

    test "opened_by_support and opened_by_requester partition every case, NULL included" do
      asked = @alice.ask_support!("no llega", about: @order)
      written = @lucia.open_support_conversation_with!(@alice, "Vimos que…", topic: :other)
      legacy = ticket_for(create_user)
      legacy.update_columns(opened_by_type: nil, opened_by_id: nil)

      assert_predicate asked, :opened_by_requester?
      assert_predicate written, :opened_by_support?
      # Only the requester could open a 0.1 case, even before the backfill.
      assert_predicate legacy.reload, :opened_by_requester?

      assert_equal [ asked, legacy ].sort_by(&:id), Ticket.opened_by_requester.sort_by(&:id)
      assert_equal [ written ], Ticket.opened_by_support.to_a
      assert_equal Ticket.count, Ticket.opened_by_requester.count + Ticket.opened_by_support.count

      # An actor whose record is gone is unavailable, never automation.
      written.update_columns(opened_by_type: "User", opened_by_id: 0)

      assert_predicate written.reload, :opened_by_support?
      assert_nil written.opened_by
    end

    test "an agent may file onto a topic the requester isn't offered, but a subject-required topic still needs about:" do
      fresh = create_user(onboarded: false)

      ticket = @lucia.open_support_conversation_with!(fresh, "Sobre tu cuenta", topic: :account)

      assert_equal "account", ticket.topic.path
      assert_raises(NotAllowed) { fresh.ask_support!("hola", topic: :account) }

      SupportDesk.config.topics do
        topic :order, about: "Order", subject: :required
        other
      end
      error = assert_raises(NotAllowed) { @lucia.open_support_conversation_with!(@alice, "hola", topic: :order) }

      assert_match(/needs something to be about/, error.message)
    end

    test "writing first about someone else's record is refused the same way asking would be" do
      theirs = create_order(user: create_user)

      assert_raises(NotAllowed) { @lucia.open_support_conversation_with!(@alice, "hola", about: theirs) }
      assert_raises(NotSupportable) { @lucia.open_support_conversation_with!(@alice, "hola", about: create_user) }
      assert_equal 0, Ticket.count
    end

    test "writing first to a person with this conversation already open is a reply into it, under the desk's reply policy" do
      existing = @alice.ask_support!("no llega", about: @order)

      ticket = @lucia.open_support_conversation_with!(@alice, "Lo estamos mirando", about: @order)

      assert_equal existing.id, ticket.id
      assert_predicate ticket, :opened_by_requester?, "reuse never rewrites who opened the case"
      assert_assigned_to ticket, @lucia
      assert_equal "taken", ticket.assignments.order(:assigned_at).last.reason
      assert_equal [ "no llega", "Lo estamos mirando" ],
                   ticket.messages.where(kind: "text").oldest_first.map(&:body)

      pedro = create_agent(name: "Pedro")
      held = create_user(name: "Bea").ask_support!("hola", topic: :account)
      held.assign!(to: pedro, by: pedro)

      with_support_config(reply_policy: :assignee_only) do
        assert_raises(NotAllowed) do
          @lucia.open_support_conversation_with!(held.requester, "Te escribimos", topic: :account)
        end
      end

      assert_equal 1, held.reload.messages.where(kind: "text").count, "a refusal writes nothing"
      assert_assigned_to held, pedro
    end

    test "the desk's opening message announces nobody: no assignment line, no :agent_replied, no :ticket_assigned" do
      ticket = nil

      events = capture_support_events(:ticket_opened, :ticket_assigned, :agent_replied, :requester_replied) do
        ticket = @lucia.open_support_conversation_with!(@alice, "Vimos que tu pedido no llegó", about: @order)
      end

      assert_equal [ :ticket_opened ], events.map(&:first)
      # The opening line and the message, and nothing else: no "Lucía se
      # ocupa de tu consulta" about a conversation Lucía herself just started.
      assert_equal %w[system text], ticket.messages.oldest_first.pluck(:kind)
      assert_equal I18n.t("support_desk.thread.opened_by_support", desk: ticket.desk.name, label: ticket.label),
                   ticket.messages.oldest_first.first.body
      assert_not_includes ticket.messages.map(&:body), I18n.t("support_desk.system.assigned", agent: "Lucía")
      refute_ticket_event ticket, :assigned
      assert_assigned_to ticket, @lucia
      assert_equal "opened", ticket.assignments.sole.reason
      assert_equal SupportDesk.actor_key(@lucia), ticket.events.of_kind(:opened).sole.payload["assignee"]
      assert_equal @lucia, ticket.events.of_kind(:opened).sole.actor
    end

    test "time_to_first_reply is nil for a case the desk opened" do
      ticket = @lucia.open_support_conversation_with!(@alice, "Vimos que…", topic: :other)
      ask_again ticket, "ah, no lo sabía"
      ticket.reload.reply!("te contamos", by: @lucia)

      assert_nil ticket.reload.time_to_first_reply
      assert_not_nil ticket.first_agent_reply_at, "the clock itself is still kept honest"

      # The same exchange on a case SHE opened does have an answer.
      asked = @alice.ask_support!("y esto?", topic: :account)
      asked.reply!("ahora mismo", by: @lucia)

      assert_not_nil asked.reload.time_to_first_reply
    end

    test "an ineligible requester can neither ask nor be written to" do
      @alice.update!(support_blocked: true)

      assert_raises(NotARequester) { @alice.ask_support!("hola", topic: :account) }
      assert_raises(NotARequester) { @lucia.open_support_conversation_with!(@alice, "Vimos que…", topic: :other) }
      assert_equal 0, Ticket.count

      @alice.update!(support_blocked: false)

      assert_nothing_raised { @alice.ask_support!("hola", topic: :account) }
    end

    test "an agent can't write first to themselves, and by: the requester is still asking" do
      # A dual-role account (an admin who is also a customer) asking for help
      # is inbound, whichever way the caller spells it.
      inbound = Ticket.open!(requester: @lucia, message: "yo también necesito ayuda", topic: :account, by: @lucia)

      assert_predicate inbound, :opened_by_requester?
      assert_predicate inbound, :unassigned?

      error = assert_raises(NotAllowed) { @lucia.open_support_conversation_with!(@lucia, "hola") }

      assert_match(/themselves/, error.message)
    end
  end
end
