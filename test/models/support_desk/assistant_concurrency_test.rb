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

        # Whether SHE answered is the race's to decide; the customer's own
        # message is not. (Until 0.3.1 this counted three messages, which
        # quietly also demanded that she always got her answer in — the very
        # thing the conversation lock now refuses when the question commits
        # first.)
        assert_includes @ticket.conversation.messages.where(kind: "text").pluck(:body), "¿hay novedades?",
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

      # --- The customer's own write, against the lock (R1) -------------------

      test "an answer is refused when the customer's next question commits behind it" do
        held = @ticket.assistant_turn
        result = nil

        with_requester_writing_behind_the_lock("¿Y el reembolso?") do
          result = begin
            @ticket.respond!("Le respondo a la primera pregunta", by: @rose, turn: held)
          rescue StaleTurn => e
            e
          end
        end

        assert_includes conversation_bodies, "¿Y el reembolso?", "the barrier has to actually write"
        refute(result.is_a?(Outcome) && result.sent?,
               "she answered around a question that had already committed")
        assert_empty assistant_messages
      end

      test "a proposal is refused when the customer's next question commits behind the approval" do
        with_assistant_config(autonomy: :draft) do
          draft = @ticket.draft!("propuesta", by: @rose, turn: @ticket.assistant_turn)
          @ticket.reload
          held = @ticket.assistant_turn
          result = nil

          with_requester_writing_behind_the_lock("Da igual, era otra cosa") do
            result = begin
              draft.send!(by: @lucia, seen_turn: held)
            rescue StaleTurn => e
              e
            end
          end

          assert_includes conversation_bodies, "Da igual, era otra cosa", "the barrier has to actually write"
          refute_instance_of(Chats::Message, result,
                             "a proposal was approved from a page that predated the next question")
          assert_predicate draft.reload, :pending?
        end
      end

      test "the sweep racing a takeover never moves a person's seat" do
        SupportDesk.config.assistant(:rose).responds_within = 1
        @ticket.assign!(to: @rose, by: @rose, turn: @ticket.reload.assistant_turn)
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

    def conversation_bodies
      @ticket.conversation.messages.where(kind: "text").order(:created_at, :id).pluck(:body)
    end

    # Commit a requester message in the window between "the answer has read
    # the case" and "the answer writes to it", from a second connection, and
    # run +block+ inside that window. Nothing here suspends a callback or
    # patches a transition: the message is an ordinary `message!`.
    #
    # The writer holds its transaction open — and with it the conversation
    # row chats updates inside every message insert — until EITHER the answer
    # reconciles (0.3.0: it read the transcript before this commit, so it
    # never saw the message) OR one second passes (0.3.1: the answer is
    # blocked on that very row, which is the whole fix). One barrier, two
    # schedules, and the rule is the same in both: a committed question is
    # never answered around.
    def with_requester_writing_behind_the_lock(body)
      inserted = ::Queue.new
      reconciled = ::Queue.new
      original = Ticket.instance_method(:reconcile_unregistered_messages!)
      Ticket.send(:define_method, :reconcile_unregistered_messages!) do
        original.bind_call(self).tap { reconciled << true }
      end

      writer = ::Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.transaction do
            User.find(@alice.id).message!(Chats::Conversation.find(@ticket.conversation_id), body)
            inserted << true
            reconciled.pop(timeout: 1)
          end
        end
      end

      inserted.pop
      yield
    ensure
      Ticket.send(:define_method, :reconcile_unregistered_messages!, original) if original
      writer&.join(15)
    end

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
