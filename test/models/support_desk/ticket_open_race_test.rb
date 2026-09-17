# frozen_string_literal: true

require "test_helper"

module SupportDesk
  # The real race, with two connections and real commits: two agents writing
  # first to the same person at the same instant. The suite's other
  # concurrency tests simulate the collision by blinding the pre-check, which
  # is the right shape but one writer; this is two.
  #
  # Real commits mean no transactional fixtures, so everything this writes is
  # deleted again on the way out.
  class TicketOpenRaceTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    teardown do
      Chats::Message.delete_all
      Chats::Participant.delete_all
      Chats::Conversation.delete_all
      Event.delete_all
      Assignment.delete_all
      Ticket.delete_all
      Desk.delete_all
      SupportDesk.reset_desks!
      Order.delete_all
      Invoice.delete_all
      User.delete_all
    end

    # DEFINED only on the PostgreSQL leg: SQLite takes one writer at a time
    # and has no row locks to race over, so there is nothing here it could
    # prove. Where it can run it must run — never skipped, never rescued into
    # a pass.
    if ActiveRecord::Base.connection.adapter_name.match?(/\Apostg/i)
      test "two agents writing first at the same instant land in one case" do
        alice = create_user(name: "Alice")
        lucia = create_agent(name: "Lucía")
        pedro = create_agent(name: "Pedro")
        opened = Concurrent::Array.new
        SupportDesk.on(:ticket_opened) { |ticket| opened << ticket.id }
        # Both threads have to be inside `open!` before either commits, or
        # this is two sequential opens wearing a costume.
        barrier = Concurrent::CyclicBarrier.new(2)

        tickets = [ [ lucia, "Vimos que tu pedido no llegó" ], [ pedro, "Te escribimos por lo mismo" ] ].map do |agent, body|
          Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do
              barrier.wait(5)
              agent.open_support_conversation_with!(alice, body, topic: :account)
            end
          end
        end.map(&:value)

        assert_equal 1, Ticket.count, "one case, whoever got there first"
        assert_equal tickets.first.id, tickets.last.id
        assert_equal [ tickets.first.id ], opened.to_a, "exactly one ticket_opened for one case"

        ticket = Ticket.find(tickets.first.id)

        assert_equal 2, ticket.messages.where(kind: "text").count
        assert_predicate ticket, :opened_by_support?
        assert_predicate ticket, :assigned?
        assert_equal 1, ticket.assignments.open.count
        assert_equal "requester", ticket.awaiting
      end
    end
  end
end
