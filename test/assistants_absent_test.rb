# frozen_string_literal: true

require "test_helper"

# I1: a host that configures no assistant sees NO behaviour change.
#
# This is the invariant every other one is written on top of. 0.3 adds nine
# columns, two tables, five event kinds, a queue tab and a whole policy
# object — and every existing installation must go on working exactly as it
# did, with nothing new in a thread, a timeline, an export or a console.
#
# So this test plays a whole case through, start to finish, and asserts the
# 0.2 answer at every step.
class AssistantsAbsentTest < ActiveSupport::TestCase
  # Everything 0.3 can emit. A single one of them firing on a desk with no
  # assistant is a host being paged about a feature they never turned on.
  ASSISTANT_EVENTS = %i[
    assistant_turn draft_proposed draft_sent draft_rejected assistant_withheld
    ticket_escalated human_requested assistant_paused assistant_resumed
  ].freeze

  setup do
    @alice = create_user(name: "Alice")
    @lucia = create_agent(name: "Lucía")
  end

  test "the whole story writes nothing an assistant would have written" do
    events = capture_support_events(*ASSISTANT_EVENTS) do
      ticket = ticket_for(@alice, message: "No me llega el pedido")
      ticket.assign!(to: @lucia, by: @lucia)
      ticket.reply!("Lo estamos viendo", by: @lucia)
      ask_again(ticket, "gracias")
      ticket.close!(by: @lucia)
      ticket.reopen!(by: @lucia)
      ticket.export

      assert_equal 0, SupportDesk::Assistant.count, "no assistant row was created"
      assert_equal 0, SupportDesk::Draft.count, "no draft row was created"
      assert_nil ticket.assistant
      assert_predicate ticket.assistant_policy, :null?
      refute_predicate ticket, :human_required?
      refute_predicate ticket, :assistant_paused?
      assert_nil ticket.assistant_cap
      assert_equal 0, ticket.assistant_turns_count
      assert_nil ticket.assistant_acted_at
    end

    assert_empty events, "a desk with no assistant emitted #{events.map(&:first).inspect}"
  end

  test "no new event kinds reach the timeline" do
    ticket = ticket_for(@alice, message: "Hola")
    ticket.assign!(to: @lucia, by: @lucia)
    ticket.reply!("Hola", by: @lucia)
    ticket.close!(by: @lucia)

    new_kinds = %w[human_requested assistant_paused assistant_resumed draft_sent draft_rejected
                   assistant_withheld]

    assert_empty ticket.events.of_kind(*new_kinds).to_a
  end

  test "no system line beyond the ones 0.2 posts" do
    with_support_config(opening_line: "Hola %{label}") do
      ticket = ticket_for(@alice, message: "Hola")
      ticket.assign!(to: @lucia, by: @lucia)

      system_lines = ticket.conversation.messages.where(kind: "system").pluck(:body)

      assert_equal [ "Hola #{ticket.label}", I18n.t("support_desk.system.assigned", agent: "Lucía") ],
                   system_lines
    end
  end

  test "the desk's pool is exactly the people in it" do
    desk = SupportDesk.desk

    assert_equal desk.humans, desk.agents
    assert_equal [ @lucia ], desk.agents
    refute_predicate desk, :assistant?
    assert_nil desk.assistant
  end

  test "actions_for offers the 0.2 verbs and nothing else" do
    ticket = ticket_for(@alice, message: "Hola")

    assert_equal %i[note reply assign change_topic close].sort, ticket.actions_for(@lucia).sort

    ticket.assign!(to: @lucia, by: @lucia)

    assert_equal %i[note reply assign hand_off release change_topic close].sort,
                 ticket.actions_for(@lucia).sort
  end

  test "the queue shows the 0.2 tabs" do
    ticket_for(@alice, message: "Hola")

    assert_equal %i[awaiting mine unassigned open closed], @lucia.support_queue.visible_tabs
    assert_not_includes @lucia.support_queue.tabs.map(&:first), :needs_human
  end

  test "the export says nothing about machines" do
    ticket = ticket_for(@alice, message: "Hola")
    ticket.reply!("Buenas", by: @lucia)

    # The system line the desk posts is "support" in an export, exactly as
    # it was in 0.2 — the point is that nothing here says "assistant".
    assert_equal %w[you support support], ticket.export[:messages].map { |message| message[:from] }
  end

  test "the revision moves, and it is the only new column that does" do
    ticket = ticket_for(@alice, message: "Hola")
    # The opening message and the `opened` transition: the turn is
    # maintained for everybody, because it costs one integer and a host who
    # configures an assistant tomorrow must not need a backfill.
    assert_operator ticket.reload.assistant_revision, :>, 0
    assert_equal "t#{ticket.id}-r#{ticket.assistant_revision}", ticket.assistant_turn

    before = ticket.assistant_revision
    ticket.reply!("Buenas", by: @lucia)

    assert_operator ticket.reload.assistant_revision, :>, before
  end
end

# I1 on the SCREENS: a host with no assistant configured gets the 0.2
# console and the 0.2 thread, to the pixel.
#
# The model half is above. This half exists because a tab, a badge or a
# switch is not something a host can turn off after the fact — it is on the
# page the morning they upgrade, and a column of zeros is how a console
# starts teaching people not to read it.
class AssistantsAbsentSurfacesTest < ActionDispatch::IntegrationTest
  setup do
    @alice = create_user(name: "Alice", onboarded: true)
    @lucia = create_agent(name: "Lucía")
    @ticket = ticket_for(@alice, message: "No me llega el pedido")
  end

  test "the queue has no tab for a machine that isn't there" do
    login_as @lucia
    get "/admin/support"

    assert_response :success
    assert_no_missing_translations
    assert_select "a[href*=?]", "tab=needs_human", count: 0
    assert_no_match(/Needs a person/, response.body)
  end

  test "the case screen has no card, no switch and no draft verbs" do
    login_as @lucia
    get "/admin/support/#{@ticket.id}"

    assert_response :success
    assert_no_missing_translations
    assert_select "input[name=draft_id]", count: 0
    assert_select "input[name=seen_turn]", count: 0
    assert_no_match(/Pause the assistant|Resume the assistant/, response.body)
    assert_no_match(/proposal/i, response.body)
  end

  test "the picker still resolves the ids a 0.2 host's own form would post" do
    # The values became actor keys, which is a change to the MARKUP. A host
    # who copied the partial into their own app in 0.2 posts bare ids, and
    # with no machine in the pool there is nothing for one to be confused
    # with — so it still resolves.
    pedro = create_agent(name: "Pedro")
    login_as @lucia

    post "/admin/support/#{@ticket.id}/assign", params: { agent_id: pedro.id.to_s }

    assert_assigned_to @ticket, pedro
  end

  test "the requester's thread has no door out of a machine" do
    login_as @alice
    get "/messages/support"

    assert_response :success
    assert_no_match(/I’d rather talk to a person/, response.body)
    assert_no_match(/Handled by/, response.body)
  end
end
