# frozen_string_literal: true

require "test_helper"
require "open3"

# The one property this whole suite cannot see from inside itself: the engine
# has to work in a host that does NOT eager load, which is every host in
# development.
#
# `SupportDesk::EngineHelper` registers its `on_load(:action_view)` hook at
# the bottom of the file that defines it, so the hook only runs once
# something has referenced the constant. Eager loading references
# everything, which is why the rest of the suite would keep passing with the
# hook dead — and `link_to_support` would be undefined in the host's dev
# environment on the first page that calls it.
#
# So this boots a second process with eager loading off and asks a view
# whether it knows the helper.
class EngineAutoloadTest < ActiveSupport::TestCase
  BOOT = <<~RUBY
    ENV["RAILS_ENV"] = "test"
    require File.expand_path("test/dummy/config/environment", Dir.pwd)

    raise "expected this boot NOT to eager load" if Rails.application.config.eager_load

    view = ActionView::Base.empty
    missing = %i[link_to_support support_unread_badge].reject { |name| view.respond_to?(name) }
    puts(missing.empty? ? "ALL PRESENT" : "MISSING: \#{missing.join(", ")}")
  RUBY

  test "the view helpers reach host views in an app that does not eager load" do
    output, status = Open3.capture2e(
      { "SUPPORT_DESK_EAGER_LOAD" => "false" },
      RbConfig.ruby, "-e", BOOT, chdir: Rails.root.join("../..").to_s
    )

    assert_predicate status, :success?, "the dummy app failed to boot without eager loading:\n#{output}"
    assert_includes output, "ALL PRESENT",
                    "support_desk's view helpers never reached ActionView. The engine's to_prepare has to " \
                    "REFERENCE SupportDesk::EngineHelper, or nothing triggers its on_load(:action_view) hook " \
                    "in a host that autoloads.\n#{output}"
  end
end
