# frozen_string_literal: true

require "test_helper"

# Most apps have one desk and never think about it. Apps with more say so,
# and everything a desk doesn't state it inherits from the default one.
class MultiDeskTest < ActiveSupport::TestCase
  setup do
    @alice = create_user(name: "Alice")
    @lucia = create_agent(name: "Lucía")
    @finance = create_user(name: "Fina", admin: false)

    SupportDesk.config.reply_within = 24.hours
    SupportDesk.config.desk(:billing) do |desk|
      desk.name = "Facturación"
      desk.reply_within = 8.hours
      desk.agents { User.where(name: "Fina") }
      desk.topics do
        topic :billing do
          topic :invoice, about: "Invoice"
        end
        other
      end
    end
  end

  test "a desk inherits what it doesn't state" do
    billing = SupportDesk.config.desk(:billing)

    assert_equal "Facturación", billing.name
    assert_equal 8.hours, billing.reply_within
    assert_equal 4.hours, billing.at_risk_after
    assert_equal :anyone, billing.reply_policy
  end

  test "each desk is its own record and its own messager seat" do
    default = SupportDesk.desk
    billing = SupportDesk.desk(:billing)

    assert_not_equal default, billing
    assert_equal "Facturación", billing.name
    assert_equal "Soporte", default.name
  end

  test "each desk has its own topic tree" do
    assert_equal %w[billing billing/invoice other], SupportDesk.config.desk(:billing).topics.map(&:path)
    assert_includes SupportDesk.config.default_desk.topics.map(&:path), "order"
  end

  test "each desk has its own pool" do
    assert_equal [ @lucia ], SupportDesk.desk.agents.to_a
    assert_equal [ @finance ], SupportDesk.desk(:billing).agents.to_a
  end

  test "tickets belong to a desk, and the scopes respect it" do
    invoice = create_invoice(user: @alice)
    default_ticket = ticket_for(@alice, topic: :account)
    billing_ticket = SupportDesk::Ticket.open!(
      requester: @alice, message: "una factura", about: invoice, desk: SupportDesk.desk(:billing)
    )

    assert_equal "billing", billing_ticket.desk.key
    assert_includes SupportDesk::Ticket.for_desk(:billing), billing_ticket
    assert_not_includes SupportDesk::Ticket.for_desk(:billing), default_ticket
  end

  test "a ticket's thresholds come from its own desk" do
    invoice = create_invoice(user: @alice)
    ticket = SupportDesk::Ticket.open!(
      requester: @alice, message: "una factura", about: invoice, desk: SupportDesk.desk(:billing)
    )
    ticket.update!(waiting_since: 10.hours.ago)

    assert_predicate ticket, :overdue?, "10 hours is past the billing desk's 8 hour promise"

    default_ticket = ticket_for(@alice, topic: :account)
    default_ticket.update!(waiting_since: 10.hours.ago)

    assert_not_predicate default_ticket, :overdue?, "10 hours is still inside the default 24 hour promise"
  end

  test "the SLA scopes measure each ticket against its own desk" do
    invoice = create_invoice(user: @alice)
    billing = SupportDesk::Ticket.open!(requester: @alice, message: "una factura", about: invoice,
                                        desk: SupportDesk.desk(:billing))
    default = ticket_for(@alice, topic: :account)
    [ billing, default ].each { |ticket| ticket.update!(waiting_since: 10.hours.ago) }

    # 10 hours is past billing's 8 hour promise and well inside the default
    # desk's 24 — one query, two answers.
    assert_includes SupportDesk::Ticket.overdue, billing
    assert_not_includes SupportDesk::Ticket.overdue, default
    assert_includes SupportDesk::Ticket.for_desk(:billing).overdue, billing
    assert_empty SupportDesk::Ticket.for_desk(:default).overdue
  end

  test "at_risk is the band before the breach, per desk" do
    invoice = create_invoice(user: @alice)
    billing = SupportDesk::Ticket.open!(requester: @alice, message: "una factura", about: invoice,
                                        desk: SupportDesk.desk(:billing))
    billing.update!(waiting_since: 5.hours.ago)

    assert_includes SupportDesk::Ticket.at_risk, billing
    assert_not_includes SupportDesk::Ticket.overdue, billing

    billing.update!(waiting_since: 9.hours.ago)

    assert_not_includes SupportDesk::Ticket.at_risk, billing
    assert_includes SupportDesk::Ticket.overdue, billing
  end

  test "asking a single desk about its own thresholds" do
    invoice = create_invoice(user: @alice)
    billing = SupportDesk::Ticket.open!(requester: @alice, message: "una factura", about: invoice,
                                        desk: SupportDesk.desk(:billing))
    billing.update!(waiting_since: 10.hours.ago)

    assert_includes SupportDesk::Ticket.overdue(:billing), billing
    assert_empty SupportDesk::Ticket.overdue(:default)
  end

  test "a requester whose desk nobody configured is refused, not quietly redirected" do
    klass = Class.new(User) do
      def self.name = "NowhereRequester"
      has_support_tickets desk: :nowhere
    end
    requester = klass.create!(name: "N")

    error = assert_raises(SupportDesk::ConfigurationError) { requester.ask_support!("hola") }

    assert_match(/isn't configured/, error.message)
  end

  test "an unknown desk key is a boot failure" do
    # A real constant, because boot validation resolves class NAMES — which
    # is the whole reason it survives a Zeitwerk reload.
    Object.const_set(:BootNowhereRequester, Class.new(User))
    BootNowhereRequester.has_support_tickets desk: :nowhere

    error = assert_raises(SupportDesk::ConfigurationError) { SupportDesk.config.validate_classes! }

    assert_match(/BootNowhereRequester/, error.message)
    assert_match(/config\.desk :nowhere/, error.message)
  ensure
    SupportDesk.requester_class_names.delete("BootNowhereRequester")
    Object.send(:remove_const, :BootNowhereRequester) if Object.const_defined?(:BootNowhereRequester)
  end

  test "a queue is one desk's queue" do
    invoice = create_invoice(user: @alice)
    SupportDesk::Ticket.open!(requester: @alice, message: "una factura", about: invoice,
                              desk: SupportDesk.desk(:billing))
    ticket_for(create_user, topic: :account)

    assert_equal 1, SupportDesk::Queue.for(@lucia).counts[:open]
    assert_equal 1, SupportDesk::Queue.for(@finance, desk: SupportDesk.desk(:billing)).counts[:open]
  end

  test "the same requester may hold one open ticket per desk about the same topic" do
    first = ticket_for(@alice, topic: :account)
    second = SupportDesk::Ticket.open!(requester: @alice, message: "otra", topic: :other,
                                       desk: SupportDesk.desk(:billing))

    assert_not_equal first.id, second.id
  end
end
