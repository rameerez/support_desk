# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/support_desk/assistant_generator"

# The generator writes three files and prints four things, and the only one
# of those seven that can hurt somebody is the one it refuses to write: an
# assistant with no disclosure decision behind her.
class AssistantGeneratorTest < Rails::Generators::TestCase
  tests SupportDesk::Generators::AssistantGenerator
  destination File.expand_path("../../tmp/generators", __dir__)
  setup :prepare_destination

  # --- The required decision -----------------------------------------------------

  test "without --disclosure it writes nothing and names the four modes" do
    output = run_generator %w[Rose]

    assert_no_file "app/jobs/support/rose_turn_job.rb"
    assert_no_file "app/services/support/rose.rb"
    assert_no_file "test/jobs/support/rose_turn_job_test.rb"

    assert_match(/needs --disclosure/, output)
    assert_match(/Nothing was written/, output)
    %w[signature_and_notice signature notice none].each do |mode|
      assert_match(/--disclosure #{mode}/, output)
    end
  end

  test "an unknown disclosure writes nothing either" do
    output = run_generator %w[Rose --disclosure loud]

    assert_no_file "app/jobs/support/rose_turn_job.rb"
    assert_match(/unknown disclosure/, output)
    assert_match(/signature_and_notice/, output)
  end

  test "an unknown autonomy writes nothing" do
    output = run_generator %w[Rose --disclosure signature --autonomy omniscient]

    assert_no_file "app/services/support/rose.rb"
    assert_match(/unknown autonomy/, output)
  end

  # --- What it writes ------------------------------------------------------------

  test "the files are named after her, and so is everything in them" do
    run_generator %w[Rose --disclosure signature]

    assert_file "app/jobs/support/rose_turn_job.rb" do |job|
      assert_match(/class RoseTurnJob < ApplicationJob/, job)
      assert_match(/discard_on SupportDesk::StaleTurn, SupportDesk::Locked, ActiveRecord::RecordNotFound/, job)
      assert_match(/return unless ticket\.assistant_turn == turn/, job)
      assert_match(/may_observe\?/, job)
      assert_match(/Support::Rose\.answer\(ticket\.brief, ticket\.transcript\)/, job)
      assert_match(/when :answer/, job)
      assert_match(/when :hand_off/, job)
      assert_match(/when :note/, job)
      assert_match(/when :nothing/, job)
    end

    assert_file "app/services/support/rose.rb" do |service|
      assert_match(/class Rose$/, service)
      assert_match(/Answer = Struct\.new/, service)
      assert_match(/raise NotImplementedError/, service)
      assert_match(/README/, service)
    end

    assert_file "test/jobs/support/rose_turn_job_test.rb" do |job_test|
      assert_match(/class RoseTurnJobTest < ActiveSupport::TestCase/, job_test)
      assert_match(/assert_pending_draft/, job_test)
      assert_match(/with_assistant_config\(:rose, autonomy: :reply\)/, job_test)
      assert_match(/assert_awaiting_requester/, job_test)
      assert_match(/a stale turn writes nothing/, job_test)
    end
  end

  test "a two-word name still produces one key, one class and one file each" do
    run_generator %w[CustomerCare --disclosure notice]

    assert_file "app/jobs/support/customer_care_turn_job.rb" do |job|
      assert_match(/class CustomerCareTurnJob < ApplicationJob/, job)
      assert_match(/Support::CustomerCare\.answer/, job)
    end
    assert_file "app/services/support/customer_care.rb"
    assert_no_file "app/jobs/support/rose_turn_job.rb"
  end

  test "it never overwrites what is already there" do
    run_generator %w[Rose --disclosure signature]
    File.write(File.join(destination_root, "app/services/support/rose.rb"), "# mine\n")

    run_generator %w[Rose --disclosure none]

    assert_file "app/services/support/rose.rb", "# mine\n"
  end

  # --- What it prints ------------------------------------------------------------

  test "the printed stanza carries the disclosure that was chosen" do
    output = run_generator %w[Rose --disclosure signature_and_notice --autonomy reply]

    assert_match(/config\.assistant :rose do \|rose\|/, output)
    assert_match(/rose\.name       = "Rose"/, output)
    assert_match(/rose\.disclosure = :signature_and_notice/, output)
    assert_match(/rose\.autonomy   = :reply/, output)
    assert_match(/config\.default_assistant = :rose/, output)
  end

  test "a non-default desk is bound to that desk instead of made the default" do
    output = run_generator %w[Rose --disclosure signature --desk billing]

    assert_match(/config\.desk\(:billing\) \{ \|desk\| desk\.assistant = :rose \}/, output)
    assert_no_match(/config\.default_assistant/, output)
  end

  test "it prints the subscription and both scheduled tasks" do
    output = run_generator %w[Rose --disclosure signature]

    assert_match(/SupportDesk\.on\(:assistant_turn, key: "support\.rose\.turn"\)/, output)
    assert_match(/Support::RoseTurnJob\.set\(wait: 20\.seconds\)\.perform_later/, output)
    assert_match(/support_desk:release_silent_assistants/, output)
    assert_match(/support_desk:redispatch_assistant_turns/, output)
    assert_match(/every minute/, output)
    assert_match(/every 5 minutes/, output)
  end

  test "it never touches the initializer or the locales" do
    run_generator %w[Rose --disclosure signature]

    assert_no_file "config/initializers/support_desk.rb"
    assert_no_file "config/locales/support_desk.es.yml"
  end
end
