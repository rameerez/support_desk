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
  # The four things the console says when it refuses a verb it would not
  # have offered. Anything else means the guard let the request through.
  NOT_OFFERED = [
    "This case is closed. Reopen it first.",
    "Take this case first — this desk only lets the assignee reply.",
    "Lucía is handling this case.",
    "Pedro is handling this case.",
    "You can't do that on this case right now."
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
      post "/madmin/support_tickets/#{ticket.id}/#{verb}", params: params_for(verb)
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
  # thing that can refuse it is the guard under test.
  def params_for(verb)
    case verb
    when :reply, :note then { body: "algo" }
    when :change_topic then { topic: "billing/invoice" }
    when :assign, :hand_off then { agent_id: @pedro.id }
    else {}
    end
  end
end
