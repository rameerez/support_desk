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

  # Same shape, on the chats side. `acts_as_messager` registers a class with
  # chats when the class LOADS, and `Chats::Inbox` folds support threads into
  # one row only for registered grouped messagers. In a host that autoloads,
  # nothing references SupportDesk::Desk before the first inbox render, so
  # the registry is empty and every support conversation is its own row (#2).
  # The inbox is asked BEFORE anything here names the desk, which is the
  # order a real host's first request sees.
  REGISTRY_BOOT = <<~RUBY_SRC
    ENV["RAILS_ENV"] = "test"
    require File.expand_path("test/dummy/config/environment", Dir.pwd)

    raise "expected this boot NOT to eager load" if Rails.application.config.eager_load

    puts "GROUPED: \#{Chats.grouped_messager_types.sort.join(",")}"
  RUBY_SRC

  test "the desk is a registered grouped messager in an app that does not eager load" do
    output, status = Open3.capture2e(
      { "SUPPORT_DESK_EAGER_LOAD" => "false" },
      RbConfig.ruby, "-e", REGISTRY_BOOT, chdir: Rails.root.join("../..").to_s
    )

    assert_predicate status, :success?, "the dummy app failed to boot without eager loading:\n#{output}"
    assert_match(/^GROUPED: .*SupportDesk::Desk/, output,
                 "SupportDesk::Desk was not registered with chats before the first inbox could be rendered. " \
                 "The engine's to_prepare has to REFERENCE SupportDesk::Desk, or a lazily loading host shows " \
                 "every support conversation as its own inbox row.\n#{output}")
  end

  # A third boot, for the property an engine has to keep at the OTHER end:
  # loading the gem's constants must not touch the database. An
  # `assets:precompile` inside a container has no database at all, and a
  # constant that assembles an identifier through the connection at
  # class-definition time turns that into a boot failure.
  #
  # This boot eager loads (so every class body really runs) and then asks
  # whether anything checked a connection out or ran a query.
  NO_DATABASE_BOOT = <<~RUBY_SRC
    ENV["RAILS_ENV"] = "test"
    queries = []
    require "active_support/notifications"
    ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| queries << payload[:sql] }

    require File.expand_path("test/dummy/config/environment", Dir.pwd)

    raise "expected this boot to eager load" unless Rails.application.config.eager_load

    # Named explicitly as well, for the hosts that do NOT eager load: these
    # are the two that build SQL of their own.
    SupportDesk::Queue
    SupportDesk::Ticket

    # The HOST's own models read their own schema as they eager load;
    # what must not happen is the gem reading ITS tables to define a class.
    puts "OUR QUERIES: \#{queries.grep(/support_desk_/).size}"
    puts "CONNECTED: \#{ActiveRecord::Base.connection_pool.connected?}"
  RUBY_SRC

  test "loading the gem runs no query and needs no connection" do
    output, status = Open3.capture2e(
      RbConfig.ruby, "-e", NO_DATABASE_BOOT, chdir: Rails.root.join("../..").to_s
    )

    assert_predicate status, :success?, "the dummy app failed to boot:\n#{output}"
    assert_includes output, "OUR QUERIES: 0",
                    "something in support_desk read its own schema while it was being LOADED. A container " \
                    "running assets:precompile has no database — build identifiers and scopes inside a " \
                    "method or a lambda, never in a class body.\n#{output}"
    assert_includes output, "CONNECTED: false", output
  end
end
