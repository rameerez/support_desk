# frozen_string_literal: true

require "test_helper"

module SupportDesk
  class TicketTransitionsTest < ActiveSupport::TestCase
    setup do
      @alice = create_user(name: "Alice")
      @lucia = create_agent(name: "Lucía")
      @pedro = create_agent(name: "Pedro")
      @order = create_order(user: @alice)
      @ticket = ticket_for(@alice, about: @order)
    end

    # --- The actor -------------------------------------------------------------

    test "a transition with no actor at all refuses to write an unsigned row" do
      error = assert_raises(ActorMissing) { @ticket.close! }

      assert_match(/by:/, error.message)
      assert_match(/Current\.actor/, error.message)
      assert_open @ticket
    end

    test "Current.actor is the fallback" do
      Current.actor = @lucia
      @ticket.close!

      assert_closed @ticket
      assert_equal @lucia, @ticket.events.of_kind(:closed).first.actor
    ensure
      Current.actor = nil
    end

    test "by: :system is a legitimate actor with no row to point at" do
      @ticket.close!(by: :system)

      assert_closed @ticket
      assert_nil @ticket.events.of_kind(:closed).first.actor
      assert_equal "system", @ticket.events.of_kind(:closed).first.payload["by"]
    end

    test "agent-only verbs refuse a requester with the fix in the message" do
      error = assert_raises(NotAnAgent) { @ticket.reply!("hola", by: @alice) }

      assert_match(/acts_as_support_agent/, error.message)
      assert_raises(NotAnAgent) { @ticket.note!("hola", by: @alice) }
      assert_raises(NotAnAgent) { @ticket.assign!(to: @alice, by: @lucia) }
    end

    # --- assign! ---------------------------------------------------------------

    test "assign! to yourself is taking the ticket" do
      @ticket.assign!(to: @lucia, by: @lucia)

      assert_assigned_to @ticket, @lucia
      assert_equal "taken", @ticket.assignments.last.reason
      assert_ticket_event @ticket, :assigned
    end

    test "assign! to someone else is assigning it" do
      @ticket.assign!(to: @pedro, by: @lucia)

      assert_assigned_to @ticket, @pedro
      assert_equal "assigned", @ticket.assignments.last.reason
    end

    test "assign! to the current holder writes nothing" do
      @ticket.assign!(to: @lucia, by: @lucia)

      assert_no_difference -> { @ticket.events.count } do
        assert_no_difference -> { @ticket.assignments.count } do
          assert_equal @ticket, @ticket.assign!(to: @lucia, by: @lucia)
        end
      end
    end

    test "assign! replaces the holder and closes their row" do
      @ticket.assign!(to: @lucia, by: @lucia)
      @ticket.assign!(to: @pedro, by: @lucia)

      assert_assigned_to @ticket, @pedro
      assert_equal 1, @ticket.assignments.open.count
      assert_equal "released", @ticket.assignments.for_agent(@lucia).first.release_reason
    end

    test "assign! on a closed ticket says to reopen it first" do
      @ticket.close!(by: @lucia)

      error = assert_raises(InvalidTransition) { @ticket.assign!(to: @lucia, by: @lucia) }

      assert_match(/reopen it first/, error.message)
    end

    test "the requester is told the first time a human takes the case" do
      @ticket.assign!(to: @lucia, by: @lucia)

      assert_equal [ "Lucía is taking care of your request" ], system_messages(@ticket)
    end

    test "announce_assignments :never keeps staffing out of the thread" do
      SupportDesk.config.announce_assignments = :never
      @ticket.assign!(to: @lucia, by: @lucia)

      assert_empty system_messages(@ticket)
    end

    test "announce_assignments :first_only stays quiet on a hand-off" do
      @ticket.assign!(to: @lucia, by: @lucia)
      @ticket.hand_off!(to: @pedro, by: @lucia)

      assert_equal 1, system_messages(@ticket).size
    end

    test "announce_assignments :always narrates the hand-off too" do
      SupportDesk.config.announce_assignments = :always
      @ticket.assign!(to: @lucia, by: @lucia)
      @ticket.hand_off!(to: @pedro, by: @lucia)

      assert_equal [ "Lucía is taking care of your request",
                     "Pedro is now taking care of your request" ], system_messages(@ticket)
    end

    # --- hand_off! -------------------------------------------------------------

    test "hand_off! is assign! said by the holder, with an internal note" do
      @ticket.assign!(to: @lucia, by: @lucia)
      @ticket.hand_off!(to: @pedro, note: "me voy de turno", by: @lucia)

      assert_assigned_to @ticket, @pedro
      assert_equal "handed_off", @ticket.assignments.last.reason
      assert_equal "handed_off", @ticket.assignments.for_agent(@lucia).first.release_reason
      event = assert_ticket_event @ticket, :handed_off, from: @lucia, to: @pedro

      assert_equal "me voy de turno", event.payload["note"]
      assert_not_includes system_messages(@ticket).join, "me voy de turno"
    end

    test "hand_off! by somebody who isn't holding it says who is" do
      @ticket.assign!(to: @lucia, by: @lucia)

      error = assert_raises(NotTheAssignee) { @ticket.hand_off!(to: @pedro, by: @pedro) }

      assert_match(/Lucía/, error.message)
      assert_match(/assign!/, error.message)
    end

    test "hand_off! emits ticket_handed_off with where it came from" do
      @ticket.assign!(to: @lucia, by: @lucia)
      seen = []
      SupportDesk.on(:ticket_handed_off) { |_ticket, _assignment, from:, note:| seen << [ from, note ] }

      @ticket.hand_off!(to: @pedro, note: "turno", by: @lucia)

      assert_equal [ [ @lucia, "turno" ] ], seen
    end

    # --- release! --------------------------------------------------------------

    test "release! puts the ticket back in the pile" do
      @ticket.assign!(to: @lucia, by: @lucia)
      @ticket.release!(by: @lucia, reason: :shift_end)

      assert_unassigned @ticket
      assert_equal "shift_end", @ticket.assignments.last.release_reason
      assert_ticket_event @ticket, :released, from: @lucia
    end

    test "release! on an unassigned ticket writes nothing" do
      assert_no_difference -> { @ticket.events.count } do
        @ticket.release!(by: @lucia)
      end
    end

    test "release! on a closed ticket raises" do
      @ticket.close!(by: @lucia)

      assert_raises(InvalidTransition) { @ticket.release!(by: @lucia) }
    end

    # --- close! and reopen! ------------------------------------------------------

    test "close! stamps who and when, and stops the clock" do
      @ticket.assign!(to: @lucia, by: @lucia)
      @ticket.close!(by: @lucia)

      assert_closed @ticket
      assert_equal @lucia, @ticket.closed_by
      assert_equal "none", @ticket.awaiting
      assert_nil @ticket.waiting_since
      assert_predicate @ticket.assignments.last, :released?
      assert_equal "closed", @ticket.assignments.last.release_reason
    end

    test "a closed ticket keeps its assignee as the record of who dealt with it" do
      @ticket.assign!(to: @lucia, by: @lucia)
      @ticket.close!(by: @lucia)

      assert_equal @lucia, @ticket.reload.assignee
      assert_empty @ticket.assignments.open
    end

    test "close! twice writes nothing the second time" do
      @ticket.close!(by: @lucia)

      assert_no_difference -> { @ticket.events.count } do
        assert_equal @ticket, @ticket.close!(by: @lucia)
      end
    end

    test "reopen! counts the reopen and gives the case back to whoever handled it" do
      @ticket.assign!(to: @lucia, by: @lucia)
      @ticket.close!(by: @lucia)
      @ticket.reopen!(by: @alice)

      assert_open @ticket
      assert_equal 1, @ticket.reopen_count
      assert_predicate @ticket, :reopened?
      assert_assigned_to @ticket, @lucia
      assert_equal "reopened", @ticket.assignments.open.first.reason
    end

    test "reopen! returns the case to the pool when its handler can no longer take it" do
      @ticket.assign!(to: @lucia, by: @lucia)
      @ticket.close!(by: @lucia)
      @lucia.update!(admin: false)

      @ticket.reopen!(by: @alice)

      assert_unassigned @ticket
    end

    test "reopen! restarts the waiting clock, so the SLA scopes can see it again" do
      @ticket.reply!("vamos", by: @lucia)
      @alice.message!(@ticket.conversation, "sigo esperando")
      # Push both clocks back, keeping the requester's the later one: the
      # desk owes the next word and has owed it for 30 hours.
      @ticket.reload.update_columns(last_agent_message_at: 31.hours.ago,
                                    last_requester_message_at: 30.hours.ago)
      @ticket.close!(by: @lucia)

      @ticket.reopen!(by: @alice)

      assert_equal "agent", @ticket.reload.awaiting
      assert_not_nil @ticket.waiting_since, "a reopened case with nothing on its clock is invisible to the SLA"
      assert_includes Ticket.waiting_over(24.hours), @ticket
      assert_includes Ticket.overdue, @ticket
      assert_predicate @ticket, :overdue?
    end

    test "reopen! on an open ticket writes nothing" do
      assert_no_difference -> { @ticket.events.count } do
        assert_equal @ticket, @ticket.reopen!(by: @alice)
      end
    end

    # --- note! -----------------------------------------------------------------

    test "note! is internal: an event, never a message" do
      event = @ticket.note!("cliente VIP", by: @lucia)

      assert_equal "note", event.kind
      assert_equal "cliente VIP", event.note
      assert_includes @ticket.notes, event
      assert_empty @ticket.conversation.messages.where("body LIKE ?", "%VIP%")
    end

    test "note! emits note_added" do
      seen = []
      SupportDesk.on(:note_added) { |_ticket, event| seen << event.note }

      @ticket.note!("ojo", by: @lucia)

      assert_equal [ "ojo" ], seen
    end

    test "note! needs something to say" do
      assert_raises(ArgumentError) { @ticket.note!("  ", by: @lucia) }
    end

    # --- change_topic! and attach_subject! ----------------------------------------

    test "change_topic! refiles the case and remembers where it came from" do
      @ticket.change_topic!(to: :"billing/invoice", by: @lucia)

      assert_equal "billing/invoice", @ticket.reload.topic.path
      event = assert_ticket_event @ticket, :topic_changed

      assert_equal "order", event.payload["from"]
      assert_equal "billing/invoice", event.payload["to"]
    end

    test "change_topic! to the same topic writes nothing" do
      assert_no_difference -> { @ticket.events.count } do
        @ticket.change_topic!(to: :order, by: @lucia)
      end
    end

    test "change_topic! to a topic nobody has raises" do
      assert_raises(UnknownTopic) { @ticket.change_topic!(to: :nope, by: @lucia) }
    end

    test "change_topic! raises the priority when the new topic is more urgent" do
      SupportDesk.config.topics do
        topic :order, about: "Order"
        topic :safety, priority: :urgent
        other
      end

      @ticket.change_topic!(to: :safety, by: @lucia)

      assert_equal 2, @ticket.reload.priority
    end

    test "attach_subject! points a free-form ticket at what it turned out to be about" do
      free = ticket_for(create_user)
      order = create_order(user: free.requester)

      free.attach_subject!(order, by: @lucia)

      assert_equal order, free.reload.subject
      assert_ticket_event free, :subject_attached
    end

    test "attach_subject! claims the cardinality of the thing it now says it's about" do
      another_order = create_order(user: @alice, number: "SO2")
      free = ticket_for(@alice, topic: :account)

      free.attach_subject!(another_order, by: @lucia)

      # The case IS the open case about that order now, so asking about the
      # order again lands in it rather than opening a second one.
      assert_equal free.id, @alice.ask_support!("otra vez", about: another_order).id
      assert_equal 1, Ticket.where(requester: @alice, subject: another_order).count
    end

    test "change_topic! frees the topic it vacated" do
      free = ticket_for(@alice, topic: :account)

      free.change_topic!(to: :other, by: @lucia)

      reopened_topic = @alice.ask_support!("una cosa nueva de mi cuenta", topic: :account)

      assert_not_equal free.id, reopened_topic.id
      assert_equal "account", reopened_topic.topic.path
    end

    test "refiling onto something the requester already has an open case about is refused" do
      about_order = ticket_for(@alice, about: @order)
      free = ticket_for(@alice, topic: :account)

      error = assert_raises(InvalidTransition) { free.attach_subject!(@order, by: @lucia) }

      assert_match(/already has an open ticket about that/, error.message)
      assert_match(about_order.reference, error.message)
      assert_nil free.reload.subject
    end

    test "change_topic! is an agent's job" do
      error = assert_raises(NotAnAgent) { @ticket.change_topic!(to: :account, by: @alice) }

      assert_match(/acts_as_support_agent/, error.message)
      assert_equal "order", @ticket.reload.topic.path
    end

    test "an agent may file onto a topic no requester is offered" do
      SupportDesk.config.topics do
        topic :order, about: "Order"
        topic :safety, priority: :urgent, only: ->(_requester) { false }
        other
      end

      @ticket.change_topic!(to: :safety, by: @lucia)

      assert_equal "safety", @ticket.reload.topic.path
      assert_equal 2, @ticket.priority
    end

    test "attach_subject! refuses a record that isn't supportable" do
      assert_raises(NotSupportable) { @ticket.attach_subject!(create_user, by: @lucia) }
    end

    test "attach_subject! with the subject it already has writes nothing" do
      assert_no_difference -> { @ticket.events.count } do
        @ticket.attach_subject!(@order, by: @lucia)
      end
    end

    # --- reply! and the reply policy ----------------------------------------------

    test "reply! is sent by the desk and authored by the agent" do
      message = @ticket.reply!("Lo estamos revisando", by: @lucia)

      assert_equal @ticket.desk, message.sender
      assert_equal @lucia, message.author
      assert_predicate message, :signed?
      assert_equal "Lo estamos revisando", message.body
    end

    test "under :anyone the first agent to answer an unheld ticket takes it" do
      @ticket.reply!("vamos", by: @lucia)

      assert_assigned_to @ticket, @lucia
      assert_equal "taken", @ticket.assignments.last.reason
    end

    test "under :anyone a drop-in reply leaves ownership alone and marks the timeline" do
      @ticket.assign!(to: @lucia, by: @lucia)
      @ticket.reply!("paso por aquí", by: @pedro)

      assert_assigned_to @ticket, @lucia
      assert_ticket_event @ticket, :drop_in
    end

    test "under :take_over a drop-in reply takes the ticket" do
      SupportDesk.config.reply_policy = :take_over
      @ticket.assign!(to: @lucia, by: @lucia)
      @ticket.reply!("me lo quedo", by: @pedro)

      assert_assigned_to @ticket, @pedro
      assert_equal "drop_in_takeover", @ticket.assignments.last.reason
    end

    test "under :assignee_only a drop-in is refused and says who holds it" do
      SupportDesk.config.reply_policy = :assignee_only
      @ticket.assign!(to: @lucia, by: @lucia)

      error = assert_raises(NotAllowed) { @ticket.reply!("paso", by: @pedro) }

      assert_match(/Lucía/, error.message)
    end

    test "under :assignee_only an unheld ticket has to be taken first" do
      SupportDesk.config.reply_policy = :assignee_only

      error = assert_raises(NotAllowed) { @ticket.reply!("paso", by: @pedro) }

      assert_match(/take it first/, error.message)

      @ticket.assign!(to: @pedro, by: @pedro)

      assert_nothing_raised { @ticket.reply!("ahora sí", by: @pedro) }
    end

    test "reply! into a locked closed ticket says to reopen it" do
      SupportDesk.config.closed_tickets = :locked
      @ticket.close!(by: @lucia)

      error = assert_raises(InvalidTransition) { @ticket.reply!("hola", by: @lucia) }

      assert_match(/reopen it first/, error.message)
    end

    test "an agent may answer a closed ticket when closing doesn't lock it, and it stays closed" do
      @ticket.close!(by: @lucia)

      assert_nothing_raised { @ticket.reply!("una cosa más", by: @lucia) }
      assert_closed @ticket
      assert_predicate @ticket.assignments.open, :empty?
    end

    # --- Bookkeeping --------------------------------------------------------------

    test "every transition writes exactly one event row" do
      @ticket.assign!(to: @lucia, by: @lucia)
      @ticket.hand_off!(to: @pedro, by: @lucia)
      @ticket.release!(by: @pedro)
      @ticket.close!(by: @lucia)
      @ticket.reopen!(by: @alice)

      assert_equal %w[opened assigned handed_off released closed reopened],
                   @ticket.events.chronological.map(&:kind)
    end

    test "the umbrella event carries the payload the audit log needs" do
      seen = []
      SupportDesk.on(:ticket_transitioned) do |ticket, kind, by:, request:, payload:|
        seen << [ ticket.reference, kind, by, payload ]
      end

      @ticket.assign!(to: @pedro, by: @lucia)

      reference, kind, by, payload = seen.last

      assert_equal @ticket.reference, reference
      assert_equal :assigned, kind
      assert_equal @lucia, by
      assert_equal SupportDesk.actor_key(@pedro), payload["assignee"]
    end

    test "actions_for is exactly the buttons a console should render" do
      assert_equal %i[note reply assign change_topic close], @ticket.actions_for(@lucia)

      @ticket.assign!(to: @lucia, by: @lucia)

      assert_equal %i[note reply assign hand_off release change_topic close], @ticket.reload.actions_for(@lucia)
      assert_equal %i[note reply assign release change_topic close], @ticket.actions_for(@pedro)

      @ticket.close!(by: @lucia)

      assert_equal %i[note reopen], @ticket.reload.actions_for(@lucia)
      assert_empty @ticket.actions_for(@alice)
    end

    test "actions_for drops reply when the policy won't allow it" do
      SupportDesk.config.reply_policy = :assignee_only
      @ticket.assign!(to: @lucia, by: @lucia)

      assert_includes @ticket.actions_for(@lucia), :reply
      assert_not_includes @ticket.reload.actions_for(@pedro), :reply
    end

    private

    def system_messages(ticket)
      ticket.conversation.messages.where(kind: "system").order(:created_at, :id).pluck(:body)
    end
  end
end
