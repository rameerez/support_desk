# frozen_string_literal: true

require "test_helper"

# The brief is the whole input to somebody else's model, so its shape is a
# contract: every key documented, `may` / `may_not` straight off the policy,
# and the two `support_context` readers — the ones that carry host data out
# of the building — present, named and opt-in where they should be.
class BriefTest < ActiveSupport::TestCase
  setup do
    @alice = create_user(name: "Alice")
    @lucia = create_agent(name: "Lucía")
    @order = create_order(user: @alice, number: "SO1")
  end

  # --- Shape ---------------------------------------------------------------------

  test "the documented keys, and nothing else at the top level" do
    configure_assistant!(:rose)
    ticket = ticket_for(@alice, about: @order)

    assert_equal %i[schema_version desk assistant case requester transcript], ticket.brief.to_h.keys
    assert_equal 1, ticket.brief.to_h[:schema_version]
  end

  test "the desk names itself and its promise in words" do
    ticket = ticket_for(@alice, about: @order)

    desk = ticket.brief.to_h[:desk]

    assert_equal "default", desk[:key]
    assert_equal "Soporte", desk[:name]
    assert_equal SupportDesk.humanize_duration(24.hours), desk[:reply_within]
  end

  test "a desk with no promise promises nothing" do
    ticket = ticket_for(@alice, about: @order)

    with_support_config(reply_within: nil) do
      assert_nil ticket.brief.to_h[:desk][:reply_within]
    end
  end

  test "the case carries its own state, its topic and what it is about" do
    ticket = ticket_for(@alice, about: @order)

    facts = ticket.brief.to_h[:case]

    assert_equal ticket.reference, facts[:reference]
    assert_equal "open", facts[:status]
    assert_equal "agent", facts[:awaiting]
    assert_equal "requester", facts[:opened_by]
    assert_equal :in_app, facts[:opened_via]
    assert_not facts[:reopened]
    assert_nil facts[:human_required]
    assert_not facts[:paused]
    assert_nil facts[:cap]
    assert_equal "order", facts[:topic][:path]
    assert_equal "Order", facts[:subject][:type]
    assert_equal "Order SO1", facts[:subject][:label]
    assert_equal "paid", facts[:subject][:status]
    assert_equal @order.support_context, facts[:subject][:context]
  end

  test "a case the desk opened says so, and a case with no subject has none" do
    ticket = open_support_ticket(for: @alice, by: @lucia, message: "Vimos algo", topic: :account)

    facts = ticket.brief.to_h[:case]

    assert_equal "support", facts[:opened_by]
    assert_nil facts[:subject]
  end

  test "a case that asked for a person says when and why" do
    configure_assistant!(:rose)
    ticket = ticket_for(@alice, about: @order)
    ticket.request_human!(by: @alice)

    facts = ticket.reload.brief.to_h[:case]

    assert_equal "requester_request", facts[:human_required][:reason]
    assert_kind_of Time, facts[:human_required][:at]
  end

  # --- The assistant ---------------------------------------------------------------

  test "no assistant on the desk is nil, not an empty assistant" do
    ticket = ticket_for(@alice, about: @order)

    assert_nil ticket.brief.to_h[:assistant]
    assert_includes ticket.brief.to_text, "No assistant works this desk."
  end

  test "may and may_not come straight off the policy" do
    configure_assistant!(:rose, autonomy: :draft)
    ticket = ticket_for(@alice, about: @order)

    facts = ticket.brief.to_h[:assistant]
    policy = ticket.assistant_policy

    assert_equal "rose", facts[:key]
    assert_equal "Rose", facts[:name]
    assert_equal :signature, facts[:disclosure]
    assert_equal policy.level, facts[:level]
    assert_equal policy.because, facts[:because]
    assert_equal policy.allowed_verbs, facts[:may]
    assert_equal policy.forbidden_verbs, facts[:may_not]
    assert_includes facts[:may], :draft
    assert_includes facts[:may_not], :reply
  end

  test "her name is her own, never the disclosed one" do
    configure_assistant!(:rose, disclosure: :signature_and_notice)
    ticket = ticket_for(@alice, about: @order)

    assert_equal "Rose", ticket.brief.to_h[:assistant][:name]
  end

  test "the turn budget is used over max, and unlimited is nil" do
    rose = configure_assistant!(:rose, autonomy: :reply, max_turns: 2)
    ticket = ticket_for(@alice, about: @order)
    ticket.respond!("Una", by: rose, turn: ticket.assistant_turn)

    assert_equal({ used: 1, max: 2 }, ticket.reload.brief.to_h[:assistant][:turns])

    with_assistant_config(:rose, max_turns: nil) do
      assert_nil ticket.brief.to_h[:assistant][:turns][:max]
      assert_includes ticket.brief.to_text, "Turns: 1/unlimited"
    end
  end

  # --- The requester ----------------------------------------------------------------

  test "the requester's own context is in the brief and on the card" do
    ticket = ticket_for(@alice, about: @order)

    # The default is empty, and it is a Hash, not nil — a harness that
    # iterates it must not have to check first.
    assert_equal({}, ticket.brief.to_h[:requester][:context])
    assert_equal({}, ticket.context_card.requester_pairs)
    assert_equal({}, ticket.context_card.to_h[:requester][:context])

    User.define_method(:support_context) { { "Plan" => "Pro" } }
    assert_equal({ "Plan" => "Pro" }, ticket.brief.to_h[:requester][:context])
    assert_equal({ "Plan" => "Pro" }, ticket.context_card.requester_pairs)
    assert_includes ticket.brief.to_text, "Plan: Pro"
  ensure
    User.remove_method(:support_context)
  end

  test "the requester is named, dated and counted" do
    ticket = ticket_for(@alice, about: @order)
    ticket_for(@alice, topic: :account)

    facts = ticket.brief.to_h[:requester]

    assert_equal "Alice", facts[:name]
    assert_equal @alice.created_at, facts[:since]
    assert_equal 2, facts[:open_cases]
  end

  # --- Internal ---------------------------------------------------------------------

  test "the desk's own reasoning is opt-in, per call" do
    rose = configure_assistant!(:rose)
    ticket = ticket_for(@alice, about: @order)
    ticket.note!("Ojo: ya reclamó en julio", by: @lucia)
    ticket.draft!("Te devolvemos el importe", by: rose, turn: ticket.assistant_turn)
    ticket.reload.pending_draft.reject!(by: @lucia, reason: "no es eso")

    assert_nil ticket.brief.to_h[:internal]
    assert_not_includes ticket.brief.to_text, "julio"

    internal = ticket.brief(include_internal: true).to_h[:internal]

    assert_equal [ "Ojo: ya reclamó en julio" ], internal[:notes].map { |note| note[:body] }
    assert_equal [ "rejected" ], internal[:drafts].map { |draft| draft[:status] }
    assert_equal [ "no es eso" ], internal[:drafts].map { |draft| draft[:rejection_reason] }
    assert_includes ticket.brief(include_internal: true).to_text, "julio"
  end

  # --- The transcript ----------------------------------------------------------------

  test "the transcript rides along, windowed" do
    ticket = ticket_for(@alice, about: @order)
    3.times { |i| ask_again(ticket, "otra vez #{i}") }

    assert_equal 4, ticket.brief.to_h[:transcript][:size]
    assert_equal 2, ticket.brief(transcript_limit: 2).to_h[:transcript][:turns].size
    assert ticket.brief(transcript_limit: 2).to_h[:transcript][:truncated]
    assert_equal 2, ticket.brief(transcript_limit: 2).transcript.size
  end

  # --- to_text -------------------------------------------------------------------------

  test "to_text is sectioned facts, with no instruction in it" do
    configure_assistant!(:rose)
    ticket = ticket_for(@alice, about: @order)

    text = ticket.brief.to_text

    %w[DESK ASSISTANT CASE REQUESTER TRANSCRIPT].each { |section| assert_includes text, "== #{section}" }
    assert_not_includes text, "== INTERNAL"
    assert_includes text, "Reference: #{ticket.reference}"
    assert_includes text, "Necesito ayuda"
    # Facts only: the gem never tells somebody else's model what to do.
    assert_no_match(/\b(please|you should|make sure|be (polite|concise|helpful))\b/i, text)
  end

  test "policy is the same object every verb asks" do
    configure_assistant!(:rose)
    ticket = ticket_for(@alice, about: @order)

    assert_equal ticket.assistant_policy.level, ticket.brief.policy.level
    assert_not ticket.brief.include_internal?
    assert ticket.brief(include_internal: true).include_internal?
  end
end
