# frozen_string_literal: true

require "test_helper"

class SupportDeskTest < ActiveSupport::TestCase
  test "VERSION is set" do
    assert_match(/\A\d+\.\d+\.\d+/, SupportDesk::VERSION)
  end

  test "configure yields the configuration and validates it" do
    SupportDesk.configure { |config| config.name = "Mesa" }

    assert_equal "Mesa", SupportDesk.config.name
    assert_predicate SupportDesk, :configured?
  end

  test "reset! clears configuration, subscribers, desks and registries" do
    SupportDesk.configure { |config| config.name = "Mesa" }
    SupportDesk.on(:ticket_opened) { |_ticket| }
    desk = SupportDesk.desk

    SupportDesk.reset!

    assert_not_equal "Mesa", SupportDesk.config.name
    assert_empty SupportDesk.subscribers[:ticket_opened]
    assert_not_predicate SupportDesk, :configured?
    assert_not_same desk, SupportDesk.desk
  end

  test "desk memoises the record and never inserts first" do
    first = SupportDesk.desk

    assert_same first, SupportDesk.desk
    assert_equal "default", first.key

    SupportDesk.reset_desks!
    queries = count_queries { SupportDesk.desk }

    assert_equal 1, queries, "a desk that exists should cost one SELECT and no INSERT"
  end

  test "desk returns nil for a key nobody configured" do
    assert_nil SupportDesk.desk(:nope)
  end

  test "desk creates a configured non-default desk" do
    SupportDesk.config.desk(:billing) { |desk| desk.name = "Facturación" }

    assert_equal "billing", SupportDesk.desk(:billing).key
    assert_equal "Facturación", SupportDesk.desk(:billing).name
  end

  test "find_topic looks across every desk and never raises" do
    assert_equal "order", SupportDesk.find_topic("order").path
    assert_equal "billing/invoice", SupportDesk.find_topic(:"billing/invoice").path

    unknown = SupportDesk.find_topic("sales/refund")

    assert_predicate unknown, :unknown?
    assert_equal "Sales refund", unknown.label
  end

  test "registries know the dummy host's classes and survive by name" do
    assert SupportDesk.requester_class?(User)
    assert SupportDesk.supportable_class?(Order)
    assert SupportDesk.supportable_class?("Invoice")
    assert SupportDesk.agent_class?(User)
    assert_not SupportDesk.supportable_class?(User)
  end

  test "the same key replaces a subscriber instead of stacking another" do
    calls = 0
    3.times { SupportDesk.on(:ticket_opened, key: :support_desk_test) { |_ticket| calls += 1 } }

    assert_equal 1, SupportDesk.subscribers[:ticket_opened].size

    create_user.ask_support!("hola")

    assert_equal 1, calls
  end

  test "without a key, subscribers stack, and off removes one" do
    SupportDesk.on(:ticket_opened) { |_ticket| }
    SupportDesk.on(:ticket_opened) { |_ticket| }

    assert_equal 2, SupportDesk.subscribers[:ticket_opened].size

    SupportDesk.on(:ticket_opened, key: :removable) { |_ticket| }
    SupportDesk.off(:ticket_opened, :removable)

    assert_equal 2, SupportDesk.subscribers[:ticket_opened].size
  end

  test "every error the gem declares is one it can actually raise" do
    # PRD §4.9 is a promise about the vocabulary, not a wishlist: a class
    # nothing raises is a class that misleads whoever rescues it.
    declared = SupportDesk.constants.map { |name| SupportDesk.const_get(name) }
                          .select { |value| value.is_a?(Class) && value < SupportDesk::Error }
                          .map(&:name).map { |name| name.split("::").last }.sort
    raised = Dir[File.expand_path("../lib/support_desk/**/*.rb", __dir__)]
             .flat_map { |file| File.read(file).scan(/raise\(?\s*(?:SupportDesk::)?([A-Z]\w+)/) }
             .flatten.uniq

    (declared - [ "ConfigurationError" ]).each do |error|
      assert_includes raised, error, "SupportDesk::#{error} is declared but never raised"
    end
  end

  test "eligible? reads a macro's if: the same way for both sides" do
  alice = create_user(name: "Alice", admin: false)

  assert SupportDesk.eligible?(alice, nil), "no condition is always yes"
  assert_not SupportDesk.eligible?(alice, :admin?)
  assert SupportDesk.eligible?(alice, ->(user) { user.name.start_with?("A") })
  # Whatever the host's predicate returns, the answer is a boolean.
  assert_equal true, SupportDesk.eligible?(alice, ->(user) { user.name })
end

test "humanize_duration speaks the reader's language, wherever it is called from" do
  assert_equal "1 day", SupportDesk.humanize_duration(24.hours)
  # Kept on Wizard as a delegation: it has been public since 0.1.
  assert_equal "1 day", SupportDesk::Wizard.humanize_duration(24.hours)

  I18n.with_locale(:es) { assert_equal "1 día", SupportDesk.humanize_duration(24.hours) }
end

test "actor_key is stable per record and distinguishes classes" do
    user = create_user
    order = create_order(user: user)

    assert_equal SupportDesk.actor_key(user), SupportDesk.actor_key(user)
    assert_not_equal SupportDesk.actor_key(user), SupportDesk.actor_key(order)
    assert_equal "system", SupportDesk.actor_key(:system)
    assert_nil SupportDesk.actor_key(nil)
  end

  test "root_path reports where the host mounted the engine" do
    assert_equal "/messages/support", SupportDesk.root_path
  end

  test "subscribe_to_chats! is idempotent" do
    SupportDesk.subscribe_to_chats!
    SupportDesk.subscribe_to_chats!

    alice = create_user
    ticket = alice.ask_support!("hola")

    assert_equal 1, ticket.events.of_kind(:opened).count
  end

  private

  def count_queries
    count = 0
    counter = ->(_name, _start, _finish, _id, payload) { count += 1 unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end
end
