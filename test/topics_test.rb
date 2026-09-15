# frozen_string_literal: true

require "test_helper"

class TopicsTest < ActiveSupport::TestCase
  setup do
    @tree = SupportDesk::TopicTree.build do
      topic :order, about: "Order", ask: "¿Con qué pedido?"
      topic :billing, priority: :high do
        topic :invoice, about: "Invoice", subject: :required
        topic :refund, prefill: ->(subject) { "Sobre #{subject}: " }
      end
      topic :account, only: ->(requester) { requester.onboarded? }
      topic :legacy, retired: true
      other
    end
  end

  # --- Shape -------------------------------------------------------------------

  test "paths are built from the nesting" do
    assert_equal %w[order billing billing/invoice billing/refund account legacy other], @tree.map(&:path)
  end

  test "find resolves a path and find! raises with the known paths" do
    assert_equal "billing/invoice", @tree.find("billing/invoice").path
    assert_nil @tree.find("billing/nope")

    error = assert_raises(SupportDesk::UnknownTopic) { @tree.find!("billing/nope") }

    assert_match(/billing\/invoice/, error.message)
  end

  test "leaves are the nodes you can actually pick" do
    assert_equal %w[order billing/invoice billing/refund account legacy other], @tree.leaves.map(&:path)
  end

  test "branches and leaves know which they are" do
    assert_predicate @tree.find("billing"), :branch?
    assert_predicate @tree.find("billing/invoice"), :leaf?
    assert_predicate @tree.find("order"), :root?
    assert_not_predicate @tree.find("billing/invoice"), :root?
  end

  test "the tree is frozen once built" do
    assert_predicate @tree, :frozen?
    assert_predicate @tree.find("order"), :frozen?
  end

  # --- Identity ----------------------------------------------------------------

  test "a topic compares against symbols, strings and topics" do
    topic = @tree.find("billing/invoice")

    assert_equal topic, @tree.find("billing/invoice")
    assert_equal "billing/invoice", topic.to_s
    assert topic == :"billing/invoice"
    assert topic == "billing/invoice"
    assert_not topic == :billing
  end

  test "under? is true for the topic itself and everything below it" do
    assert_predicate @tree.find("billing/invoice"), :leaf?
    assert @tree.find("billing/invoice").under?(:billing)
    assert @tree.find("billing").under?(:billing)
    assert_not @tree.find("order").under?(:billing)
  end

  # --- Options -----------------------------------------------------------------

  test "labels come from i18n and fall back to a humanized key" do
    assert_equal "Something else", @tree.find("other").label
    assert_equal "Invoice", @tree.find("billing/invoice").label
  end

  test "full_label spells out the branch" do
    assert_equal "Billing › Invoice", @tree.find("billing/invoice").full_label
  end

  test "about is resolved lazily from class names" do
    assert_equal [ Order ], @tree.find("order").about
    assert_equal [ "Invoice" ], @tree.find("billing/invoice").about_class_names
    assert @tree.find("order").about?(Order)
    assert_not @tree.find("order").about?(Invoice)
  end

  test "subject mode defaults to optional with about: and none without" do
    assert_equal :optional, @tree.find("order").subject_mode
    assert_equal :required, @tree.find("billing/invoice").subject_mode
    assert_equal :none, @tree.find("billing/refund").subject_mode
    assert_predicate @tree.find("other"), :free_form?
  end

  test "branch options reach descendants unless overridden" do
    assert_equal 1, @tree.find("billing/invoice").priority
    assert_equal 1, @tree.find("billing").priority
    assert_equal 0, @tree.find("order").priority
  end

  test "only: decides visibility, and retired nodes are never visible" do
    onboarded = create_user(onboarded: true)
    fresh = create_user(onboarded: false)

    assert_includes @tree.visible_for(onboarded).map(&:path), "account"
    assert_not_includes @tree.visible_for(fresh).map(&:path), "account"
    assert_not_includes @tree.visible_for(onboarded).map(&:path), "legacy"
  end

  test "visible_for walks into a branch" do
    user = create_user

    assert_equal %w[billing/invoice billing/refund], @tree.visible_for(user, under: "billing").map(&:path)
  end

  test "prefill takes a string or a callable" do
    assert_equal "Sobre thing: ", @tree.find("billing/refund").prefill("thing")
    assert_nil @tree.find("order").prefill
  end

  test "ask comes from the option or i18n" do
    assert_equal "¿Con qué pedido?", @tree.find("order").ask
    assert_equal "What is it about?", @tree.find("other").ask
  end

  test "candidates default to the about: class's own picker" do
    user = create_user
    order = create_order(user: user)
    create_order(user: create_user)

    assert_equal [ order ], @tree.find("order").candidates_for(user).to_a
  end

  test "candidates: overrides the default" do
    user = create_user
    tree = SupportDesk::TopicTree.build do
      topic :order, about: "Order", candidates: ->(_requester) { Order.none }
    end

    assert_empty tree.find("order").candidates_for(user)
  end

  # --- other -------------------------------------------------------------------

  test "other is the free-form leaf, and can be removed" do
    assert_predicate @tree, :free_form?
    assert_equal "other", @tree.free_form_leaf.path

    without = SupportDesk::TopicTree.build do
      topic :order, about: "Order"
      other false
    end

    assert_not_predicate without, :free_form?
    assert_nil without.free_form_leaf
  end

  # --- DSL validation ----------------------------------------------------------

  test "an unknown topic option fails at build time with the known options" do
    error = assert_raises(SupportDesk::ConfigurationError) do
      SupportDesk::TopicTree.build { topic :order, abuot: "Order" }
    end

    assert_match(/unknown topic option :abuot/, error.message)
    assert_match(/:about/, error.message)
  end

  test "subject and priority are checked against their vocabularies" do
    assert_raises(SupportDesk::ConfigurationError) { SupportDesk::TopicTree.build { topic :x, subject: :maybe } }
    assert_raises(SupportDesk::ConfigurationError) { SupportDesk::TopicTree.build { topic :x, priority: :panic } }
  end

  test "procs must be callable" do
    error = assert_raises(SupportDesk::ConfigurationError) do
      SupportDesk::TopicTree.build { topic :x, only: true }
    end

    assert_match(/only must respond to #call/, error.message)
  end

  # --- The attribute type -------------------------------------------------------

  test "the type casts symbols, strings and topics, and serializes to the path" do
    type = SupportDesk::Topic::Type.new

    assert_equal "order", type.cast(:order).path
    assert_equal "order", type.cast("order").path
    assert_equal "order", type.serialize(type.cast("order"))
    assert_equal "order", type.serialize(:order)
    assert_nil type.cast(nil)
  end

  test "an unknown path reads as a null object that still renders" do
    unknown = SupportDesk::Topic::Type.new.cast("gone/away")

    assert_predicate unknown, :unknown?
    assert_predicate unknown, :retired?
    assert_equal "gone/away", unknown.to_s
    assert_equal "Gone away", unknown.label
    assert_empty unknown.about
  end

  test "a ticket's topic round-trips through the database" do
    alice = create_user
    ticket = ticket_for(alice, topic: :"billing/invoice")

    assert_instance_of SupportDesk::Topic, ticket.reload.topic
    assert_equal "billing/invoice", ticket.topic.path
    assert_includes SupportDesk::Ticket.where(topic: :"billing/invoice"), ticket
    assert_includes SupportDesk::Ticket.on_topic(:billing), ticket
    assert_not_includes SupportDesk::Ticket.on_topic(:order), ticket
  end
end
