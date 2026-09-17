# frozen_string_literal: true

require "test_helper"

module SupportDesk
  # Writing first to somebody who already has this conversation open is a
  # REPLY, and the promise is exact: the same thing `reply!` would have done,
  # whichever way the case was found — by the pre-check, or by losing the
  # insert race to somebody else's INSERT a millisecond earlier.
  #
  # So the tests compare the two outcomes rather than describing one of them:
  # a reuse path that grew its own policy, its own assignment or its own
  # silence would show up as a difference, not as a missing assertion.
  class TicketReuseTest < ActiveSupport::TestCase
    POLICIES = %i[anyone take_over assignee_only].freeze
    HOLDERS = %i[unassigned own other released].freeze

    setup do
      @lucia = create_agent(name: "Lucía")
      @pedro = create_agent(name: "Pedro")
    end

    test "reuse has exactly the reply-policy effects reply! has" do
      POLICIES.each do |policy|
        HOLDERS.each do |holder|
          expected = outcome(policy: policy, holder: holder) do |ticket, agent|
            ticket.reply!("lo estamos mirando", by: agent)
          end
          actual = outcome(policy: policy, holder: holder) do |ticket, agent|
            agent.open_support_conversation_with!(ticket.requester, "lo estamos mirando", topic: :account)
          end

          assert_equal expected, actual, "reuse under #{policy} on a #{holder} case"
        end
      end
    end

    test "and so does the case this call lost the insert race to" do
      skip_unless_partial_indexes

      POLICIES.each do |policy|
        HOLDERS.each do |holder|
          expected = outcome(policy: policy, holder: holder) do |ticket, agent|
            ticket.reply!("lo estamos mirando", by: agent)
          end
          actual = outcome(policy: policy, holder: holder) do |ticket, agent|
            blind_the_pre_check do
              agent.open_support_conversation_with!(ticket.requester, "lo estamos mirando", topic: :account)
            end
          end

          assert_equal expected, actual, "an insert loser under #{policy} on a #{holder} case"
        end
      end
    end

    test "a new case is the one shape that is not a reply" do
      ticket = @lucia.open_support_conversation_with!(create_user(name: "Bea"), "Vimos que…", topic: :account)

      assert_equal %w[opened], ticket.assignments.chronological.map(&:reason)
      assert_equal %w[opened], ticket.events.chronological.map(&:kind)
      assert_assigned_to ticket, @lucia
    end

    test "reuse never rewrites who opened the case, or its clocks, behind the reply" do
      requester = create_user(name: "Bea")
      written = @lucia.open_support_conversation_with!(requester, "Vimos que…", topic: :account)
      ask_again written, "cuéntame"

      again = @pedro.open_support_conversation_with!(requester, "te cuento", topic: :account)

      assert_equal written.id, again.id
      assert_equal @lucia, again.opened_by
      assert_equal "requester", again.awaiting
      assert_equal again.last_agent_message_at, again.waiting_since
      assert_equal 3, again.messages.where(kind: "text").count
    end

    test "a case that closed between the lookup and the lock is reopened by the requester, not by us" do
      requester = create_user(name: "Bea")
      ticket = requester.ask_support!("hola", topic: :account)

      # The pre-check saw an open case; by the time we hold the lock another
      # agent has closed it. An agent's own last word must not put it back in
      # the queue, and must not invent a reopen nobody asked for.
      close_between_lookup_and_lock(ticket) do
        @lucia.open_support_conversation_with!(requester, "una última cosa", topic: :account)
      end

      assert_equal 1, Ticket.count, "the stale read is answered, not opened again"
      assert_ticket_closed ticket
      assert_equal 0, ticket.reload.reopen_count
      assert_nil ticket.waiting_since
      assert_not_nil ticket.last_agent_message_at

      # The requester writing into it is what reopens it, exactly as always.
      ask_again ticket, "sigo con el problema"

      assert_ticket_open ticket
      assert_equal 1, ticket.reload.reopen_count
    end

    test "a stale assignee doesn't overwrite the seat somebody else took" do
      requester = create_user(name: "Bea")
      ticket = requester.ask_support!("hola", topic: :account)
      stale = Ticket.find(ticket.id)
      ticket.assign!(to: @pedro, by: @pedro)

      # `stale` still thinks the case is unassigned. Under :anyone a drop-in
      # leaves the holder alone, and the lock is what makes the write read
      # today's row rather than the one this instance remembers.
      stale.reply!("lo estamos mirando", by: @lucia)

      assert_assigned_to ticket, @pedro
      assert_equal %w[taken], ticket.assignments.chronological.map(&:reason)
      assert_ticket_event ticket, :drop_in
    end

    private

    # One case in one state, one write, and everything that write could have
    # changed — the comparable shape the two paths have to agree on.
    def outcome(policy:, holder:)
      requester = create_user(name: "R#{SecureRandom.hex(3)}")
      ticket = requester.ask_support!("hola", topic: :account)

      case holder
      when :own then ticket.assign!(to: @lucia, by: @lucia)
      when :other then ticket.assign!(to: @pedro, by: @pedro)
      when :released
        ticket.assign!(to: @pedro, by: @pedro)
        ticket.release!(by: @pedro)
      end

      error = nil
      with_support_config(reply_policy: policy) do
        yield ticket, @lucia
      rescue SupportDesk::Error, ActiveRecord::RecordInvalid => e
        error = e.class.name
      end

      ticket.reload
      {
        error: error,
        assignee: ticket.assignee&.support_agent_name,
        assignments: ticket.assignments.chronological.map { |assignment| [ assignment.reason, assignment.release_reason ] },
        events: ticket.events.chronological.map(&:kind),
        bodies: ticket.messages.where(kind: "text").oldest_first.map(&:body),
        awaiting: ticket.awaiting,
        opened_by_support: ticket.opened_by_support?
      }
    end

    # The state a real race leaves behind: the row the other request
    # committed a millisecond ago wasn't visible to our pre-check, so the
    # INSERT is what catches it.
    def blind_the_pre_check
      original = Ticket.method(:open_ticket_for)
      checks = 0
      blind_once = lambda do |**arguments|
        checks += 1
        checks == 1 ? nil : original.call(**arguments)
      end

      Ticket.stub(:open_ticket_for, blind_once) { yield }
    end

    # The state a concurrent close leaves behind: the row is closed, and the
    # answer our pre-check already gave still says open. Stubbing the lookup
    # is how a test holds that instant still.
    def close_between_lookup_and_lock(ticket)
      Ticket.find(ticket.id).close!(by: @pedro)

      Ticket.stub(:existing_for, ->(**_arguments) { ticket }) { yield }
    end
  end
end
