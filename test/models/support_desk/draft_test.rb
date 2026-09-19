# frozen_string_literal: true

require "test_helper"

module SupportDesk
  # §12.7 — the proposal, and the person who decides about it.
  #
  # A sent draft is the HUMAN's message: they read it, they own it, and the
  # requester sees their signature. What the machine contributed is
  # provenance — in the message's metadata and in this row.
  class DraftTest < ActiveSupport::TestCase
    setup do
      @alice = create_user(name: "Alice")
      @lucia = create_agent(name: "Lucía")
      @rose = configure_assistant!(autonomy: :draft)
      @ticket = ticket_for(@alice, message: "No me llega el pedido")
      @draft = @ticket.draft!("Ya lo estamos mirando", by: @rose, turn: @ticket.assistant_turn,
                                                       confidence: 0.9)
    end

    def turn = @ticket.reload.assistant_turn

    # --- The row -----------------------------------------------------------------

    test "a fresh proposal is pending, hers, and stamped with the turn it answered" do
      assert_predicate @draft, :pending?
      assert_equal @rose, @draft.author
      assert_equal SupportDesk.actor_key(@rose), @draft.author_key
      assert_equal 90, @draft.confidence_percent
      assert_equal "Ya lo estamos mirando", @draft.final_body
      refute_predicate @draft, :edited?
      assert_equal @draft, @ticket.reload.pending_draft
    end

    test "the scopes partition by what a person decided" do
      assert_includes Draft.pending, @draft
      assert_includes Draft.by(@rose), @draft
      assert_empty Draft.reviewed

      @draft.send!(by: @lucia, seen_turn: turn)

      assert_includes Draft.sent, @draft
      assert_includes Draft.verbatim, @draft
      assert_includes Draft.reviewed, @draft
      assert_empty Draft.edited
      assert_empty Draft.pending
    end

    # --- Staleness ---------------------------------------------------------------

    test "anything at all makes it stale — that is what the turn is for" do
      refute_predicate @draft, :stale?

      @ticket.note!("una nota", by: @lucia)

      assert_predicate @draft.reload, :stale?
    end

    test "a customer writing again makes it stale" do
      ask_again(@ticket, "¿hay novedades?")

      assert_predicate @draft.reload, :stale?
    end

    # --- Sending -----------------------------------------------------------------

    test "sending it verbatim posts the human's message with the machine's provenance" do
      message = @draft.send!(by: @lucia, seen_turn: turn)

      assert_equal "Ya lo estamos mirando", message.body
      assert_equal @lucia, message.author, "the person who sent it signs it"
      assert_equal SupportDesk.actor_key(@rose), message.metadata.dig("support_desk", "drafted_by")
      assert_equal @draft.id.to_s, message.metadata.dig("support_desk", "draft_id")
      assert_equal false, message.metadata.dig("support_desk", "edited")
      refute @ticket.assistant_message?(message), "a person sent this one"

      @draft.reload

      assert_predicate @draft, :sent?
      assert_equal @lucia, @draft.reviewed_by
      assert_equal message.id, @draft.sent_message_id
      assert_nil @draft.sent_body, "verbatim keeps one body"
      assert_awaiting_requester @ticket
    end

    test "sending an edit keeps both what she wrote and what went out" do
      message = @draft.send!(by: @lucia, seen_turn: turn, body: "Casi: lo tienes mañana")

      assert_equal "Casi: lo tienes mañana", message.body
      assert_equal true, message.metadata.dig("support_desk", "edited")

      @draft.reload

      assert_predicate @draft, :edited?
      assert_equal "Casi: lo tienes mañana", @draft.sent_body
      assert_equal "Ya lo estamos mirando", @draft.body, "what she proposed is still readable"
      assert_equal "Casi: lo tienes mañana", @draft.final_body
    end

    test "sending it writes the whole decision to the timeline" do
      message = @draft.send!(by: @lucia, seen_turn: turn, body: "Editado")
      event = assert_ticket_event(@ticket, :draft_sent, by: @lucia)

      assert_equal @draft.id.to_s, event.payload["draft"]
      assert_equal SupportDesk.actor_key(@rose), event.payload["assistant"]
      assert_equal true, event.payload["edited"]
      assert_equal false, event.payload["was_stale"]
      assert_equal message.id.to_s, event.payload["message"]
      assert_empty @ticket.events.requester_visible.of_kind(:draft_sent).to_a
    end

    test "sending it emits draft_sent for the host to notify on" do
      seen = []
      SupportDesk.on(:draft_sent) { |ticket, draft, message, by:| seen << [ ticket.id, draft.id, message.id, by ] }

      message = @draft.send!(by: @lucia, seen_turn: turn)

      assert_equal [ [ @ticket.id, @draft.id, message.id, @lucia ] ], seen
    end

    test "the person who sends it takes the case over from her" do
      with_assistant_config(autonomy: :reply) { @ticket.assign!(to: @rose, by: @lucia) }
      @draft.send!(by: @lucia, seen_turn: turn)

      assert_assigned_to @ticket, @lucia
      assert_equal "drop_in_takeover", @ticket.assignments.open.first.reason
    end

    test "attachments ride along to the message" do
      draft = @ticket.draft!(nil, by: @rose, turn: turn, files: [ blob("captura.png") ])
      message = draft.send!(by: @lucia, seen_turn: turn)

      assert_equal [ "captura.png" ], message.files.map { |file| file.filename.to_s }
    end

    # --- Refusing to send --------------------------------------------------------

    test "a turn the reviewer never saw is refused, and the proposal survives" do
      stale = turn
      ask_again(@ticket, "¿hay novedades?")

      error = assert_raises(StaleTurn) { @draft.send!(by: @lucia, seen_turn: stale) }

      assert_match(/read it again/, error.message)
      assert_predicate @draft.reload, :pending?
      assert_awaiting_reply @ticket
    end

    test "re-reading the case is the only way to send a stale proposal" do
      ask_again(@ticket, "¿hay novedades?")

      assert_predicate @draft.reload, :stale?

      message = @draft.send!(by: @lucia, seen_turn: turn)

      assert_predicate @draft.reload, :sent?
      assert_equal true, assert_ticket_event(@ticket, :draft_sent).payload["was_stale"],
                   "it was stale when they sent it, and the record says so"
      assert_equal "Ya lo estamos mirando", message.body
    end

    test "seen_turn is not optional" do
      assert_raises(ArgumentError) { @draft.send!(by: @lucia, seen_turn: nil) }
      assert_raises(ArgumentError) { @draft.send!(by: @lucia, seen_turn: "") }
    end

    test "an edit can't be blank — that is what rejecting is for" do
      assert_raises(ArgumentError) { @draft.send!(by: @lucia, seen_turn: turn, body: "   ") }
      assert_predicate @draft.reload, :pending?
    end

    test "a proposal somebody already decided about can't be decided again" do
      @draft.send!(by: @lucia, seen_turn: turn)

      error = assert_raises(InvalidTransition) { @draft.send!(by: @lucia, seen_turn: turn) }

      assert_match(/is sent, not pending/, error.message)
      assert_raises(InvalidTransition) { @draft.reject!(by: @lucia) }
    end

    test "a machine never approves anything, its own work included" do
      assert_raises(NotAllowed) { @draft.send!(by: @rose, seen_turn: turn) }
      assert_raises(NotAllowed) { @draft.send!(by: :system, seen_turn: turn) }
      assert_raises(NotAnAgent) { @draft.send!(by: @alice, seen_turn: turn) }
    end

    # --- Rejecting ---------------------------------------------------------------

    test "rejecting keeps the reason, which is the number worth watching" do
      @draft.reject!(by: @lucia, reason: "no es eso")

      assert_predicate @draft.reload, :rejected?
      assert_equal "no es eso", @draft.rejection_reason
      assert_equal @lucia, @draft.reviewed_by
      assert_not_nil @draft.reviewed_at
      refute_pending_draft @ticket
      assert_awaiting_reply @ticket, "the customer is still owed an answer"

      event = assert_ticket_event(@ticket, :draft_rejected, by: @lucia)

      assert_equal "no es eso", event.payload["reason"]
    end

    test "rejecting emits draft_rejected" do
      seen = []
      SupportDesk.on(:draft_rejected) { |_ticket, draft, by:, reason:| seen << [ draft.id, by, reason ] }

      @draft.reject!(by: @lucia, reason: "no")

      assert_equal [ [ @draft.id, @lucia, "no" ] ], seen
    end

    # --- What throws it away -----------------------------------------------------

    test "a person answering by hand supersedes it" do
      @ticket.reply!("Te contesto yo", by: @lucia)

      assert_predicate @draft.reload, :superseded?
      refute_pending_draft @ticket
    end

    test "pausing her throws it away" do
      @ticket.pause_assistant!(by: @lucia)

      assert_predicate @draft.reload, :superseded?
    end

    test "closing the case expires it, and says how many" do
      # Closed by a person who never answered: the proposal is expired,
      # not superseded — nobody replaced it, the case just ended.
      @ticket.close!(by: @lucia)

      assert_predicate @draft.reload, :expired?
      assert_equal 1, @ticket.events.of_kind(:closed).first.payload["expired_drafts"]
    end

    test "sending one never supersedes itself" do
      @draft.send!(by: @lucia, seen_turn: turn)

      assert_predicate @draft.reload, :sent?, "the reply it posts must not throw it away on the way out"
    end

    # --- What the instance knows about itself ------------------------------------

    test "the case sees its own proposal without being reloaded" do
      ticket = ticket_for(@alice, topic: :order, message: "Otra consulta")

      outcome = ticket.respond!("Una propuesta", by: @rose, turn: ticket.assistant_turn)

      # No reload: a console renders from the instance it just wrote with,
      # and a button that only appears after a round trip is a button that
      # is missing when it matters.
      assert_equal outcome.draft, ticket.pending_draft
      assert_includes ticket.actions_for(@lucia), :send_draft

      ticket.pause_assistant!(by: @lucia)

      assert_nil ticket.pending_draft
      assert_not_includes ticket.actions_for(@lucia), :send_draft
    end

    test "sending and rejecting clear it on the same instance too" do
      assert_equal @draft, @ticket.pending_draft

      @draft.send!(by: @lucia, seen_turn: turn)

      assert_nil @ticket.pending_draft

      other = @ticket.draft!("otra", by: @rose, turn: turn)

      assert_equal other, @ticket.pending_draft

      other.reject!(by: @lucia)

      assert_nil @ticket.pending_draft
    end

    test "closing a case clears it on the same instance" do
      @ticket.close!(by: @lucia)

      assert_nil @ticket.pending_draft
    end

    # --- Validation --------------------------------------------------------------

    test "a proposal needs something in it" do
      error = assert_raises(ArgumentError) { @ticket.draft!(nil, by: @rose, turn: turn) }

      assert_match(/needs something to say/, error.message)
      # And the model says so too, for anything that writes a row directly.
      refute_predicate Draft.new(ticket: @ticket, author: @rose, proposed_turn: turn), :valid?
    end

    test "sources are checked like anything a stranger typed" do
      assert_raises(ActiveRecord::RecordInvalid) do
        @ticket.draft!("x", by: @rose, turn: turn, sources: [ { "title" => "x", "url" => "javascript:alert(1)" } ])
      end
      assert_raises(ActiveRecord::RecordInvalid) do
        @ticket.draft!("x", by: @rose, turn: turn,
                            sources: Array.new(21) { { "title" => "x", "url" => "https://x.test" } })
      end
      assert_raises(ActiveRecord::RecordInvalid) do
        @ticket.draft!("x", by: @rose, turn: turn, sources: [ { "title" => "y" * 501, "url" => nil } ])
      end

      draft = @ticket.draft!("x", by: @rose, turn: turn,
                                  sources: [ { "title" => "Ayuda", "url" => "https://x.test/a" },
                                             { "title" => "Sin enlace", "url" => nil } ])

      assert_equal 2, draft.sources.size
    end

    test "a source that isn't a pair at all is refused, not an exception" do
      # `["title", "x"].to_h` raises TypeError. A model wrote these, so the
      # shape is whatever came back, and a validation that raises is a 500
      # on the page that would have shown somebody what went wrong.
      [ [ [ "title", "x" ] ], [ "https://x.test" ], [ 42 ], [ [ [ 1, 2, 3 ] ] ] ].each do |sources|
        error = assert_raises(ActiveRecord::RecordInvalid) do
          @ticket.draft!("x", by: @rose, turn: turn, sources: sources)
        end

        assert_match(/title:, url: /, error.message, "#{sources.inspect} should say what it wanted")
      end

      assert_predicate @draft.reload, :pending?
    end

    test "a failed proposal never takes the pending one with it" do
      assert_raises(ActiveRecord::RecordInvalid) do
        @ticket.draft!("x", by: @rose, turn: turn, sources: [ { "title" => "x", "url" => "ftp://x.test" } ])
      end

      assert_predicate @draft.reload, :pending?, "validated before anything was superseded"
    end

    test "confidence is a probability or nothing" do
      assert_raises(ActiveRecord::RecordInvalid) { @ticket.draft!("x", by: @rose, turn: turn, confidence: 1.5) }

      draft = @ticket.draft!("x", by: @rose, turn: turn)

      assert_nil draft.confidence_percent
    end

    test "one pending proposal per case, whatever the adapter" do
      skip_unless_partial_indexes

      assert_raises(ActiveRecord::RecordNotUnique) do
        Draft.insert_all!([ { ticket_id: @ticket.id, author_type: @rose.class.polymorphic_name,
                             author_id: @rose.id, proposed_turn: turn, body: "otra", status: "pending",
                             created_at: Time.current, updated_at: Time.current } ])
      end
    end

    private

    def blob(filename)
      ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("contenido"), filename: filename, content_type: "image/png"
      )
    end
  end
end
