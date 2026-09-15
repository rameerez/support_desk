# frozen_string_literal: true

require "test_helper"

class MacrosTest < ActiveSupport::TestCase
  setup do
    @alice = create_user(name: "Alice")
    @lucia = create_agent(name: "Lucía")
  end

  # --- has_support_tickets -----------------------------------------------------

  test "has_support_tickets adds exactly four methods" do
    added = %i[support_tickets ask_support! awaiting_support_reply? unread_support_count]

    added.each { |method| assert_respond_to @alice, method }
  end

  test "support_tickets is a relation you can chain the scopes onto" do
    order = create_order(user: @alice)
    about_order = ticket_for(@alice, about: order)
    free = ticket_for(@alice, topic: :account)

    assert_equal 2, @alice.support_tickets.count
    assert_equal [ about_order ], @alice.support_tickets.about(order).to_a
    assert_includes @alice.support_tickets.open, free
  end

  test "awaiting_support_reply? is true while the desk owes an answer" do
    ticket = ticket_for(@alice)

    assert_predicate @alice, :awaiting_support_reply?

    ticket.reply!("vamos", by: @lucia)

    assert_not_predicate @alice.reload, :awaiting_support_reply?
  end

  test "unread_support_count counts against the chats read horizon" do
    ticket = ticket_for(@alice)

    assert_equal 0, @alice.unread_support_count

    ticket.reply!("una", by: @lucia)
    ticket.reply!("dos", by: @lucia)

    # Three, not two: taking the ticket also posted "Lucía is taking care of
    # your request", which is new content the requester hasn't read either.
    assert_equal 3, @alice.unread_support_count

    ticket.conversation.mark_read_by!(@alice)

    assert_equal 0, @alice.unread_support_count
  end

  test "a requester with tickets can't be deleted out from under them" do
    ticket_for(@alice)

    assert_not @alice.destroy
  end

  test "desk: routes a requester's tickets to another desk" do
    SupportDesk.config.desk(:billing) { |desk| desk.name = "Facturación" }
    klass = Class.new(User) do
      def self.name = "BillingUser"
      has_support_tickets desk: :billing, as: "client"
    end

    requester = klass.create!(name: "B")
    ticket = requester.ask_support!("hola")

    assert_equal "billing", ticket.desk.key
    assert_equal "client", ticket.requester_role
  end

  # --- supportable -------------------------------------------------------------

  test "supportable? answers on the class and the instance" do
    assert_predicate Order, :supportable?
    assert_predicate create_order(user: @alice), :supportable?
    assert_not_respond_to User.new, :supportable?
  end

  test "support_label, status, context and url have working defaults" do
    invoice = create_invoice(user: @alice, number: "INV1")

    assert_equal "Invoice INV1", invoice.support_label
    assert_nil invoice.support_status
    assert_empty invoice.support_context
    assert_nil invoice.support_url
  end

  test "supportable_by? defaults to the obvious ownership check" do
    order = create_order(user: @alice)

    assert order.supportable_by?(@alice)
    assert_not order.supportable_by?(create_user)
    assert_not order.supportable_by?(nil)
  end

  test "support_candidates_for defaults to the requester's own association" do
    mine = create_order(user: @alice)
    create_order(user: create_user)

    assert_equal [ mine ], Order.support_candidates_for(@alice).to_a
  end

  test "candidates: overrides the picker" do
    first = create_invoice(user: @alice, number: "INV1")
    second = create_invoice(user: @alice, number: "INV2")

    assert_equal [ second, first ], Invoice.support_candidates_for(@alice).to_a
  end

  test "support_topic is where a door opens the ticket" do
    assert_equal "order", Order.new.support_topic
    assert_equal "billing/invoice", Invoice.new.support_topic
  end

  test "supportable records keep their tickets when they go away" do
    order = create_order(user: @alice)
    ticket = ticket_for(@alice, about: order)

    order.destroy!

    assert_nil ticket.reload.subject_id
    assert_predicate ticket, :persisted?
  end

  test "supportable refuses a candidates: that cannot be called" do
    error = assert_raises(SupportDesk::ConfigurationError) do
      Class.new(ApplicationRecord) do
        def self.name = "Bogus"
        supportable topic: :x, candidates: "Order.all"
      end
    end

    assert_match(/must respond to #call/, error.message)
  end

  # --- acts_as_support_agent ---------------------------------------------------

  test "support_agent? honours the if: condition" do
    assert_predicate @lucia, :support_agent?
    assert_not_predicate @alice, :support_agent?
  end

  test "if: also takes a callable" do
    klass = Class.new(User) do
      def self.name = "CallableAgent"
      acts_as_support_agent if: ->(user) { user.name.start_with?("A") }
    end

    assert_predicate klass.create!(name: "Ana"), :support_agent?
    assert_not_predicate klass.create!(name: "Bea"), :support_agent?
  end

  test "support_agent_name is the signature requesters see" do
    assert_equal "Lucía", @lucia.support_agent_name
  end

  test "an agent is on duty and uncapped unless the host says otherwise" do
    assert_predicate @lucia, :on_duty?
    assert_nil @lucia.support_capacity
    assert_equal :human, @lucia.support_agent_kind
  end

  test "kind: marks a bot as a bot" do
    klass = Class.new(User) do
      def self.name = "BotAgent"
      acts_as_support_agent kind: :ai
    end

    assert_equal :ai, klass.new.support_agent_kind
  end

  test "support_queue is this agent's view of the desk" do
    queue = @lucia.support_queue

    assert_kind_of SupportDesk::Queue, queue
    assert_equal @lucia, queue.agent
  end

  test "an agent knows what they have been assigned" do
    ticket = ticket_for(@alice)
    ticket.assign!(to: @lucia, by: @lucia)

    assert_includes @lucia.support_tickets_assigned, ticket
    assert_equal 1, @lucia.support_assignments.count
  end

  test "acts_as_support_agent refuses options it doesn't have" do
    error = assert_raises(SupportDesk::ConfigurationError) do
      Class.new(User) do
        def self.name = "BadAgent"
        acts_as_support_agent when: :admin?
      end
    end

    assert_match(/unknown acts_as_support_agent option :when/, error.message)
  end

  test "no verbs are added to the agent model" do
    %i[close take reply_to hand_off release].each { |verb| assert_not_respond_to @lucia, verb }
  end
end
