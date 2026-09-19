# frozen_string_literal: true

require "test_helper"

# `ticket.actions_for(agent)` stopped being decoration the moment the
# console began refusing anything it doesn't return. It is authorization
# now, and authorization that only ever gets exercised on its happy path
# fails open — or, here, fails CLOSED and silently: narrow `actions_for` by
# one entry and the console quietly stops accepting a verb, with every
# existing test still green because none of them press that button in that
# state.
#
# So this file writes the button set down independently, state by state,
# and checks it twice: against `actions_for`, and against what the console
# actually accepts over HTTP. A change to either has to be a deliberate
# change to the table.
class ConsoleOfferedActionsTest < ActionDispatch::IntegrationTest
  # The things the console says when it refuses a verb it would not have
  # offered. Anything else means the guard let the request through.
  NOT_OFFERED = [
    "This case is closed. Reopen it first.",
    "Take this case first — this desk only lets the assignee reply.",
    "Lucía is handling this case.",
    "Pedro is handling this case.",
    # A machine holds it, by the name the customer is reading.
    "Rose · virtual assistant is handling this case.",
    "You can't do that on this case right now.",
    "There is no proposal waiting on this case.",
    # One per status a decided proposal can be in: pressing Enviar on a
    # proposal somebody already dealt with has to say WHICH, or the second
    # reviewer learns nothing from the refusal.
    "That proposal was already sent.",
    "That proposal was already discarded.",
    "That proposal was already replaced.",
    "That proposal was already expired."
  ].freeze

  setup do
    @lucia = create_agent(name: "Lucía")
    @pedro = create_agent(name: "Pedro")

    login_as @lucia
  end

  test "open and unheld: everything but hand off, release and reopen" do
    assert_console_offers %i[note reply assign change_topic close] do
      fresh_ticket
    end
  end

  test "open and mine: the full set" do
    assert_console_offers %i[note reply assign hand_off release change_topic close] do
      fresh_ticket.tap { |ticket| ticket.assign!(to: @lucia, by: @lucia) }
    end
  end

  test "open and somebody else's: a drop-in may reply, but not hand off" do
    assert_console_offers %i[note reply assign release change_topic close] do
      fresh_ticket.tap { |ticket| ticket.assign!(to: @pedro, by: @pedro) }
    end
  end

  test "assignee_only and somebody else's: no reply" do
    with_support_config(reply_policy: :assignee_only) do
      assert_console_offers %i[note assign release change_topic close] do
        fresh_ticket.tap { |ticket| ticket.assign!(to: @pedro, by: @pedro) }
      end
    end
  end

  test "assignee_only and unheld: take it before you can answer it" do
    with_support_config(reply_policy: :assignee_only) do
      assert_console_offers %i[note assign change_topic close] do
        fresh_ticket
      end
    end
  end

  test "closed: a note and a way back" do
    assert_console_offers %i[note reopen] do
      fresh_ticket.tap { |ticket| ticket.close!(by: @lucia) }
    end
  end

  test "off duty: a note, and nothing that speaks to the requester" do
    # `on_duty?` is a seam hosts implement; the dummy takes the default
    # true, so this is the one place the suite can watch it say no.
    User.class_eval { def on_duty? = false }

    assert_console_offers %i[note] do
      fresh_ticket
    end
  ensure
    User.send(:remove_method, :on_duty?)
  end

  # --- With an assistant on the desk ----------------------------------------------
  #
  # Everything above is a desk with nothing configured, which is the state
  # every existing host is in. These are the states the assistants added,
  # and they are the ones easiest to get wrong: the two draft verbs come and
  # go with a ROW, and the switch comes and goes with the configuration.

  test "an assistant on the desk and nothing proposed: the switch, and no draft verbs" do
    configure_assistant!

    assert_console_offers %i[note reply assign change_topic close pause_assistant] do
      fresh_ticket
    end
  end

  test "a proposal waiting: send it, discard it, or write your own" do
    configure_assistant!

    assert_console_offers %i[note reply assign change_topic close pause_assistant
                             send_draft reject_draft] do
      ticket = fresh_ticket
      draft_as(support_assistant, ticket, "¿Te refieres al pedido de ayer?")
      ticket
    end
  end

  test "paused: the switch turns the other way, and the proposal it threw away is gone" do
    configure_assistant!

    assert_console_offers %i[note reply assign change_topic close resume_assistant] do
      ticket = fresh_ticket
      draft_as(support_assistant, ticket, "una propuesta")
      # Pausing supersedes it, which is the point: a switched-off assistant
      # must not leave behind a button that sends her words.
      ticket.pause_assistant!(by: @lucia)
      ticket
    end
  end

  test "closed with a proposal on it: a note and a way back, nothing else" do
    configure_assistant!

    assert_console_offers %i[note reopen] do
      ticket = fresh_ticket
      draft_as(support_assistant, ticket, "una propuesta")
      ticket.close!(by: @lucia)
      ticket
    end
  end

  test "nobody to write to: the proposal can be discarded but never sent" do
    configure_assistant!

    assert_console_offers %i[note assign change_topic close pause_assistant reject_draft] do
      ticket = fresh_ticket
      draft_as(support_assistant, ticket, "una propuesta")
      # The account went away between the proposal and the review. Sending
      # it would be speaking to nobody; deciding about it is still the
      # desk's to do.
      ticket.requester.update!(support_blocked: true)
      ticket
    end
  end

  test "assignee_only with the assistant holding it: a person may answer, and may send her words" do
    configure_assistant!(autonomy: :reply)

    with_support_config(reply_policy: :assignee_only) do
      assert_console_offers %i[note reply assign release change_topic close pause_assistant
                               send_draft reject_draft] do
        ticket = fresh_ticket
        ticket.assign!(to: support_assistant, by: @lucia)
        draft_as(support_assistant, ticket, "una propuesta")
        ticket
      end
    end
  end

  test "OFFERED_AS names exactly the member verbs" do
    # The console accepts a verb only when `actions_for` offers what
    # OFFERED_AS maps it to — so a verb missing from this table would be a
    # POST nothing checks, and one in the table with no route is a check
    # nothing ever reaches.
    assert_equal SupportDesk::Console::MEMBER_VERBS, SupportDesk::Console::OFFERED_AS.keys
  end

  private

  # A ticket nothing has touched yet — new requester, new subject.
  #
  # `Ticket.open!` hands back the requester's EXISTING open ticket about the
  # same thing, which is the cardinality guarantee doing its job and exactly
  # wrong here: reusing one requester meant every verb after the first was
  # judged against the state the previous verb left behind. A requester per
  # ticket also keeps the rate limit and the open-ticket cap out of it.
  def fresh_ticket
    requester = create_user(name: "Requester #{SecureRandom.hex(3)}")
    ticket_for(requester, about: create_order(user: requester, number: "SO#{SecureRandom.hex(2).upcase}"))
  end

  # +expected+ is the table. The block builds a fresh ticket in the state
  # under test — fresh, because a verb that goes through changes the state
  # the next one would be judged against.
  def assert_console_offers(expected, &build)
    assert_equal expected.sort, build.call.actions_for(@lucia).sort,
                 "actions_for no longer matches the button set this state is supposed to have — " \
                 "if that is deliberate, change the table here and the console will follow"

    SupportDesk::Console::OFFERED_AS.each do |verb, offered_as|
      ticket = build.call
      post "/madmin/support_tickets/#{ticket.id}/#{verb}", params: params_for(verb, ticket)
      alert = flash[:alert]
      # Follow the redirect so the flash is consumed. Without this, one
      # verb's refusal is still sitting in the session when the next verb
      # is judged, and the whole table reads as refusals.
      follow_redirect! if response.redirect?

      if expected.include?(offered_as)
        assert_not_includes NOT_OFFERED, alert, "the console refused #{verb}, which this state offers"
      else
        assert_includes NOT_OFFERED, alert, "the console accepted #{verb}, which this state does not offer"
      end
    end
  end

  # Enough for each verb to get past its own argument checks, so the only
  # thing that can refuse it is the guard under test. The draft verbs need a
  # REAL id: a made-up one is refused by the action rather than by the
  # guard, which would read as a pass in every state.
  def params_for(verb, ticket)
    case verb
    when :reply, :note then { body: "algo" }
    when :change_topic then { topic: "billing/invoice" }
    when :assign, :hand_off then { agent_id: SupportDesk.actor_key(@pedro) }
    when :send_draft
      { draft_id: ticket.drafts.first&.id.to_s, seen_turn: ticket.assistant_turn }
    when :reject_draft then { draft_id: ticket.drafts.first&.id.to_s }
    else {}
    end
  end
end
