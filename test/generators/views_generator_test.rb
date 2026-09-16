# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/support_desk/views_generator"

class ViewsGeneratorTest < Rails::Generators::TestCase
  tests SupportDesk::Generators::ViewsGenerator
  destination File.expand_path("../../tmp/generators", __dir__)
  setup :prepare_destination

  test "ejects every requester-facing template by default" do
    run_generator

    assert_file "app/views/support_desk/tickets/index.html.erb"
    assert_file "app/views/support_desk/tickets/new.html.erb"
    assert_file "app/views/support_desk/tickets/rate_limited.html.erb"
    assert_file "app/views/support_desk/tickets/_ticket_row.html.erb"
    assert_file "app/views/support_desk/tickets/_pick_topic.html.erb"
    assert_file "app/views/support_desk/tickets/_pick_thing.html.erb"
    assert_file "app/views/support_desk/tickets/_write.html.erb"
    assert_file "app/views/support_desk/tickets/_context_card.html.erb"
    assert_file "app/views/support_desk/tickets/_door.html.erb"

    # The rows this engine contributes to chats' own screens travel too.
    assert_file "app/views/chats/slots/_inbox_top.html.erb"
    assert_file "app/views/chats/slots/_locked_composer.html.erb"
  end

  test "can eject a single group" do
    run_generator %w[--views tickets]

    assert_file "app/views/support_desk/tickets/index.html.erb"
    assert_no_file "app/views/chats/slots/_inbox_top.html.erb"
  end

  test "the ejected views are the ones the engine renders" do
    run_generator

    # Same bytes, so a host that ejects sees exactly what it had before.
    %w[index.html.erb _write.html.erb].each do |template|
      shipped = SupportDesk::Engine.root.join("app/views/support_desk/tickets", template)
      assert_file "app/views/support_desk/tickets/#{template}", File.read(shipped)
    end
  end
end
