# frozen_string_literal: true

require "test_helper"

class WizardTest < ActiveSupport::TestCase
  setup do
    @alice = create_user(name: "Alice", onboarded: true)
    @lucia = create_agent
    @order = create_order(user: @alice, number: "SO1")
  end

  def wizard(params = {})
    SupportDesk::Wizard.new(@alice, params)
  end

  # --- Step 1: pick a topic -----------------------------------------------------

  test "with nothing chosen, the first step offers the top level" do
    w = wizard

    assert_equal :topic, w.step
    assert_predicate w, :topic_step?
    assert_equal %w[order billing account other], w.choices.map(&:path)
    assert_equal "What do you need help with?", w.ask
  end

  test "the choices honour only: and never offer retired topics" do
    fresh = create_user(onboarded: false)

    assert_not_includes SupportDesk::Wizard.new(fresh).choices.map(&:path), "account"
  end

  test "a branch shows its children, and the step is still :topic" do
    w = wizard(topic: "billing")

    assert_equal :topic, w.step
    assert_equal %w[billing/invoice], w.choices.map(&:path)
  end

  test "an unknown topic path leaves the requester at the first step" do
    w = wizard(topic: "nope")

    assert_nil w.topic
    assert_equal :topic, w.step
  end

  # --- Step 2: pick a thing -----------------------------------------------------

  test "a leaf that attaches something asks which one" do
    other_order = create_order(user: @alice, number: "SO2")
    create_order(user: create_user)
    w = wizard(topic: "order")

    assert_equal :subject, w.step
    assert_predicate w, :subject_step?
    assert_equal [ @order, other_order ].map(&:id).sort, w.choices.map(&:id).sort
    assert_predicate w, :subject_optional?
  end

  test "a free-form leaf skips straight to the composer" do
    w = wizard(topic: "other")

    assert_equal :compose, w.step
    assert_nil w.subject
  end

  test "none of these skips the picker" do
    w = wizard(topic: "order", no_subject: "1")

    assert_equal :compose, w.step
    assert_nil w.subject
  end

  test "the picker marks the records this requester already has a case about" do
    ticket = ticket_for(@alice, about: @order)
    w = wizard(topic: "order")

    assert_equal ticket, w.open_tickets_by_subject[[ "Order", @order.id.to_s ]]
  end

  # --- Step 3: write ------------------------------------------------------------

  test "picking a subject resolves the topic and lands on the composer" do
    w = wizard(subject: SupportDesk::Wizard.sign_subject(@order))

    assert_equal :compose, w.step
    assert_equal @order, w.subject
    assert_equal "order", w.topic.path
  end

  test "a record may be passed directly, for hosts driving the wizard in Ruby" do
    w = wizard(about: @order)

    assert_equal :compose, w.step
    assert_equal @order, w.subject
  end

  test "the composer carries the topic's prefill, placeholder and the promise" do
    SupportDesk.config.topics do
      topic :order, about: "Order", prefill: ->(order) { "About #{order.support_label}: " },
                    placeholder: "¿Qué ha pasado?"
      other
    end
    w = wizard(about: @order)

    assert_equal "About Order SO1: ", w.prefill
    assert_equal "¿Qué ha pasado?", w.placeholder
    assert_equal "We usually reply in under 1 day", w.promise
    assert_equal 24.hours, w.promise_within
  end

  test "open! opens the ticket the wizard describes" do
    w = wizard(subject: SupportDesk::Wizard.sign_subject(@order))
    ticket = w.open!("No ha llegado")

    assert_equal @order, ticket.subject
    assert_equal "order", ticket.topic.path
    assert_equal "No ha llegado", ticket.messages.first.body
  end

  test "open! refuses to submit a wizard that isn't finished" do
    error = assert_raises(SupportDesk::InvalidTransition) { wizard.open!("hola") }

    assert_match(/still on the topic step/, error.message)
  end

  test "existing_ticket is the case this would land in" do
    w = wizard(subject: SupportDesk::Wizard.sign_subject(@order))

    assert_nil w.existing_ticket

    ticket = ticket_for(@alice, about: @order)

    assert_equal ticket, wizard(about: @order).existing_ticket
  end

  # --- Subject tokens -----------------------------------------------------------

  test "subjects travel as signed GlobalIDs, never as raw ids" do
    token = SupportDesk::Wizard.sign_subject(@order)

    assert_not_equal @order.id.to_s, token
    assert_equal @order, SupportDesk::Wizard.find_signed_subject(token)
    # Tamper with the signature and it stops resolving.
    assert_nil SupportDesk::Wizard.find_signed_subject(token.sub(/--\h+\z/, "--0000"))
  end

  test "a token signed for something else is not accepted" do
    wrong_purpose = @order.to_sgid(for: :something_else).to_s

    assert_nil SupportDesk::Wizard.find_signed_subject(wrong_purpose)
    assert_nil SupportDesk::Wizard.find_signed_subject("garbage")
    assert_nil SupportDesk::Wizard.find_signed_subject(nil)
  end

  test "an expired token is not accepted" do
    token = SupportDesk::Wizard.sign_subject(@order)

    travel SupportDesk::Wizard::SUBJECT_TOKEN_TTL + 1.minute do
      assert_nil SupportDesk::Wizard.find_signed_subject(token)
    end
  end

  test "a signed subject somebody else owns is dropped, not honoured" do
    someone_elses = create_order(user: create_user)
    w = wizard(subject: SupportDesk::Wizard.sign_subject(someone_elses))

    assert_nil w.subject
    assert_equal :topic, w.step
  end

  test "subject_token round-trips the current choice into the next form" do
    w = wizard(about: @order)

    assert_equal @order, SupportDesk::Wizard.find_signed_subject(w.subject_token)
  end

  test "on the composer there is nothing left to choose" do
    w = wizard(topic: "other")

    assert_empty w.choices
    assert_nil w.ask
    assert_not_predicate w, :subject_optional?
  end

  test "a desk with no promise configured shows none" do
    SupportDesk.config.reply_within = nil
    SupportDesk.config.at_risk_after = nil

    assert_nil wizard(topic: "other").promise
    assert_nil wizard(topic: "other").promise_within
  end

  test "a topic that requires a subject won't let the requester skip it" do
    SupportDesk.config.topics do
      topic :order, about: "Order", subject: :required
      other
    end
    w = wizard(topic: "order", no_subject: "1")

    assert_equal :subject, w.step
    assert_not_predicate w, :subject_optional?
  end

  test "a record that isn't supportable is ignored, signed or not" do
    w = wizard(about: create_user)

    assert_nil w.subject
    assert_equal :topic, w.step
  end

  test "there is nothing to round-trip before a subject is chosen" do
    assert_nil wizard.subject_token
    assert_nil wizard.existing_ticket
  end

  test "a free-form ticket's existing case is found by topic, not by subject" do
    ticket = ticket_for(@alice, topic: :other)

    assert_equal ticket, wizard(topic: "other").existing_ticket
  end

  test "inspect says which step it's on" do
    assert_match(/step=compose topic="order"/, wizard(about: @order).inspect)
  end

  test "durations are humanized through i18n, and never as Translation missing" do
    assert_equal "1 day", SupportDesk::Wizard.humanize_duration(24.hours)

    # The dummy has no rails-i18n, so Spanish has no date translations: the
    # requester gets a plain duration rather than "Translation missing".
    I18n.with_locale(:es) do
      assert_equal "24 hours", SupportDesk::Wizard.humanize_duration(24.hours)
    end
  end

  test "the wizard drives the desk the requester writes to" do
    SupportDesk.config.desk(:billing)
    klass = Class.new(User) do
      def self.name = "BillingRequester"
      has_support_tickets desk: :billing
    end

    assert_equal "billing", SupportDesk::Wizard.new(klass.create!(name: "B")).desk.key
  end
end
