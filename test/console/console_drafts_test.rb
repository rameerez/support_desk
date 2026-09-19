# frozen_string_literal: true

require "test_helper"

# The review desk, over HTTP: the screen a person reads a machine's words on,
# and the four buttons under it.
#
# The one that matters is Enviar. A draft is written by a machine and SENT BY
# A PERSON — their signature, their case, their responsibility — so the whole
# design question is whether the person really read it. The turn is the
# answer: the page carries the turn it was rendered with, the send carries it
# back, and a case that moved in between comes back as the same screen with
# the reason on top rather than as a message into a conversation that has
# gone somewhere else.
#
# These drive the mounted console (Layer 4) because it renders the gem's own
# views, which is where the hidden fields and the composer's edit mode live.
class ConsoleDraftsTest < ActionDispatch::IntegrationTest
  setup do
    @lucia = create_agent(name: "Lucía")
    @alice = create_user(name: "Alice")
    @rose = configure_assistant!
    @ticket = ticket_for(@alice, message: "¿Dónde está mi pedido?")

    login_as @lucia
  end

  # --- The card ------------------------------------------------------------------

  test "the case screen shows the proposal, its confidence and its sources" do
    draft_as(@rose, @ticket, "Tu pedido sale mañana.", confidence: 0.82,
             sources: [ { "title" => "Política de envíos", "url" => "https://example.com/envios" } ])

    get "/admin/support/#{@ticket.id}"

    assert_response :success
    assert_no_missing_translations
    assert_select "h2", text: /Rose/
    assert_select "section", text: /Tu pedido sale mañana\./
    assert_match "declared confidence 82 %", response.body
    assert_select "a[href=?][rel=?]", "https://example.com/envios", "noopener", text: "Política de envíos"
    assert_select "input[name=seen_turn][value=?]", @ticket.assistant_turn
  end

  test "a source with a url nothing should click is printed, never linked" do
    # The model validates these, and old rows and future models are not the
    # model's to promise. A citation is a link an agent clicks.
    draft = draft_as(@rose, @ticket, "Mira esto")
    draft.update_column(:sources, [ { "title" => "Raro", "url" => "javascript:alert(1)" } ])

    get "/admin/support/#{@ticket.id}"

    assert_response :success
    assert_select "a[href^=?]", "javascript:", count: 0
    assert_match "Raro", response.body
  end

  test "every form on the card names the proposal it is about" do
    # A button that posts without saying WHICH proposal is refused before
    # the model is asked, and the refusal is a flash nobody reads: the
    # discard button shipped like that and looked exactly like a no-op.
    draft = draft_as(@rose, @ticket, "Tu pedido sale mañana.")

    get "/admin/support/#{@ticket.id}"

    assert_response :success
    %w[send_draft reject_draft].each do |verb|
      assert_select "form[action=?] input[name=draft_id][value=?]",
                    "/admin/support/#{@ticket.id}/#{verb}", draft.id.to_s
    end
    assert_select "form[action=?] input[name=seen_turn][value=?]",
                  "/admin/support/#{@ticket.id}/send_draft", @ticket.assistant_turn
  end

  test "no proposal, no card" do
    get "/admin/support/#{@ticket.id}"

    assert_response :success
    assert_select "input[name=draft_id]", count: 0
  end

  # --- Sending -------------------------------------------------------------------

  test "Enviar sends the proposal verbatim, signed by the person who sent it" do
    draft = draft_as(@rose, @ticket, "Tu pedido sale mañana.")

    post "/admin/support/#{@ticket.id}/send_draft",
         params: { draft_id: draft.id.to_s, seen_turn: @ticket.assistant_turn }

    assert_redirected_to "/admin/support/#{@ticket.id}"
    assert_equal "Proposal sent.", flash[:notice]

    message = @ticket.messages.where(kind: "text").last

    assert_equal "Tu pedido sale mañana.", message.body
    assert_equal @lucia, message.author, "the person who sent it owns it"
    assert_equal SupportDesk.actor_key(@rose), message.metadata.dig("support_desk", "drafted_by")
    assert_equal false, message.metadata.dig("support_desk", "edited")
    assert_predicate draft.reload, :sent?
    assert_equal @lucia, draft.reviewed_by
    refute_pending_draft @ticket
  end

  test "an edit sends the person's words and keeps the machine's" do
    draft = draft_as(@rose, @ticket, "Tu pedido sale mañana.")

    post "/admin/support/#{@ticket.id}/send_draft",
         params: { draft_id: draft.id.to_s, seen_turn: @ticket.assistant_turn,
                   body: "Tu pedido sale mañana por la tarde." }

    assert_equal "Proposal sent.", flash[:notice]
    assert_equal "Tu pedido sale mañana por la tarde.", @ticket.messages.where(kind: "text").last.body
    assert_predicate draft.reload, :edited?
    assert_equal "Tu pedido sale mañana.", draft.body, "the original is kept"
    assert_equal "Tu pedido sale mañana por la tarde.", draft.final_body
  end

  test "an edit that empties the box is a refusal, not a send" do
    draft = draft_as(@rose, @ticket, "Tu pedido sale mañana.")

    post "/admin/support/#{@ticket.id}/send_draft",
         params: { draft_id: draft.id.to_s, seen_turn: @ticket.assistant_turn, body: "   " }

    # The same refusal an empty composer gets, in the same words: an empty
    # box is "write something", never "descártala".
    assert_equal "Write something before sending.", flash[:alert]
    assert_predicate draft.reload, :pending?
  end

  test "Editar opens the composer with the proposal in it" do
    draft = draft_as(@rose, @ticket, "Tu pedido sale mañana.")

    get "/admin/support/#{@ticket.id}", params: { compose: "reply", draft: draft.id.to_s }

    assert_response :success
    assert_select "textarea[name=body]", text: /Tu pedido sale mañana\./
    assert_select "form[action=?] input[name=draft_id][value=?]",
                  "/admin/support/#{@ticket.id}/send_draft", draft.id.to_s
    assert_match "Send the edited proposal", response.body
  end

  test "a draft param naming something else leaves the composer alone" do
    draft_as(@rose, @ticket, "Tu pedido sale mañana.")

    get "/admin/support/#{@ticket.id}", params: { compose: "reply", draft: "999999" }

    assert_response :success
    assert_select "textarea[name=body]", text: ""
    assert_select "form[action=?]", "/admin/support/#{@ticket.id}/reply"
  end

  # --- The turn ------------------------------------------------------------------

  test "a case that moved comes back as the same screen, with the text and the new turn" do
    draft = draft_as(@rose, @ticket, "Tu pedido sale mañana.")
    stale_turn = @ticket.assistant_turn
    ask_again(@ticket, "Ya da igual, era otra cosa")

    post "/admin/support/#{@ticket.id}/send_draft",
         params: { draft_id: draft.id.to_s, seen_turn: stale_turn, body: "Tu pedido sale el jueves." }

    assert_response :unprocessable_entity
    assert_equal "The conversation has changed. Read it and send again.", flash[:alert]
    assert_predicate draft.reload, :pending?, "nothing was sent"
    assert_equal 0, @ticket.messages.where(kind: "text").where(sender_type: "SupportDesk::Desk").count

    # Their words are still in the box, and the form now carries the turn
    # they are about to read — there is no "send anyway".
    assert_select "textarea[name=body]", text: /Tu pedido sale el jueves\./
    assert_select "input[name=seen_turn][value=?]", @ticket.reload.assistant_turn
    assert_no_match stale_turn, css_select("input[name=seen_turn]").map { |input| input["value"] }.join(" ")
  end

  test "the card says so when the case moved under it" do
    draft_as(@rose, @ticket, "Tu pedido sale mañana.")
    ask_again(@ticket, "Ya da igual")

    get "/admin/support/#{@ticket.id}"

    assert_response :success
    assert_match "The conversation has changed since this was proposed.", response.body
  end

  # --- Refusals ------------------------------------------------------------------

  test "a proposal id that names nothing is a flash, not a 500" do
    draft_as(@rose, @ticket, "Tu pedido sale mañana.")

    post "/admin/support/#{@ticket.id}/send_draft",
         params: { draft_id: "999999", seen_turn: @ticket.assistant_turn }

    assert_equal "That proposal is gone.", flash[:alert]
  end

  test "pressing Enviar twice says what happened to it" do
    draft = draft_as(@rose, @ticket, "Tu pedido sale mañana.")
    params = { draft_id: draft.id.to_s, seen_turn: @ticket.assistant_turn }

    post "/admin/support/#{@ticket.id}/send_draft", params: params

    assert_equal "Proposal sent.", flash[:notice]

    # The same submit again, from a tab that never learned. It must not read
    # "there is no proposal": there was one, and this person sent it.
    post "/admin/support/#{@ticket.id}/send_draft", params: params

    assert_equal "That proposal was already sent.", flash[:alert]
    # One answer went out, not two. Counted from the DESK's side of the
    # conversation — Alice's opening message is a text message too.
    assert_equal 1, @ticket.messages.where(kind: "text", sender_type: "SupportDesk::Desk").count
  end

  test "a proposal id that isn't text is a refusal, not a lookup" do
    draft_as(@rose, @ticket, "Tu pedido sale mañana.")

    post "/admin/support/#{@ticket.id}/send_draft",
         params: { draft_id: { evil: "1" }, seen_turn: @ticket.assistant_turn }

    assert_equal "Something in the form didn't come through. Try again.", flash[:alert]
    assert_pending_draft @ticket
  end

  test "a send with no turn on it is refused before the model is asked" do
    draft = draft_as(@rose, @ticket, "Tu pedido sale mañana.")

    post "/admin/support/#{@ticket.id}/send_draft", params: { draft_id: draft.id.to_s }

    assert_equal "Something in the form didn't come through. Try again.", flash[:alert]
    assert_predicate draft.reload, :pending?
  end

  # --- Discarding ----------------------------------------------------------------

  test "Descartar keeps the reason, and the case stays waiting" do
    draft = draft_as(@rose, @ticket, "Tu pedido sale mañana.")

    post "/admin/support/#{@ticket.id}/reject_draft",
         params: { draft_id: draft.id.to_s, reason: "no es eso, habla del pedido anterior" }

    assert_equal "Proposal discarded.", flash[:alert].nil? ? flash[:notice] : flash[:notice]
    assert_predicate draft.reload, :rejected?
    assert_equal "no es eso, habla del pedido anterior", draft.rejection_reason
    assert_equal @lucia, draft.reviewed_by
    assert_assert_reason_recorded @ticket, draft
    assert_awaiting_reply @ticket, "discarding a proposal doesn't answer anybody"
  end

  test "a reason that isn't text is dropped rather than written down" do
    draft = draft_as(@rose, @ticket, "Tu pedido sale mañana.")

    post "/admin/support/#{@ticket.id}/reject_draft",
         params: { draft_id: draft.id.to_s, reason: { evil: "1" } }

    assert_predicate draft.reload, :rejected?
    assert_nil draft.rejection_reason
  end

  # --- The switch ----------------------------------------------------------------

  test "Pausar takes her off this case and throws away what she proposed" do
    # Seated for real: only an assistant who may answer may HOLD a case, so
    # the seat is taken at :reply through the model's own path rather than
    # written onto the row. Everything the pause has to undo is then true —
    # she holds it, and she has something waiting.
    draft = nil
    with_assistant_config(autonomy: :reply) do
      @ticket.assign!(to: @rose, by: @lucia)
      draft = draft_as(@rose, @ticket, "Tu pedido sale mañana.")
    end

    assert_held_by_assistant @ticket, @rose

    post "/admin/support/#{@ticket.id}/pause_assistant", params: { reason: "cliente enfadado" }

    assert_equal "The assistant is paused on this case.", flash[:notice]
    assert_predicate @ticket.reload, :assistant_paused?
    assert_equal "cliente enfadado", @ticket.assistant_paused_reason
    assert_predicate draft.reload, :superseded?
    assert_unassigned @ticket
  end

  test "Reanudar puts her back, and only that" do
    @ticket.pause_assistant!(by: @lucia, reason: "un momento")

    post "/admin/support/#{@ticket.id}/resume_assistant"

    assert_equal "The assistant is back on this case.", flash[:notice]
    refute_predicate @ticket.reload, :assistant_paused?
    assert_nil @ticket.assistant_paused_reason
  end

  test "the header offers one switch at a time" do
    get "/admin/support/#{@ticket.id}"

    assert_response :success
    assert_match "Pause the assistant", response.body
    assert_no_match(/Resume the assistant/, response.body)

    @ticket.pause_assistant!(by: @lucia)
    get "/admin/support/#{@ticket.id}"

    assert_match "Resume the assistant", response.body
    assert_no_match(/Pause the assistant/, response.body)
  end

  # --- What the screen says about her --------------------------------------------

  test "the context card says what she may do here, and puts the rule in the tooltip" do
    with_topic_assistant_cap("other", :observe) do
      get "/admin/support/#{@ticket.id}"

      assert_response :success
      assert_select "dt", text: "Assistant"
      # The LEVEL is the answer an agent needs; `because` is written for
      # whoever is reading a stack trace, so it rides in the tooltip.
      row = css_select("dd[title]").detect { |dd| dd.text.strip == "observe" }

      assert row, "the context card doesn't say what she may do here"
      assert_equal "topic other caps rose at observe", row["title"]
    end
  end

  test "the context card carries the host's own words about the person asking" do
    User.define_method(:support_context) { { "Plan" => "Premium", "Pedidos" => 3 } }

    get "/admin/support/#{@ticket.id}"

    assert_response :success
    assert_no_missing_translations
    assert_select "h3", text: "About this person"
    assert_select "dt", text: "Plan"
    assert_select "dd", text: "Premium"
  ensure
    User.send(:remove_method, :support_context)
  end

  test "a message she sent herself is marked as hers, with what she claimed about it" do
    with_assistant_config(autonomy: :reply) do
      respond_as(@rose, @ticket, "Tu pedido sale mañana.", confidence: 0.9)
    end

    get "/admin/support/#{@ticket.id}"

    assert_response :success
    # Staff-only, and read from the message's own metadata so a host that
    # changes disclosure mode tomorrow doesn't rewrite yesterday's bubbles.
    assert_select "span[title=?]", "declared confidence 90 %", text: "🤖"
  end

  test "a message a person sent from her proposal is marked as theirs, from her" do
    draft = draft_as(@rose, @ticket, "Tu pedido sale mañana.")

    post "/admin/support/#{@ticket.id}/send_draft",
         params: { draft_id: draft.id.to_s, seen_turn: @ticket.assistant_turn }
    follow_redirect!

    assert_response :success
    assert_select "span", text: "Rose · virtual assistant's proposal"
    # It is a PERSON's message: no robot on it.
    assert_select "span", text: "🤖", count: 0
  end

  # --- The picker ----------------------------------------------------------------
  #
  # The pool is people and a machine, and their ids come out of two different
  # tables. "Assign this case to the machine" is not a decision to make on a
  # coin flip, so the form posts actor KEYS and a bare id only resolves while
  # exactly one member of the pool answers to it.

  test "the picker offers actor keys, and the machine's key assigns the machine" do
    pedro = create_agent(name: "Pedro")

    with_assistant_config(autonomy: :reply) do
      get "/admin/support/#{@ticket.id}"

      offered = css_select("select[name=agent_id] option").map { |option| option["value"] }.reject(&:blank?)

      assert_equal [ SupportDesk.actor_key(pedro), SupportDesk.actor_key(@rose) ].sort, offered.sort
      assert_empty offered.grep(/\A\d+\z/), "a bare id in the form is a coin flip on the server"

      post "/admin/support/#{@ticket.id}/assign", params: { agent_id: SupportDesk.actor_key(@rose) }

      assert_held_by_assistant @ticket, @rose
    end
  end

  test "a bare id resolves while only one of the pool answers to it" do
    pedro = create_agent(name: "Pedro")
    move_assistant_to! [ User.maximum(:id).to_i, SupportDesk::Assistant.maximum(:id).to_i ].max + 1

    post "/admin/support/#{@ticket.id}/assign", params: { agent_id: pedro.id.to_s }

    assert_assigned_to @ticket, pedro
  end

  test "a bare id two of the pool answer to is refused, not guessed" do
    # A person and a machine on the same number. It is contrived to arrange
    # and entirely ordinary in production: two tables, two sequences.
    rose = move_assistant_to!(@lucia.id)

    assert_equal @lucia.id, rose.id, "the collision this test is about didn't happen"

    with_assistant_config(autonomy: :reply) do
      post "/admin/support/#{@ticket.id}/assign", params: { agent_id: @lucia.id.to_s }

      assert_equal "Choose an agent from this desk.", flash[:alert]
      assert_unassigned @ticket, "an ambiguous id must never pick one of them"

      # The keys still say which is which, and they are what the form posts.
      post "/admin/support/#{@ticket.id}/assign", params: { agent_id: SupportDesk.actor_key(rose) }

      assert_held_by_assistant @ticket, rose
    end
  end

  # --- The queue -----------------------------------------------------------------

  test "the rows say which cases need a person and which have words waiting" do
    draft_as(@rose, @ticket, "Tu pedido sale mañana.")
    flagged = ticket_for(create_user(name: "Bruno"), message: "Quiero hablar con alguien")
    flagged.escalate!(by: @lucia, reason: "fraude")

    get "/admin/support?tab=open"

    assert_response :success
    assert_no_missing_translations
    assert_match "Proposal ready", response.body
    assert_match "Needs a person", response.body
  end

  test "the needs a person tab is offered wherever an assistant answers" do
    get "/admin/support"

    assert_response :success
    assert_no_missing_translations
    assert_select "a[href=?]", "/admin/support/?tab=needs_human"
    assert_match "Needs a person", response.body

    # And it is a tab that works, not a link to a name the queue refuses.
    get "/admin/support", params: { tab: "needs_human" }

    assert_response :success
  end

  private

  # Put the assistant row on a chosen id, and forget the memoised record so
  # the next request resolves the moved one. Two tables mean two sequences,
  # and whether they happen to agree is not something a test should leave to
  # whichever adapter it is running on.
  def move_assistant_to!(id)
    SupportDesk::Assistant.where(key: "rose").update_all(id: id)
    SupportDesk.reset_assistants!
    @rose = SupportDesk.assistant(:rose)
  end

  # The decision is on the case's own timeline, not only on the draft row:
  # a rejection nobody can find later is a rejection nobody learns from.
  def assert_assert_reason_recorded(ticket, draft)
    event = ticket.events.of_kind("draft_rejected").last

    assert event, "no draft_rejected event was written"
    assert_equal draft.id.to_s, event.payload["draft"]
  end
end
