# frozen_string_literal: true

require "test_helper"

# The launcher's live badge (SupportDesk::Launcher): a replace of
# `support_desk_launcher_badge` on the requester's `[requester, :support_desk]`
# stream wherever chats says an unread count in a case may have moved
# (`Chats.on(:unread_changed)`, chats >= 0.7.0), the case's own notices
# included, and never for a conversation that is not a case.
class LauncherBadgeTest < ActiveSupport::TestCase
  setup do
    @alice = create_user(name: "Alice", onboarded: true)
    @bob = create_user(name: "Bob")
    @lucia = create_agent(name: "Lucía")
    @ticket = ticket_for(@alice, topic: :other, message: "Where is my refund?")
    clear_enqueued_jobs
  end

  test "a reply to their case replaces the requester's badge, with the count it leaves" do
    reply_as @lucia, @ticket, "On its way"

    badges = badge_broadcasts_for(@alice)
    assert_operator badges.size, :>=, 1
    assert_equal SupportDesk::Launcher::BADGE_ID, badges.last[:target]
    assert_equal "replace", badges.last[:action].to_s
    assert_equal({ requester: @alice }, badges.last[:locals], "counted as it renders, in the job")
    html = ApplicationController.render(partial: SupportDesk::Launcher::BADGE_PARTIAL, locals: badges.last[:locals])
    assert_includes html, %(data-count="#{@alice.unread_support_count}")
  end

  test "a notice the case posts on its own (a system message) moves the badge too" do
    @ticket.conversation.post_system_message!("We reopened this conversation.")

    assert_equal 1, badge_broadcasts_for(@alice).size
  end

  test "reading the case brings the badge down" do
    reply_as @lucia, @ticket, "On its way"
    clear_enqueued_jobs

    @ticket.conversation.mark_read_by!(@alice)

    assert_equal [ @alice ], badge_broadcasts_for(@alice).map { |badge| badge[:locals][:requester] }
    assert_equal 0, @alice.unread_support_count
  end

  test "a conversation that is not a case never touches the launcher" do
    @bob.message!(@alice, "hola")

    assert_empty badge_broadcasts_for(@alice)
  end

  test "the requester's own message moves nobody's launcher badge" do
    ask_again @ticket, "Any news?"

    assert_empty badge_broadcasts_for(@alice)
  end

  private

  # The launcher-badge broadcasts enqueued for +requester+'s stream.
  def badge_broadcasts_for(requester)
    stream = "#{requester.to_gid_param}:support_desk" # how Turbo names the [requester, :support_desk] stream
    enqueued_jobs.filter_map do |job|
      next unless job["job_class"] == "Turbo::Streams::ActionBroadcastJob"

      args = ActiveJob::Arguments.deserialize(job["arguments"])
      next unless args.first == stream

      args.last.symbolize_keys
    end
  end
end
