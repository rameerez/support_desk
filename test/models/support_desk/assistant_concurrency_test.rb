# frozen_string_literal: true

require "test_helper"

module SupportDesk
  # §12.6, the half that needs two connections: what happens when a model's
  # answer, a customer's next message and a sweep all arrive at once.
  #
  # The threaded examples are DEFINED only on PostgreSQL — SQLite takes one
  # writer at a time and has no row locks to race over, so there would be
  # nothing there for them to prove — and never skipped where they can run.
  # Every scenario also has a sequential twin that runs on every adapter,
  # because the RULE ("one reply per turn") has to hold either way.
  #
  # Real commits mean no transactional fixtures, so everything this writes is
  # deleted again on the way out.
  class AssistantConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    setup do
      @alice = create_user(name: "Alice")
      @lucia = create_agent(name: "Lucía")
      @rose = configure_assistant!(autonomy: :reply)
      @ticket = ticket_for(@alice, message: "No me llega el pedido")
    end

    teardown do
      Chats::Message.delete_all
      Chats::Participant.delete_all
      Chats::Conversation.delete_all
      Draft.delete_all
      Event.delete_all
      Assignment.delete_all
      Ticket.delete_all
      Assistant.delete_all
      Desk.delete_all
      SupportDesk.reset_desks!
      SupportDesk.reset_assistants!
      Order.delete_all
      Invoice.delete_all
      User.delete_all
    end

    def assistant_messages
      @ticket.conversation.messages.where(kind: "text").to_a.select { |message| @ticket.assistant_message?(message) }
    end

    # --- Sequentially, everywhere ------------------------------------------------

    test "the same turn twice is one answer and one refusal" do
      held = @ticket.assistant_turn

      @ticket.respond!("Ya lo miramos", by: @rose, turn: held)

      assert_raises(StaleTurn) { Ticket.find(@ticket.id).respond!("Ya lo miramos", by: @rose, turn: held) }
      assert_equal 1, assistant_messages.size
    end

    test "the same turn twice is one proposal and one refusal" do
      with_assistant_config(autonomy: :draft) do
        held = @ticket.assistant_turn

        @ticket.draft!("propuesta", by: @rose, turn: held)

        assert_raises(StaleTurn) { Ticket.find(@ticket.id).draft!("otra", by: @rose, turn: held) }
        assert_equal 1, Draft.pending.count
      end
    end

    test "a customer writing first makes the answer a refusal, never a second bubble" do
      held = @ticket.assistant_turn
      ask_again(@ticket, "¿hay novedades?")

      assert_raises(StaleTurn) { Ticket.find(@ticket.id).respond!("Ya lo miramos", by: @rose, turn: held) }
      assert_empty assistant_messages
      assert_awaiting_reply @ticket
    end

    # --- With two connections ----------------------------------------------------

    if ActiveRecord::Base.connection.adapter_name.match?(/\Apostg/i)
      test "two answers on one turn leave one message" do
        held = @ticket.assistant_turn
        results = run_together(2) do
          Ticket.find(@ticket.id).respond!("Ya lo miramos", by: SupportDesk.assistant(:rose), turn: held)
        end

        assert_equal 1, results.count { |result| result.is_a?(Outcome) && result.sent? }
        assert_equal 1, results.count { |result| result.is_a?(StaleTurn) }
        assert_equal 1, assistant_messages.size
        assert_equal 1, @ticket.reload.assistant_turns_count
      end

      test "two proposals on one turn leave one pending" do
        SupportDesk.config.assistant(:rose).autonomy = :draft
        held = @ticket.assistant_turn
        results = run_together(2) do
          Ticket.find(@ticket.id).draft!("propuesta", by: SupportDesk.assistant(:rose), turn: held)
        end

        assert_equal 1, results.count { |result| result.is_a?(Draft) }
        assert_equal 1, results.count { |result| result.is_a?(StaleTurn) }
        assert_equal 1, Draft.pending.count
      end

      test "an answer racing the customer's next message never answers around it" do
        held = @ticket.assistant_turn
        results = run_together(2) do |index|
          if index.zero?
            Ticket.find(@ticket.id).respond!("Ya lo miramos", by: SupportDesk.assistant(:rose), turn: held)
          else
            User.find(@alice.id).message!(Chats::Conversation.find(@ticket.conversation_id), "¿hay novedades?")
          end
        end

        answer = results.first

        assert_equal 2, @ticket.conversation.messages.where(kind: "text").count - 1,
                     "the customer's message always lands"
        assert_operator assistant_messages.size, :<=, 1, "never two answers to one question"

        if answer.is_a?(StaleTurn)
          assert_empty assistant_messages, "she read a case that had already moved on"
        else
          assert_predicate answer, :sent?
          assert_operator assistant_messages.first.created_at, :<=,
                          @ticket.conversation.messages.where(kind: "text").order(:created_at, :id).last.created_at,
                          "her answer precedes the message that made the next turn"
        end
      end

      test "the sweep racing a takeover never moves a person's seat" do
        SupportDesk.config.assistant(:rose).responds_within = 1
        @ticket.assign!(to: @rose, by: @rose)
        Ticket.where(id: @ticket.id).update_all(waiting_since: 1.hour.ago)

        results = run_together(2) do |index|
          if index.zero?
            SupportDesk.release_silent_assistants!
          else
            Ticket.find(@ticket.id).assign!(to: User.find(@lucia.id), by: User.find(@lucia.id))
          end
        end

        assert_empty results.grep(StandardError), results.grep(StandardError).map(&:message).inspect
        @ticket.reload

        # Either order is correct. What is never correct is a case that
        # waited an hour and has neither a person on it nor one asked for.
        assert(@ticket.assigned_to?(@lucia) || @ticket.human_required?,
               "the case ended up with nobody and no request for anybody")
        refute_predicate @ticket, :held_by_assistant?
      end
    end

    private

    # Run +count+ blocks at once, each on its own connection, and hand back
    # what each of them returned — or the exception it raised, because a
    # refusal IS the result in most of these.
    def run_together(count)
      threads = Array.new(count) do |index|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            yield index
          rescue StandardError => e
            e
          end
        end
      end
      threads.map(&:value)
    ensure
      threads&.each(&:join)
    end
  end
end
