# frozen_string_literal: true

require "test_helper"

module SupportDesk
  # §12.9 — pause, the case cap, closing, the silent sweep, redispatch and
  # outreach. Everything that decides whether she is working on a case at
  # all, and everything that notices when she has stopped.
  class AssistantLifecycleTest < ActiveSupport::TestCase
    setup do
      @alice = create_user(name: "Alice")
      @lucia = create_agent(name: "Lucía")
      @rose = configure_assistant!(autonomy: :resolve)
      @ticket = ticket_for(@alice, message: "No me llega el pedido")
    end

    def turn = @ticket.reload.assistant_turn

    # --- Pause -------------------------------------------------------------------

    test "pausing takes her seat, her proposal and her turn" do
      @ticket.assign!(to: @rose, by: @rose, turn: @ticket.reload.assistant_turn)
      draft = @ticket.draft!("propuesta", by: @rose, turn: turn)
      seen = []
      SupportDesk.on(:assistant_paused) { |ticket, by:| seen << [ ticket.id, by ] }

      @ticket.pause_assistant!(by: @lucia, reason: "conversación delicada")

      assert_predicate @ticket, :assistant_paused?
      assert_equal "conversación delicada", @ticket.assistant_paused_reason
      assert_unassigned @ticket
      assert_predicate draft.reload, :superseded?
      assert_assistant_policy @ticket, :off
      assert_equal [ [ @ticket.id, @lucia ] ], seen
      assert_equal "conversación delicada", assert_ticket_event(@ticket, :assistant_paused).payload["reason"]
    end

    test "pausing twice writes once, and a closed case can't be paused" do
      @ticket.pause_assistant!(by: @lucia)
      @ticket.pause_assistant!(by: @lucia)

      assert_equal 1, @ticket.events.of_kind(:assistant_paused).count

      @ticket.resume_assistant!(by: @lucia)
      @ticket.reply!("Ya está", by: @lucia)
      @ticket.close!(by: @lucia)

      assert_raises(InvalidTransition) { @ticket.pause_assistant!(by: @lucia) }
    end

    test "resuming wakes the harness when the customer is waiting" do
      @ticket.pause_assistant!(by: @lucia)
      turns = []
      SupportDesk.on(:assistant_turn) { |*| turns << true }

      @ticket.resume_assistant!(by: @lucia)

      refute_predicate @ticket, :assistant_paused?
      assert_equal 1, turns.size
      assert_ticket_event @ticket, :assistant_resumed
    end

    test "a paused case is not a hidden case" do
      @ticket.pause_assistant!(by: @lucia)

      # The whole point of the separate column: the case is still in the
      # queue, still awaiting an answer, and the people can still see it.
      assert_awaiting_reply @ticket
      assert_includes @lucia.support_queue.awaiting, @ticket
      assert_includes @ticket.actions_for(@lucia), :reply
    end

    # --- The case cap ------------------------------------------------------------

    test "a case she closed and the customer reopened comes back to people, capped" do
      @ticket.respond!("Ya está resuelto", by: @rose, turn: turn)
      @ticket.close!(by: @rose, turn: turn)

      assert_equal @rose, @ticket.closed_by

      ask_again(@ticket, "no funcionó")

      assert_ticket_open @ticket
      assert_unassigned @ticket, "it comes back to people"
      assert_equal "draft", @ticket.reload.assistant_cap
      assert_equal true, @ticket.events.of_kind(:reopened).first.payload["assistant_capped"]
      assert_assistant_policy @ticket, :draft, because: "this case caps rose at draft"

      outcome = @ticket.respond!("Lo reviso otra vez", by: @rose, turn: turn)

      assert_predicate outcome, :drafted?, "her next answer is a proposal, whatever her level is elsewhere"
    end

    test "an existing cap is kept when it is tighter" do
      @ticket.update!(assistant_cap: "observe")
      @ticket.respond!("Ya está", by: @rose, turn: turn) # withheld at :observe
      @ticket.reply!("Ya está", by: @lucia)
      @ticket.close!(by: @lucia)
      @ticket.update_columns(closed_by_type: Assistant.polymorphic_name, closed_by_id: @rose.id)

      ask_again(@ticket, "sigue sin ir")

      assert_equal "observe", @ticket.reload.assistant_cap, "a cap can only tighten"
    end

    test "a case a PERSON closed comes back to that person" do
      @ticket.assign!(to: @lucia, by: @lucia)
      @ticket.reply!("Ya está", by: @lucia)
      @ticket.close!(by: @lucia)

      ask_again(@ticket, "no funcionó")

      assert_assigned_to @ticket, @lucia, "the human path is untouched"
      assert_nil @ticket.assistant_cap
    end

    test "an explicit hand-back is what lifts a case cap" do
      @ticket.update!(assistant_cap: "draft")

      @ticket.assign!(to: @rose, by: @lucia)

      assert_nil @ticket.reload.assistant_cap
    end

    # --- Closing -----------------------------------------------------------------

    test "she may close only what she holds, when it is the customer's turn" do
      @ticket.respond!("Ya está resuelto", by: @rose, turn: turn)

      assert_held_by_assistant @ticket, @rose
      assert_predicate @ticket, :awaiting_requester?

      @ticket.close!(by: @rose, turn: turn)

      assert_ticket_closed @ticket
      assert_equal @rose, @ticket.closed_by
      assert_includes Ticket.resolved_by_assistant, @ticket
    end

    test "closing needs the current turn like everything else" do
      @ticket.respond!("Ya está", by: @rose, turn: turn)
      stale = turn
      @ticket.note!("una nota", by: @lucia)

      assert_raises(StaleTurn) { @ticket.close!(by: @rose, turn: stale) }
      assert_raises(ArgumentError) { @ticket.close!(by: @rose) }
      assert_ticket_open @ticket
    end

    # --- The silent sweep --------------------------------------------------------

    test "a case she sat on past her promise goes to a person" do
      with_assistant_config(responds_within: 60) do
        @ticket.assign!(to: @rose, by: @rose, turn: @ticket.reload.assistant_turn)
        escalated = []
        SupportDesk.on(:ticket_escalated) { |ticket, from:, reason:, by:| escalated << [ ticket.id, reason ] }

        assert_equal 0, SupportDesk.release_silent_assistants!, "not yet"

        travel 2.minutes

        assert_equal 1, SupportDesk.release_silent_assistants!

        assert_needs_human @ticket, reason: "assistant_silent"
        assert_unassigned @ticket
        assert_equal [ [ @ticket.id, :assistant_silent ] ], escalated
        assert_equal 0, SupportDesk.release_silent_assistants!, "and it does not do it twice"
      end
    end

    test "the sweep leaves a person's seat alone and still asks for a person" do
      with_assistant_config(responds_within: 60) do
        @ticket.assign!(to: @rose, by: @rose, turn: @ticket.reload.assistant_turn)
        travel 2.minutes
        # Somebody took it over between the scope and the lock.
        @ticket.assign!(to: @lucia, by: @lucia)

        assert_equal 0, SupportDesk.release_silent_assistants!, "it is not hers any more"
        assert_assigned_to @ticket, @lucia
      end
    end

    test "an assistant with no promise is not swept" do
      with_assistant_config(responds_within: nil) do
        @ticket.assign!(to: @rose, by: @rose, turn: @ticket.reload.assistant_turn)
        travel 1.hour

        assert_equal 0, SupportDesk.release_silent_assistants!
        refute_needs_human @ticket
      end
    end

    test "the sweep leaves a case whose silence ended while it was sweeping" do
      # The sweep's predicates are true when the candidates are SELECTED. By
      # the time it reaches the second one, a person has answered it — and
      # escalating it anyway raises its priority and tells the customer a
      # person is coming, on a case that already has one.
      with_assistant_config(responds_within: 60) do
        first = ticket_for(create_user(name: "Ana"), message: "la primera")
        second = ticket_for(create_user(name: "Bruno"), message: "la segunda")
        [ first, second ].each do |ticket|
          ticket.assign!(to: @rose, by: @rose, turn: ticket.reload.assistant_turn)
          Ticket.where(id: ticket.id).update_all(waiting_since: 1.hour.ago)
        end
        # Answering the second one the moment the first is handed over: the
        # sweep is between its own SELECT and its own transition, and this
        # needs no barrier and no stubbed transition to be exactly that.
        SupportDesk.on(:ticket_escalated) do |ticket, **|
          Ticket.find(second.id).reply!("Ya te contesto yo", by: @lucia) if ticket.id == first.id
        end

        moved = SupportDesk.release_silent_assistants!

        assert_predicate first.reload, :human_required?
        refute_needs_human second.reload
        assert_assigned_to second, @lucia
        assert_equal 1, moved, "a case whose silence had ended was counted as moved"
        refute_ticket_event second, :escalated
      end
    end

    # --- Redispatch --------------------------------------------------------------

    test "a turn nobody acted on is re-emitted" do
      turns = []
      SupportDesk.on(:assistant_turn) { |_ticket, _assistant, message, turn:| turns << [ message, turn ] }

      assert_equal 0, SupportDesk.redispatch_assistant_turns!(older_than: 60), "too soon"

      travel 2.minutes

      assert_equal 1, SupportDesk.redispatch_assistant_turns!(older_than: 60)
      assert_equal 1, turns.size
      assert_nil turns.first.first
      assert_equal @ticket.reload.assistant_turn, turns.first.last
    end

    test "a turn she acted on is not re-emitted, whatever she decided" do
      with_assistant_config(autonomy: :draft) do
        @ticket.draft!("propuesta", by: @rose, turn: turn)
        travel 2.minutes

        assert_equal 0, SupportDesk.redispatch_assistant_turns!(older_than: 60),
                     "a proposal counts as having acted"
      end

      other = ticket_for(@alice, topic: :order, message: "Otra")
      other.note!("mirando", by: @rose, turn: other.assistant_turn)
      travel 2.minutes

      assert_equal 0, SupportDesk.redispatch_assistant_turns!(older_than: 60), "so does a note"
    end

    test "a withheld answer counts as having acted, so the harness is not chased" do
      with_assistant_config(autonomy: :observe) do
        @ticket.respond!("no debería", by: @rose, turn: turn)
        travel 2.minutes

        assert_equal 0, SupportDesk.redispatch_assistant_turns!(older_than: 60)
      end
    end

    # --- A lost registration is repairable (R3) ----------------------------------

    test "redispatch repairs a committed message whose registration was lost" do
      # A worker killed between the message's COMMIT and the subscriber that
      # registers it. Nothing is wrong with the message; the case simply does
      # not know about it, and its clocks say the customer has the last word.
      @ticket.respond!("Lo estamos mirando", by: @rose, turn: turn)

      assert_awaiting_requester @ticket

      Ticket.stub(:for_conversation, nil) { ask_again(@ticket, "¿hay novedades?") }
      @ticket.reload
      held = @ticket.assistant_turn

      # The clocks still say the customer has the last word, so the idle
      # query — which reads those clocks — cannot see this case at all.
      assert_predicate @ticket, :awaiting_requester?
      assert_empty Ticket.open.assistant_idle_since(1.minute.from_now).to_a

      turns = []
      SupportDesk.on(:assistant_turn) { |_ticket, _assistant, _message, turn:| turns << turn }

      travel 10.minutes do
        SupportDesk.redispatch_assistant_turns!
      end

      refute_equal held, @ticket.reload.assistant_turn, "redispatch never repaired the case"
      assert_awaiting_reply @ticket
      assert_includes turns, @ticket.assistant_turn, "the repaired case has to end in an actionable turn"
    end

    test "the repair outlives the answer whose turn it made stale" do
      Ticket.stub(:for_conversation, nil) { ask_again(@ticket, "¿hay novedades?") }
      @ticket.reload
      held = @ticket.assistant_turn

      assert_raises(StaleTurn) { @ticket.respond!("Respuesta vieja", by: @rose, turn: held) }

      # In 0.3.0 the refusal rolled the registration back with it and the next
      # run read the very same revision — the same refusal, for ever.
      refute_equal held, @ticket.reload.assistant_turn
      assert_awaiting_reply @ticket
      @ticket.respond!("Respuesta al día", by: @rose, turn: @ticket.assistant_turn)

      assert_awaiting_requester @ticket
    end

    # --- Outreach ----------------------------------------------------------------

    test "she may not write first unless she is allowed to and works at :reply" do
      bob = create_user(name: "Bob")

      error = assert_raises(AssistantNotAllowed) do
        @rose.open_support_conversation_with!(bob, "Hola, te escribimos", topic: :order)
      end

      assert_match(/may not open conversations/, error.message)

      with_assistant_config(may_open_conversations: true, autonomy: :draft) do
        error = assert_raises(AssistantNotAllowed) do
          @rose.open_support_conversation_with!(bob, "Hola", topic: :order)
        end

        assert_match(/opening a case means speaking first/, error.message)
      end
    end

    test "a capped topic refuses her outreach" do
      bob = create_user(name: "Bob")

      with_assistant_config(may_open_conversations: true) do
        with_topic_assistant_cap("order", :draft) do
          error = assert_raises(AssistantNotAllowed) do
            @rose.open_support_conversation_with!(bob, "Hola", topic: :order)
          end

          assert_equal :open, error.verb
        end
      end
    end

    test "when she may, she is seated, disclosed and one turn down" do
      bob = create_user(name: "Bob")

      with_assistant_config(may_open_conversations: true, disclosure: :signature_and_notice) do
        turns = []
        SupportDesk.on(:assistant_turn) { |*| turns << true }

        ticket = @rose.open_support_conversation_with!(bob, "Hola, vimos que tu pedido se retrasó", topic: :order)

        assert_held_by_assistant ticket, @rose
        assert_equal "opened", ticket.assignments.open.first.reason
        assert_equal 1, ticket.assistant_turns_count
        assert_predicate ticket, :awaiting_requester?
        assert_empty turns, "nobody is owed an answer until the customer writes back"

        messages = ticket.conversation.messages.order(:created_at, :id).to_a
        notice = messages.find { |message| message.kind == "system" && message.body.match?(/virtual/) }
        hers = messages.find { |message| message.kind == "text" }

        assert_not_nil notice, "a notice mode introduces her before she speaks"
        assert_operator notice.created_at, :<, hers.created_at
        assert_equal @rose, hers.author
        assert_equal "rose", hers.metadata.dig("support_desk", "assistant")

        ask_again(ticket, "vale, gracias")

        assert_equal 1, turns.size, "and now there is something to answer"
      end
    end

    test "writing into a case that already exists is an ordinary reply, with her full rules" do
      with_assistant_config(may_open_conversations: true) do
        reused = @rose.open_support_conversation_with!(@alice, "¿Sigues teniendo el problema?", topic: :other)

        assert_equal @ticket.id, reused.id, "the open case is the case"
        assert_equal 1, reused.reload.assistant_turns_count
        assert_predicate reused, :awaiting_requester?
      end
    end

    test "a case she may not answer refuses her outreach into it too" do
      @ticket.assign!(to: @lucia, by: @lucia)

      with_assistant_config(may_open_conversations: true) do
        assert_raises(AssistantNotAllowed) do
          @rose.open_support_conversation_with!(@alice, "Hola otra vez", topic: :other)
        end
      end
    end

    # --- The record --------------------------------------------------------------

    test "deactivating her stops everything, everywhere, without a deploy" do
      @ticket.assign!(to: @rose, by: @rose, turn: @ticket.reload.assistant_turn)

      @rose.deactivate!(by: @lucia, reason: "el modelo está caído")

      refute_predicate @rose.reload, :active?
      refute_predicate @rose, :on_duty?
      refute_predicate @rose, :support_agent?
      assert_assistant_policy @ticket, :off, because: "rose is inactive"
      assert_empty @ticket.actions_for(@rose)

      @rose.activate!(by: @lucia)

      assert_predicate @rose.reload, :active?
    end

    test "she knows which desks are hers and what she is holding" do
      @ticket.assign!(to: @rose, by: @rose, turn: @ticket.reload.assistant_turn)

      assert_equal [ SupportDesk.desk ], @rose.desks
      assert_equal [ @ticket ], @rose.held_tickets.to_a
      assert_match(/rose .*resolve active/, @rose.inspect)
    end

    test "an assistant nobody configures any more still renders, and may do nothing" do
      SupportDesk.reset!
      configure_support_desk!
      orphan = Assistant.find_by(key: "rose")

      assert_not_nil orphan
      refute_predicate orphan, :configured?
      assert_equal "Rose", orphan.name
      assert_equal :off, orphan.autonomy
      refute_predicate orphan, :disclosed?
    end
  end
end
