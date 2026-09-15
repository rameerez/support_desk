# frozen_string_literal: true

require "test_helper"

# The three wizard frames at one URL: /support/new.
class WizardFlowTest < ActionDispatch::IntegrationTest
  setup do
    @alice = create_user(name: "Alice", onboarded: true)
    @lucia = create_agent(name: "Lucía")
    @order = create_order(user: @alice, number: "SO1")
    login_as @alice
  end

  def token_for(record) = SupportDesk::Wizard.sign_subject(record)

  # --- Step 1: the topic tree ---------------------------------------------------

  test "the wizard opens on the topic tree, inside the support_wizard frame" do
    get "/messages/support/new"

    assert_response :success
    assert_select "turbo-frame#support_wizard[data-turbo-action=advance]"
    assert_select ".support-desk-choice__label", text: "Order"
    assert_select ".support-desk-choice__label", text: "Something else"
    # Branches are links into the same frame, one level at a time.
    assert_select "a[href=?]", "/messages/support/new?topic=billing"
  end

  test "a branch drills in place and offers a way back up" do
    get "/messages/support/new?topic=billing"

    assert_response :success
    assert_select ".support-desk-choice__label", text: "Invoice"
    assert_select "a.support-desk-wizard__back[href=?]", "/messages/support/new"
  end

  test "only: hides a topic from the requester it isn't for" do
    login_as create_user(name: "Fresh", onboarded: false)
    get "/messages/support/new"

    assert_response :success
    assert_select ".support-desk-choice__label", text: "Account", count: 0
  end

  # --- Step 2: which one --------------------------------------------------------

  test "a leaf that attaches something asks which one, signing every choice" do
    other = create_order(user: @alice, number: "SO2")
    create_order(user: create_user, number: "SOMEONE-ELSE")
    get "/messages/support/new?topic=order"

    assert_response :success
    assert_select ".support-desk-choice__label", text: "Order SO1"
    assert_select ".support-desk-choice__label", text: "Order SO2"
    assert_select ".support-desk-choice__label", text: "Order SOMEONE-ELSE", count: 0
    # Raw ids never travel; the picker links carry signed tokens.
    assert_select "a.support-desk-choice[href*=?]", "about=", count: 2
    assert_no_match(/about=#{other.id}\b/, response.body)
  end

  test "the picker offers none of these when the topic says the subject is optional" do
    get "/messages/support/new?topic=order"

    assert_select "a.support-desk-choice--none[href=?]", "/messages/support/new?no_subject=1&topic=order"
  end

  test "something already being talked about links into that conversation instead" do
    ticket = ticket_for(@alice, about: @order)
    get "/messages/support/new?topic=order"

    assert_select "a.support-desk-choice--taken[href=?]", "/messages/#{ticket.conversation.id}"
    assert_select ".support-desk-choice__hint", text: /#{I18n.t("support_desk.wizard.already_open")}/
  end

  test "a required subject with nothing to pick says so rather than showing an empty list" do
    SupportDesk.config.topics do
      topic :order, about: "Order", subject: :required
      other
    end
    login_as create_user(name: "Orderless", onboarded: true)
    get "/messages/support/new?topic=order"

    assert_response :success
    assert_select ".support-desk-empty", text: I18n.t("support_desk.wizard.nothing_to_pick")
  end

  test "an optional subject with nothing to pick skips the dead end and goes to the composer" do
    login_as create_user(name: "Orderless", onboarded: true)
    get "/messages/support/new?topic=order"

    assert_response :success
    assert_select "textarea[name=message]"
  end

  # --- Step 3: write ------------------------------------------------------------

  test "choosing a thing lands on the composer, with the context card above it" do
    get "/messages/support/new?topic=order&about=#{token_for(@order)}"

    assert_response :success
    assert_select ".support-desk-card__label", text: "Order SO1"
    assert_select ".support-desk-card__status", text: @order.support_status
    assert_select "textarea[name=message]"
    assert_select "input[type=hidden][name=subject]"
    assert_select "form[action=?][data-turbo-frame=_top]", "/messages/support/tickets"
  end

  test "a door deep-links straight to the composer and resolves the topic itself" do
    get "/messages/support/new?about=#{token_for(@order)}"

    assert_response :success
    assert_select ".support-desk-card__label", text: "Order SO1"
    assert_select "input[type=hidden][name=topic][value=order]"
  end

  test "a free-form leaf skips both pickers" do
    get "/messages/support/new?topic=other"

    assert_response :success
    assert_select "textarea[name=message]"
    assert_select "input[type=hidden][name=topic][value=other]"
    assert_select ".support-desk-card", count: 0
  end

  test "none of these carries its answer into the form, so the POST lands on the composer" do
    get "/messages/support/new?topic=order&no_subject=1"

    assert_response :success
    assert_select "input[type=hidden][name=no_subject][value='1']"
    assert_select "input[type=hidden][name=topic][value=order]"
  end

  test "the composer shows the topic's prefill, placeholder and the promise" do
    SupportDesk.config.topics do
      topic :order, about: "Order", prefill: ->(order) { "About #{order.support_label}: " },
                    placeholder: "¿Qué ha pasado?"
      other
    end
    get "/messages/support/new?about=#{token_for(@order)}"

    assert_select "textarea[name=message][placeholder=?]", "¿Qué ha pasado?", text: "About Order SO1: "
    assert_select ".support-desk-form__promise", text: /1 day|24 hours/
  end

  test "the composer offers the case they already have instead of a second one" do
    ticket = ticket_for(@alice, about: @order)
    get "/messages/support/new?about=#{token_for(@order)}"

    assert_response :success
    assert_select "textarea[name=message]", count: 0
    assert_select ".support-desk-notice a[href=?]", "/messages/#{ticket.conversation.id}"
  end

  # --- Submitting ----------------------------------------------------------------

  test "submitting opens the case and hands the requester to the conversation" do
    assert_difference -> { SupportDesk::Ticket.count }, 1 do
      post "/messages/support/tickets", params: { topic: "order", subject: token_for(@order),
                                                  message: "No ha llegado" }
    end

    ticket = SupportDesk::Ticket.last

    assert_redirected_to "/messages/#{ticket.conversation.id}"
    assert_equal @order, ticket.subject
    assert_equal "order", ticket.topic.path
    assert_equal @alice, ticket.requester
    assert_equal "No ha llegado", ticket.messages.first.body
  end

  test "submitting twice lands in the same case, not two" do
    post "/messages/support/tickets", params: { topic: "order", subject: token_for(@order), message: "Una vez" }
    first = SupportDesk::Ticket.last

    assert_no_difference -> { SupportDesk::Ticket.count } do
      post "/messages/support/tickets", params: { topic: "order", subject: token_for(@order), message: "Otra vez" }
    end

    assert_redirected_to "/messages/#{first.conversation.id}"
    assert_equal 2, first.reload.messages.count
  end

  test "a free-form case needs no subject at all" do
    post "/messages/support/tickets", params: { topic: "other", message: "Una duda" }

    ticket = SupportDesk::Ticket.last

    assert_equal "other", ticket.topic.path
    assert_nil ticket.subject
    assert_redirected_to "/messages/#{ticket.conversation.id}"
  end

  test "an empty message is a question, not a ticket" do
    assert_no_difference -> { SupportDesk::Ticket.count } do
      post "/messages/support/tickets", params: { topic: "other", message: "   " }
    end

    assert_response :unprocessable_entity
    assert_select ".support-desk-error", text: I18n.t("support_desk.wizard.message_required")
    assert_select "textarea[name=message]"
  end

  test "submitting from a step that isn't the composer re-renders that step" do
    assert_no_difference -> { SupportDesk::Ticket.count } do
      post "/messages/support/tickets", params: { topic: "billing", message: "Desde una rama" }
    end

    assert_response :unprocessable_entity
    assert_select ".support-desk-choice__label", text: "Invoice"
  end

  test "the requester's own actor is what signs the opening event" do
    post "/messages/support/tickets", params: { topic: "other", message: "Quién soy" }

    assert_equal @alice, SupportDesk::Ticket.last.events.first.actor
  end
end
