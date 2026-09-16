# frozen_string_literal: true

require "test_helper"

# The parts of the step machine the SCREENS lean on: where "back" goes, what
# the composer round-trips, and what the wizard does when a step would be a
# dead end. Everything here is the PORO, so an ejected view, a native app or
# an API gets the same answers the bundled views get.
class WizardNavigationTest < ActiveSupport::TestCase
  setup do
    @alice = create_user(name: "Alice", onboarded: true)
    @order = create_order(user: @alice, number: "SO1")
  end

  def wizard(params = {})
    SupportDesk::Wizard.new(@alice, params)
  end

  # --- Back ---------------------------------------------------------------------

  test "the first screen has nowhere to go back to" do
    assert_nil wizard.back
  end

  test "back from inside a branch is the level above it" do
    assert_equal({}, wizard(topic: "billing").back)
    assert_equal({ topic: "billing" }, wizard(topic: "billing/invoice").back)
  end

  test "back from the picker is the level the leaf was chosen from" do
    assert_equal({}, wizard(topic: "order").back)
  end

  test "back from the composer is the picker, when there was one" do
    assert_equal({ topic: "order" }, wizard(about: @order).back)
    assert_equal({ topic: "order" }, wizard(topic: "order", no_subject: "1").back)
  end

  test "back from a free-form composer is the topic tree, because there was no picker" do
    assert_equal({}, wizard(topic: "other").back)
  end

  # --- State the composer carries -------------------------------------------------

  test "state_params carry the chosen topic and a freshly signed subject" do
    state = wizard(about: @order).state_params

    assert_equal "order", state[:topic]
    assert_equal @order, SupportDesk::Wizard.find_signed_subject(state[:subject])
    assert_not state.key?(:no_subject)
  end

  test "state_params remember a refused subject, so the POST lands on the composer" do
    state = wizard(topic: "order", no_subject: "1").state_params

    assert_equal({ topic: "order", no_subject: 1 }, state)
    assert_equal :compose, SupportDesk::Wizard.new(@alice, state).step
  end

  test "no_subject is only an answer where the topic offered it" do
    # `other` attaches nothing, so there was never a choice to decline.
    assert_equal({ topic: "other" }, wizard(topic: "other", no_subject: "1").state_params)
  end

  # --- Subjects off the query string ------------------------------------------------

  test "about: accepts the signed token a door puts in the URL" do
    w = wizard(about: SupportDesk::Wizard.sign_subject(@order))

    assert_equal @order, w.subject
    assert_equal "order", w.topic.path
    assert_equal :compose, w.step
  end

  test "subject_rejected? tells a controller when to answer 404" do
    assert_not_predicate wizard, :subject_rejected?
    assert_not_predicate wizard(topic: "order"), :subject_rejected?
    assert_not_predicate wizard(about: @order), :subject_rejected?

    assert_predicate wizard(about: "garbage"), :subject_rejected?
    assert_predicate wizard(about: SupportDesk::Wizard.sign_subject(create_order(user: create_user))),
                     :subject_rejected?
    assert_predicate wizard(subject: "forged--0000"), :subject_rejected?
  end

  # --- Dead ends --------------------------------------------------------------------

  test "an optional picker with nothing in it is skipped, not shown empty" do
    orderless = create_user(name: "Orderless", onboarded: true)
    w = SupportDesk::Wizard.new(orderless, { topic: "order" })

    assert_empty w.candidates
    assert_equal :compose, w.step
  end

  test "a required picker with nothing in it still asks, because the topic insists" do
    SupportDesk.config.topics do
      topic :order, about: "Order", subject: :required
      other
    end
    orderless = create_user(name: "Orderless", onboarded: true)

    assert_equal :subject, SupportDesk::Wizard.new(orderless, { topic: "order" }).step
  end

  # --- Visibility: a topic nobody offers is a topic nobody reaches -----------------
  #
  # Five properties, one per test, each failing if its clause is removed from
  # SupportDesk::Wizard#resolve_topic.

  test "a hidden topic is not reachable by typing its path" do
    SupportDesk.config.topics do
      topic :order, about: "Order", only: ->(_requester) { false }
      other
    end
    w = wizard(topic: "order")

    assert_nil w.topic
    assert_equal :topic, w.step
  end

  test "a hidden topic is not reachable through a supportable's own topic either" do
    SupportDesk.config.topics do
      topic :order, about: "Order", only: ->(_requester) { false }
      other
    end
    # The record IS Alice's, and the wizard still refuses its topic: the two
    # ways in have to agree, or `about:` is a way around `only:`.
    w = wizard(about: @order)

    assert_equal @order, w.subject
    assert_nil w.topic
    assert_equal :topic, w.step
  end

  test "a retired topic never resolves, by path or by subject" do
    SupportDesk.config.topics do
      topic :order, about: "Order", retired: true
      other
    end

    assert_nil wizard(topic: "order").topic
    assert_nil wizard(about: @order).topic
  end

  test "a topic that requires a subject can never be submitted without one" do
    SupportDesk.config.topics do
      topic :order, about: "Order", subject: :required
      other
    end
    w = wizard(topic: "order", no_subject: "1")

    # The step machine refuses, and so would the core underneath it.
    assert_equal :subject, w.step
    assert_raises(SupportDesk::InvalidTransition) { w.open!("Sin asunto") }
    assert_raises(SupportDesk::NotAllowed) { @alice.ask_support!("Sin asunto", topic: "order") }
  end

  test "with nothing on offer, the wizard falls back to the DECLARED way out" do
    SupportDesk.config.topics do
      # Nothing at the top level this requester may see, but the exit below
      # it says otherwise for them.
      topic :everything, only: ->(_requester) { false } do
        other only: ->(_requester) { true }
      end
    end
    w = wizard

    assert_empty w.tree.visible_for(@alice)
    assert_equal :compose, w.step
    assert_equal "everything/other", w.topic.path
    # And the core agrees: the fallback opens a real ticket rather than a
    # composer that 404s on submit.
    assert_equal "everything/other", w.open!("Una duda").topic.path
  end

  test "an undeclared subject-less leaf is never the way out" do
    SupportDesk.config.topics do
      # `safety` takes no subject, but nobody declared it the exit.
      topic :safety, subject: :none, only: ->(_requester) { false }
    end
    w = wizard

    assert_empty w.tree.visible_for(@alice)
    assert_nil w.topic
    assert_equal :topic, w.step
    assert_empty w.choices
  end

  test "a hidden way out refuses cleanly rather than offering a composer that cannot submit" do
    SupportDesk.config.topics do
      topic :order, about: "Order", only: ->(_requester) { false }
      other only: ->(_requester) { false }
    end
    w = wizard

    assert_nil w.topic
    assert_equal :topic, w.step
    assert_nil w.back
    assert_raises(SupportDesk::InvalidTransition) { w.open!("Una duda") }
  end

  test "a tree with no topics at all refuses without raising" do
    SupportDesk.config.topics { }
    w = wizard

    assert_predicate w.tree, :empty?
    assert_nil w.topic
    assert_equal :topic, w.step
    assert_empty w.choices
  end

  test "candidates are resolved once, however many times the views ask" do
    calls = 0
    SupportDesk.config.topics do
      topic :order, about: "Order", candidates: lambda { |requester|
        calls += 1
        requester.orders
      }
      other
    end
    w = wizard(topic: "order")
    3.times { w.candidates }

    assert_equal [ @order ], w.choices.to_a
    assert_equal 1, calls
  end

  test "open_ticket_about marks the records already being talked about" do
    ticket = ticket_for(@alice, about: @order)
    other = create_order(user: @alice, number: "SO2")
    w = wizard(topic: "order")

    assert_equal ticket, w.open_ticket_about(@order)
    assert_nil w.open_ticket_about(other)
    assert_nil w.open_ticket_about(nil)
  end
end
