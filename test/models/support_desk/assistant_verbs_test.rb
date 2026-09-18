# frozen_string_literal: true

require "test_helper"

module SupportDesk
  # §12.4 — the verb matrix. What the assistant may press, level by level and
  # state by state, checked against the transitions AND against
  # `actions_for`, because a console that renders one set and accepts another
  # has a UI that lies.
  class AssistantVerbsTest < ActiveSupport::TestCase
    # A host's own `kind: :ai` model. It is a perfectly good agent as far as
    # 0.2 was concerned — which is the point: 0.3 refuses it everywhere.
    class HostBot < ActiveRecord::Base
      self.table_name = "users"
      acts_as_messager
      acts_as_support_agent kind: :ai
    end

    setup do
      @alice = create_user(name: "Alice")
      @lucia = create_agent(name: "Lucía")
      @rose = configure_assistant!(autonomy: :resolve)
      @ticket = ticket_for(@alice, message: "Hola")
    end

    def turn = @ticket.reload.assistant_turn

    # --- Level by level ----------------------------------------------------------

    test "note is hers from :observe up, and refused below" do
      with_assistant_config(autonomy: :observe) do
        assert @ticket.note!("mirando", by: @rose, turn: turn)
      end

      with_assistant_config(autonomy: :off) do
        error = assert_raises(AssistantNotAllowed) { @ticket.note!("mirando", by: @rose, turn: turn) }

        assert_equal :note, error.verb
        assert_match(/rose may not note on #{@ticket.reference}/, error.message)
        assert_match(/autonomy is off/, error.message)
      end
    end

    test "draft! is hers from :draft up" do
      with_assistant_config(autonomy: :observe) do
        assert_raises(AssistantNotAllowed) { @ticket.draft!("propuesta", by: @rose, turn: turn) }
      end

      with_assistant_config(autonomy: :draft) do
        assert_kind_of Draft, @ticket.draft!("propuesta", by: @rose, turn: turn)
      end
    end

    test "reply! is hers from :reply up" do
      with_assistant_config(autonomy: :draft) do
        error = assert_raises(AssistantNotAllowed) { @ticket.reply!("hola", by: @rose, turn: turn) }

        assert_equal :reply, error.verb
      end

      with_assistant_config(autonomy: :reply) do
        assert_kind_of Chats::Message, @ticket.reply!("hola", by: @rose, turn: turn)
      end
    end

    test "close! is hers only at :resolve, and only on a case she holds" do
      with_assistant_config(autonomy: :reply) do
        @ticket.reply!("hola", by: @rose, turn: turn)

        assert_raises(AssistantNotAllowed) { @ticket.close!(by: @rose, turn: turn) }
      end

      with_assistant_config(autonomy: :resolve) do
        @ticket.close!(by: @rose, turn: turn)

        assert_ticket_closed @ticket
      end
    end

    test "close! is refused while the customer is still owed an answer" do
      @ticket.assign!(to: @rose, by: @lucia)

      assert_predicate @ticket, :awaiting_reply?
      assert_raises(AssistantNotAllowed) { @ticket.close!(by: @rose, turn: turn) }
    end

    test "close! is refused once somebody has asked for a person" do
      @ticket.reply!("hola", by: @rose, turn: turn)
      @ticket.request_human!(by: @alice)

      assert_raises(AssistantNotAllowed) { @ticket.close!(by: @rose, turn: turn) }
      assert_ticket_open @ticket
    end

    test "release! is her own seat and nobody else's" do
      @ticket.assign!(to: @lucia, by: @lucia)

      assert_raises(AssistantNotAllowed) { @ticket.release!(by: @rose) }
      assert_assigned_to @ticket, @lucia

      @ticket.release!(by: @lucia)
      @ticket.assign!(to: @rose, by: @lucia)
      @ticket.release!(by: @rose)

      assert_unassigned @ticket
    end

    # --- What she may never do ---------------------------------------------------

    test "she may not refile a case — triage is where authority comes from" do
      error = assert_raises(AssistantNotAllowed) { @ticket.change_topic!(to: :order, by: @rose) }

      assert_equal :triage, error.verb

      order = create_order(user: @alice)

      assert_raises(AssistantNotAllowed) { @ticket.attach_subject!(order, by: @rose) }
    end

    test "she may not hand a case to somebody — she escalates" do
      @ticket.assign!(to: @rose, by: @lucia)
      error = assert_raises(AssistantNotAllowed) { @ticket.hand_off!(to: @lucia, by: @rose) }

      assert_equal :hand_off, error.verb
    end

    test "she may not reopen a case" do
      @ticket.reply!("hola", by: @lucia)
      @ticket.close!(by: @lucia)

      assert_raises(AssistantNotAllowed) { @ticket.reopen!(by: @rose) }
      assert_ticket_closed @ticket
    end

    test "she may not assign anybody, including herself onto somebody else's case" do
      error = assert_raises(AssistantNotAllowed) { @ticket.assign!(to: @lucia, by: @rose) }

      assert_match(/can only take a case herself/, error.message)

      @ticket.assign!(to: @lucia, by: @lucia)

      assert_raises(AssistantNotAllowed) { @ticket.assign!(to: @rose, by: @rose) }
      assert_assigned_to @ticket, @lucia
    end

    test "she may take an unheld case at :reply and not below" do
      with_assistant_config(autonomy: :draft) do
        assert_raises(AssistantNotAllowed) { @ticket.assign!(to: @rose, by: @rose) }
      end

      with_assistant_config(autonomy: :reply) do
        @ticket.assign!(to: @rose, by: @rose)

        assert_held_by_assistant @ticket, @rose
      end
    end

    test "she may not approve or reject a proposal, even her own" do
      draft = @ticket.draft!("propuesta", by: @rose, turn: turn)

      assert_raises(NotAllowed) { draft.send!(by: @rose, seen_turn: turn) }
      assert_raises(NotAllowed) { draft.reject!(by: @rose) }
      assert_predicate draft.reload, :pending?
    end

    test "she may not resume herself" do
      @ticket.pause_assistant!(by: @lucia)

      assert_raises(NotAllowed) { @ticket.resume_assistant!(by: @rose) }
      assert_raises(NotAllowed) { @ticket.pause_assistant!(by: @rose) }
    end

    # --- Who she has to be -------------------------------------------------------

    test "a host's own kind: :ai model is refused on every verb" do
      bot = HostBot.create!(name: "Botty", admin: true)

      assert SupportDesk.ai_actor?(bot)
      assert_raises(NotAnAssistant) { @ticket.reply!("hola", by: bot) }
      assert_raises(NotAnAssistant) { @ticket.note!("hola", by: bot) }
      assert_raises(NotAnAssistant) { @ticket.close!(by: bot) }
      assert_raises(NotAnAssistant) { @ticket.assign!(to: bot, by: @lucia) }
      assert_raises(NotAnAssistant) { @ticket.release!(by: bot) }
      assert_raises(NotAnAssistant) { @ticket.change_topic!(to: :order, by: bot) }
      assert_raises(NotAnAssistant) { @ticket.respond!("hola", by: bot, turn: turn) }
      assert_raises(NotAnAssistant) { @ticket.escalate!(by: bot, reason: "x", turn: turn) }
    end

    test "a host's own kind: :ai model can't approve a proposal either" do
      bot = HostBot.create!(name: "Botty", admin: true)
      draft = @ticket.draft!("propuesta", by: @rose, turn: turn)

      assert_raises(NotAllowed) { draft.send!(by: bot, seen_turn: turn) }
    end

    test "another desk's assistant is not this desk's" do
      SupportDesk.configure do |config|
        config.assistant(:max) { |assistant| assistant.disclosure = :none }
        config.default_assistant = :rose
        config.desk(:billing) { |desk| desk.assistant = :max }
      end
      max = SupportDesk.assistant(:max)

      assert_raises(NotAnAssistant) { @ticket.respond!("hola", by: max, turn: turn) }
      assert_raises(NotAnAssistant) { @ticket.note!("hola", by: max, turn: turn) }
    end

    test "a deactivated assistant may do nothing" do
      @rose.deactivate!(by: @lucia)

      assert_raises(NotAnAgent) { @ticket.respond!("hola", by: @rose, turn: turn) }
      assert_raises(NotAnAgent) { @ticket.note!("hola", by: @rose, turn: turn) }
    end

    # --- actions_for -------------------------------------------------------------

    test "actions_for offers her exactly what the policy allows, state by state" do
      # Unheld, awaiting her, at :resolve.
      assert_equal %i[note escalate release draft reply take close].sort - %i[release close],
                   @ticket.actions_for(@rose).sort

      @ticket.assign!(to: @rose, by: @rose)

      assert_includes @ticket.actions_for(@rose), :release
      assert_not_includes @ticket.actions_for(@rose), :take, "she already has it"

      @ticket.reply!("hola", by: @rose, turn: turn)

      assert_includes @ticket.actions_for(@rose), :close, "held, and the customer has the last word"
      assert_not_includes @ticket.actions_for(@rose), :reply, "it isn't her turn"
    end

    test "actions_for drops everything that speaks when there is nobody to speak to" do
      @ticket.assign!(to: @rose, by: @rose)
      @alice.update!(support_blocked: true)

      assert_equal %i[note escalate release], @ticket.reload.actions_for(@rose)
    end

    test "actions_for on a closed case is looking, and not even escalating" do
      @ticket.reply!("hola", by: @lucia)
      @ticket.close!(by: @lucia)

      assert_equal %i[note], @ticket.actions_for(@rose)
    end

    test "actions_for is empty for a machine that isn't this desk's assistant" do
      bot = HostBot.create!(name: "Botty", admin: true)

      assert_empty @ticket.actions_for(bot)
    end

    test "actions_for offers a person the draft verbs and the pause switch" do
      @ticket.draft!("propuesta", by: @rose, turn: turn)

      actions = @ticket.reload.actions_for(@lucia)

      assert_includes actions, :send_draft
      assert_includes actions, :reject_draft
      assert_includes actions, :pause_assistant

      @ticket.pause_assistant!(by: @lucia)

      assert_includes @ticket.actions_for(@lucia), :resume_assistant
      assert_not_includes @ticket.actions_for(@lucia), :send_draft, "pausing threw the proposal away"
    end
  end
end
