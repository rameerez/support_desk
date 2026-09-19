# frozen_string_literal: true

require "test_helper"

module SupportDesk
  # §12.5 — `respond!`: the one verb a harness needs. It hands over an answer
  # and policy decides what that becomes — sent, drafted, or withheld with a
  # reason on the record.
  class AssistantRespondTest < ActiveSupport::TestCase
    setup do
      @alice = create_user(name: "Alice")
      @lucia = create_agent(name: "Lucía")
      @rose = configure_assistant!(autonomy: :reply, disclosure: :signature)
      @ticket = ticket_for(@alice, message: "No me llega el pedido")
    end

    def turn = @ticket.reload.assistant_turn

    def respond(body = "Lo miramos ahora", **options)
      @ticket.respond!(body, by: @rose, turn: options.delete(:turn) || turn, **options)
    end

    # --- Sent --------------------------------------------------------------------

    test "at :reply she answers, takes the case and stops the clock" do
      outcome = respond

      assert_predicate outcome, :sent?
      assert_equal "Lo miramos ahora", outcome.message.body
      assert_awaiting_requester @ticket
      assert_held_by_assistant @ticket, @rose
      assert_equal 1, @ticket.reload.assistant_turns_count
      assert_not_nil @ticket.first_agent_reply_at
      assert_not_nil @ticket.assistant_acted_at
    end

    test "the message carries the whole decision" do
      outcome = respond("Aquí tienes", confidence: 0.82, sources: [ { "title" => "Ayuda", "url" => "https://x.test/a" } ],
                        metadata: { "model" => "test-1" })
      stamp = outcome.message.metadata["support_desk"]

      assert_equal "rose", stamp["assistant"]
      assert_equal "ai", stamp["kind"]
      assert_equal "signature", stamp["disclosure"]
      assert_equal true, stamp["signed"]
      assert_in_delta 0.82, stamp["confidence"]
      assert_equal [ { "title" => "Ayuda", "url" => "https://x.test/a" } ], stamp["sources"]
      assert_equal "reply", stamp.dig("policy", "level")
      assert_equal({ "model" => "test-1" }, outcome.message.metadata["host"], "the host's own metadata is nested")
      assert @ticket.assistant_message?(outcome.message)
    end

    test "the successor turn is the one a second action has to hold" do
      before = turn
      outcome = respond

      assert_equal @ticket.reload.assistant_turn, outcome.turn
      assert_not_equal before, outcome.turn, "the answer consumed the turn it held"
    end

    test "she is seated without an announcement — her disclosure is her introduction" do
      with_support_config(announce_assignments: :always) do
        respond

        system_lines = @ticket.conversation.messages.where(kind: "system").pluck(:body)

        assert_empty system_lines.grep(/taking care|se ocupa/),
                     "nobody was told a person picked this up"
        assert_equal "taken", @ticket.assignments.open.first.reason
      end
    end

    test "agent_replied fires exactly as it does for a person" do
      seen = []
      SupportDesk.on(:agent_replied) { |_ticket, message| seen << message.body }

      respond

      assert_equal [ "Lo miramos ahora" ], seen
    end

    # --- Drafted -----------------------------------------------------------------

    test "at :draft she proposes, says nothing, and leaves the case where it was" do
      with_assistant_config(autonomy: :draft) do
        outcome = respond

        assert_predicate outcome, :drafted?
        assert_equal "Lo miramos ahora", outcome.draft.body
        assert_equal "draft", outcome.draft.metadata.dig("policy", "level")
        assert_awaiting_reply @ticket
        assert_unassigned @ticket
        refute_assistant_spoke @ticket
        assert_equal 0, @ticket.reload.assistant_turns_count
      end
    end

    test "a human holding the case turns an answer into a proposal for them" do
      @ticket.assign!(to: @lucia, by: @lucia)
      outcome = respond

      assert_predicate outcome, :drafted?
      assert_assigned_to @ticket, @lucia
      assert_match(/Lucía holds the case/, outcome.policy.because)
    end

    test "a newer proposal supersedes the one before it" do
      with_assistant_config(autonomy: :draft) do
        first = respond("Primera").draft
        second = respond("Segunda")

        assert_predicate first.reload, :superseded?
        assert_equal second.draft.id, @ticket.reload.pending_draft.id
        assert_equal 1, @ticket.drafts.pending.count
      end
    end

    test "attachments alone are a whole answer" do
      with_assistant_config(autonomy: :draft) do
        outcome = @ticket.respond!(nil, by: @rose, turn: turn, files: [ fixture_file ])

        assert_predicate outcome, :drafted?
        assert_predicate outcome.draft.files, :attached?
      end
    end

    # --- Withheld ----------------------------------------------------------------

    test "below :draft she writes nothing, and the reason is on the record" do
      with_assistant_config(autonomy: :observe) do
        outcome = respond

        assert_predicate outcome, :withheld?
        assert_equal :policy, outcome.reason
        refute_assistant_spoke @ticket
        refute_pending_draft @ticket

        event = assert_ticket_event(@ticket, :assistant_withheld)

        assert_equal "policy", event.payload["reason"]
        assert_equal "rose", event.payload["assistant"]
        assert_equal "observe", event.payload.dig("policy", "level")
      end
    end

    test "answering when it isn't her turn is withheld, not an error" do
      respond
      outcome = respond("¿Algo más?")

      assert_predicate outcome, :withheld?
      assert_equal :not_your_turn, outcome.reason
      assert_equal 1, @ticket.reload.assistant_turns_count
    end

    test "a pause withholds, and says which rule it was" do
      @ticket.pause_assistant!(by: @lucia, reason: "delicado")
      outcome = respond

      assert_predicate outcome, :withheld?
      assert_equal :policy, outcome.reason
      assert_match(/paused on this case/, outcome.policy.because)
    end

    test "withheld events are staff-only" do
      with_assistant_config(autonomy: :observe) { respond }

      assert_empty @ticket.events.requester_visible.of_kind(:assistant_withheld).to_a
    end

    # --- The budget --------------------------------------------------------------

    test "the last turn is spent, and the next one asks for a person" do
      with_assistant_config(autonomy: :reply, max_turns: 1) do
        respond

        assert_equal 0, @ticket.reload.assistant_turns_left

        ask_again(@ticket, "sigue sin llegar")
        outcome = respond("Sigo en ello")

        assert_predicate outcome, :drafted?, "out of budget, so a person sends it"
        assert_predicate outcome, :escalated?
        assert_equal :max_turns, outcome.reason
        assert_needs_human @ticket, reason: "max_turns"
        assert_unassigned @ticket, "her seat goes back"
        assert_equal Topic::PRIORITIES[:high], @ticket.reload.priority
        assert_pending_draft @ticket, body: "Sigo en ello"
      end
    end

    test "the hand-off line is posted once, however many turns run out" do
      with_assistant_config(autonomy: :reply, max_turns: 1) do
        respond
        ask_again(@ticket, "¿hola?")
        respond("otra")
        ask_again(@ticket, "¿sigues ahí?")
        respond("y otra")

        lines = @ticket.conversation.messages.where(kind: "system").pluck(:body)

        assert_equal 1, lines.count { |line| line.include?(I18n.t("support_desk.system.handed_off_to_humans")) }
      end
    end

    test "no budget at all means she never runs out" do
      with_assistant_config(autonomy: :reply, max_turns: nil) do
        assert_nil @ticket.assistant_turns_left

        3.times do |index|
          respond("Respuesta #{index}")
          ask_again(@ticket, "otra pregunta #{index}")
        end

        assert_equal 3, @ticket.reload.assistant_turns_count
        refute_needs_human @ticket
      end
    end

    # --- Refusals ----------------------------------------------------------------

    test "a person can't respond! — that verb is hers" do
      assert_raises(NotAnAssistant) { @ticket.respond!("hola", by: @lucia, turn: turn) }
    end

    test "respond! needs something to say" do
      assert_raises(ArgumentError) { respond(nil) }
      assert_raises(ArgumentError) { respond("   ") }
    end

    test "respond! without a turn is a bug in the harness, and says so" do
      error = assert_raises(ArgumentError) { @ticket.respond!("hola", by: @rose, turn: nil) }

      assert_match(/turn: is required/, error.message)
    end

    test "there is nobody to write to once the account is gone" do
      @alice.update!(support_blocked: true)

      assert_raises(Locked) { respond }
      refute_assistant_spoke @ticket
    end

    # --- Disclosure --------------------------------------------------------------

    test "a signed mode signs the bubble with the disclosed name" do
      outcome = respond

      assert_equal @rose, outcome.message.author
      assert_equal "Rose · virtual assistant", @rose.disclosed_name
      assert_match(/Rose/, Chats.message_signature_for(outcome.message).to_s)
    end

    test "a nameless mode posts no author, and the truth stays in the metadata" do
      with_assistant_config(disclosure: :none) do
        outcome = respond

        assert_nil outcome.message.author, "the requester sees the desk"
        refute_predicate outcome.message, :signed?
        assert_nil Chats.message_signature_for(outcome.message)
        assert_equal "rose", outcome.message.metadata.dig("support_desk", "assistant")
        assert @ticket.assistant_message?(outcome.message), "staff still see what wrote it"
        assert_equal "Rose", @rose.disclosed_name, "and an undisclosed name is not decorated"
      end
    end

    test "a notice mode opens the conversation with one, before the bubble" do
      with_assistant_config(disclosure: :notice) do
        outcome = respond

        notice = @ticket.conversation.messages.where(kind: "system").last

        assert_match(/asistente virtual|virtual assistant/, notice.body)
        assert_operator notice.created_at, :<, outcome.message.created_at,
                        "the notice introduces the message it precedes"

        ask_again(@ticket, "otra")
        respond("otra respuesta")

        assert_equal 1, @ticket.conversation.messages.where(kind: "system")
                              .count { |message| message.body.include?("virtual") },
                     "she introduces herself once"
      end
    end

    test "a notice mode with no line at all refuses to post silently" do
      with_assistant_config(disclosure: :notice, disclosure_line: ->(_ticket) { nil }) do
        assert_raises(ConfigurationError) { respond }
        refute_assistant_spoke @ticket
      end
    end

    test "the export names her whatever the mode" do
      with_assistant_config(disclosure: :none) do
        respond

        assert_includes @ticket.export[:messages].map { |message| message[:from] }, "assistant"
      end
    end

    private

    def fixture_file
      ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("captura"), filename: "captura.txt", content_type: "text/plain"
      )
    end
  end
end
