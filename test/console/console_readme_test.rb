# frozen_string_literal: true

require "test_helper"

# The README's "Agent console" section is a promise about names. This runs
# the promise, so the three snippets anybody copies can't quietly rot.
class ConsoleReadmeTest < ActiveSupport::TestCase
  test "the two concerns exist and are includable" do
    controller = Class.new(ActionController::Base) do
      include SupportDesk::Console
      include SupportDesk::Console::Index
    end

    assert_includes controller.ancestors, SupportDesk::Console
    assert_includes controller.ancestors, SupportDesk::Console::Index
  end

  test "the concern answers every verb the README lists" do
    verbs = %i[reply take assign hand_off release close reopen note change_topic next]

    verbs.each do |verb|
      assert SupportDesk::Console.public_method_defined?(verb),
             "SupportDesk::Console is missing ##{verb}"
    end

    assert_equal (verbs - [ :next ]).sort, SupportDesk::Console::TRANSITIONS.sort
  end

  test "the README's configuration lines all assign" do
    SupportDesk.configure do |config|
      config.current_agent_method = :current_user
      config.visible_desks_for = ->(_agent) { [ :default ] }
      config.authorize_console = ->(_agent, _ticket, _action) { true }
      config.console_parent_controller = "::ApplicationController"
    end

    agent = create_agent

    assert_equal [ SupportDesk.desk ], SupportDesk.config.desks_visible_to(agent)
    assert SupportDesk.config.console_authorized?(agent, nil, :index)
  end

  test "an unset visible_desks_for means every desk" do
    SupportDesk.config.desk(:billing)
    SupportDesk.desk(:billing)

    assert_nil SupportDesk.config.visible_desks_for
    assert_equal SupportDesk::Desk.count, SupportDesk.config.desks_visible_to(create_agent).count
  end

  test "an unset authorize_console means yes" do
    assert_nil SupportDesk.config.authorize_console
    assert SupportDesk.config.console_authorized?(create_agent, nil, :close)
  end

  test "both hooks refuse anything that can't be called" do
    assert_raises(SupportDesk::ConfigurationError) { SupportDesk.config.visible_desks_for = :everything }
    assert_raises(SupportDesk::ConfigurationError) { SupportDesk.config.authorize_console = true }
  end

  test "the console engine is mountable, and isolated from the requester engine" do
    assert_operator SupportDesk::ConsoleEngine, :<, Rails::Engine
    assert_predicate SupportDesk::ConsoleEngine, :isolated?
    assert_equal "support_desk_console", SupportDesk::ConsoleEngine.engine_name

    # Two engines can't isolate the same namespace: the requester engine has
    # to keep SupportDesk's, or its URL helpers stop resolving.
    assert_equal SupportDesk::Engine, SupportDesk.railtie_namespace
    assert_equal SupportDesk::ConsoleEngine, SupportDesk::Console.railtie_namespace
  end

  test "the console engine draws its own routes file, not the requester engine's" do
    console = SupportDesk::ConsoleEngine.paths["config/routes.rb"].existent

    assert_equal [ SupportDesk::ConsoleEngine.root.join("config/console_routes.rb").to_s ], console
    assert_equal [ SupportDesk::Engine.root.join("config/routes.rb").to_s ],
                 SupportDesk::Engine.paths["config/routes.rb"].existent
  end
end
