# frozen_string_literal: true

require "application_system_test_case"

# Reviewing a machine's words, in a real browser.
#
# The whole design question is whether the person really read the proposal,
# and the parts that answer it are all on the screen: the card above the
# composer, the edit that opens the composer with her words already in it,
# and the 422 that comes back as the SAME screen when the customer wrote
# again while the page was open.
#
# What goes out is a message from the PERSON — their signature on it, their
# case, their responsibility — with the machine's name kept only as
# provenance, on the staff side of the desk.
class ConsoleDraftReviewTest < ApplicationSystemTestCase
  setup do
    @alice = create_user(name: "Alice")
    @lucia = create_agent(name: "Lucía")
    @rose = configure_assistant!
    @ticket = ticket_for(@alice, message: "¿Dónde está mi pedido?")

    login_as @lucia
  end

  test "the card carries what a reviewer needs before they put their name on it" do
    draft = propose "Tu pedido sale mañana.", confidence: 0.82,
                    sources: [ { "title" => "Política de envíos", "url" => "https://example.com/envios" } ]
    open_case

    within(card_for(draft)) do
      assert_text "Rose · virtual assistant's proposal"
      assert_text "Tu pedido sale mañana."
      assert_text "declared confidence 82 %"
      assert_link "Política de envíos", href: "https://example.com/envios"
    end
  end

  test "Enviar puts the person's name on the machine's words" do
    draft = propose "Tu pedido sale mañana."
    card = card_for(draft)
    open_case

    within(card) { click_on "Send" }

    # Wait for the card to go before reading anything else: the bubble it
    # leaves behind says the same words the card did.
    assert_no_selector card

    assert_text "Tu pedido sale mañana."
    assert_text "Lucía"
    # Staff-side provenance: a person sent this, and a machine wrote it.
    assert_text "Rose · virtual assistant's proposal"

    assert_predicate draft.reload, :sent?
    assert_equal @lucia, draft.reviewed_by
    assert_equal @lucia, draft.sent_message.author, "the person who sent it owns it"
    assert_equal "Tu pedido sale mañana.", draft.sent_message.body
  end

  test "Editar opens the composer with her words in it, and sends the person's" do
    draft = propose "Tu pedido sale mañana."
    card = card_for(draft)
    open_case

    within(card) { click_on "Edit" }

    assert_current_path(/compose=reply/, url: false)
    assert_field "body", with: "Tu pedido sale mañana."

    fill_in "body", with: "Tu pedido sale mañana por la tarde."
    click_on "Send the edited proposal"

    assert_no_selector card

    assert_predicate draft.reload, :edited?
    assert_equal "Tu pedido sale mañana.", draft.body, "the original is kept"
    assert_equal "Tu pedido sale mañana por la tarde.", draft.final_body
  end

  test "Descartar keeps the reason, and the case is still waiting for an answer" do
    draft = propose "Tu pedido sale mañana."
    card = card_for(draft)
    open_case

    within(card) do
      fill_in "reason", with: "habla del pedido anterior"
      click_on "Discard"
    end

    assert_no_selector card

    assert_predicate draft.reload, :rejected?
    assert_equal "habla del pedido anterior", draft.rejection_reason
    assert_awaiting_reply @ticket, "discarding a proposal doesn't answer anybody"
  end

  test "a customer who writes again while the page is open is read before they are answered" do
    draft = propose "Tu pedido sale mañana."
    card = card_for(draft)
    open_case

    assert_no_text "The conversation has changed since this was proposed."

    # The page is open, and the case moves under it.
    ask_again(@ticket, "Ya da igual, era otra cosa")

    within(card) { click_on "Send" }

    # The same screen again, not a redirect: the proposal is still here and
    # the reason is on it. There is no "send anyway".
    assert_text "The conversation has changed since this was proposed."
    assert_selector card
    assert_predicate draft.reload, :pending?, "nothing was sent"
    assert_equal 0, @ticket.messages.where(kind: "text", sender_type: "SupportDesk::Desk").count
  end

  private

  def propose(body, **options) = draft_as(@rose, @ticket, body, **options)

  # The card's own element, as a selector that outlives the proposal: once
  # it is sent there is no pending draft to ask for an id.
  def card_for(draft) = "##{ActionView::RecordIdentifier.dom_id(draft)}"

  # Capybara's own `visit`, without turbo-rails' wait for every
  # `<turbo-cable-stream-source>` on the page to report `connected`. The
  # console's case screen carries one and this dummy has no cable server
  # behind it, so the patched `visit` would block for the whole Capybara
  # wait on every example here. That the stream is rendered at all is
  # `console_engine_test.rb`'s to say.
  def open_case
    page.visit "/admin/support/#{@ticket.id}"
    assert_selector "h1", text: @ticket.label
  end
end
