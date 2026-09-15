# frozen_string_literal: true

require "test_helper"

class EventsTest < ActiveSupport::TestCase
  test "on refuses an event nobody emits, and names the ones we do" do
    error = assert_raises(SupportDesk::ConfigurationError) { SupportDesk.on(:ticket_eaten) { } }

    assert_match(/unknown event :ticket_eaten/, error.message)
    assert_match(/:ticket_opened/, error.message)
  end

  test "on needs a block" do
    assert_raises(SupportDesk::ConfigurationError) { SupportDesk.on(:ticket_opened) }
  end

  test "every subscriber runs, in registration order" do
    seen = []
    SupportDesk.on(:ticket_closed) { |ticket, **| seen << [ :first, ticket ] }
    SupportDesk.on(:ticket_closed) { |ticket, **| seen << [ :second, ticket ] }

    SupportDesk.emit(:ticket_closed, :the_ticket, by: :system)

    assert_equal [ [ :first, :the_ticket ], [ :second, :the_ticket ] ], seen
  end

  test "a raising subscriber is reported and never stops the next one" do
    reported = []
    reporter = Class.new do
      define_method(:report) { |error, **context| reported << [ error, context ] }
    end.new

    seen = []
    SupportDesk.on(:ticket_closed) { |_ticket, **| raise "boom" }
    SupportDesk.on(:ticket_closed) { |_ticket, **| seen << :ran }

    Rails.stub(:error, reporter) do
      SupportDesk.emit(:ticket_closed, :the_ticket, by: :system)
    end

    assert_equal [ :ran ], seen
    assert_equal 1, reported.size
    assert_equal "boom", reported.first.first.message
    assert_equal :ticket_closed, reported.first.last[:context][:event]
  end

  test "every event is mirrored on ActiveSupport::Notifications" do
    payloads = []
    subscriber = ActiveSupport::Notifications.subscribe("ticket_closed.support_desk") do |*, payload|
      payloads << payload
    end

    SupportDesk.emit(:ticket_closed, :the_ticket, by: :system)

    assert_equal 1, payloads.size
    assert_equal [ :the_ticket ], payloads.first[:args]
    assert_equal :system, payloads.first[:by]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  test "opening a ticket emits ticket_opened after the transcript exists" do
    alice = create_user
    seen = []
    SupportDesk.on(:ticket_opened) { |ticket| seen << [ ticket.reference, ticket.messages.count ] }

    ticket = alice.ask_support!("hola")

    assert_equal [ [ ticket.reference, 1 ] ], seen
  end

  test "transitions emit their own event and the umbrella one" do
    alice = create_user
    lucia = create_agent
    ticket = ticket_for(alice)

    specific = []
    umbrella = []
    SupportDesk.on(:ticket_closed) { |closed, by:| specific << [ closed.reference, by ] }
    SupportDesk.on(:ticket_transitioned) { |t, kind, by:, request:, payload:| umbrella << [ t.reference, kind, by ] }

    ticket.close!(by: lucia)

    assert_equal [ [ ticket.reference, lucia ] ], specific
    assert_equal [ [ ticket.reference, :closed, lucia ] ], umbrella
  end

  test "a requester's reply emits requester_replied, the opening message does not" do
    alice = create_user
    replies = []
    SupportDesk.on(:requester_replied) { |_ticket, message| replies << message.body }

    ticket = ticket_for(alice, message: "primera")

    assert_empty replies

    alice.message!(ticket.conversation, "segunda")

    assert_equal [ "segunda" ], replies
  end

  test "an agent's reply emits agent_replied" do
    alice = create_user
    lucia = create_agent
    ticket = ticket_for(alice)
    replies = []
    SupportDesk.on(:agent_replied) { |_ticket, message| replies << message.body }

    ticket.reply!("vamos", by: lucia)

    assert_equal [ "vamos" ], replies
  end

  test "the catalogue documents every event the gem can emit" do
    assert_includes SupportDesk::Events::CATALOGUE.keys, :ticket_transitioned
    assert_equal "ticket, message", SupportDesk::Events::CATALOGUE[:requester_replied]
  end
end
