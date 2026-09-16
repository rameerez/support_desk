# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < ActiveSupport::TestCase
  setup { @config = SupportDesk::Configuration.new }

  # --- Global settings ---------------------------------------------------------

  test "requester_class accepts a Class or a String and stores the name" do
    @config.requester_class = User

    assert_equal "User", @config.requester_class
    assert_equal User, @config.requester_model
  end

  test "blank class names fail on assignment" do
    error = assert_raises(SupportDesk::ConfigurationError) { @config.requester_class = "  " }

    assert_match(/can't be blank/, error.message)
  end

  # --- Desk settings -----------------------------------------------------------

  test "top level setters configure the default desk" do
    @config.name = "Soporte"
    @config.reply_within = 8.hours

    assert_equal "Soporte", @config.desk(:default).name
    assert_equal 8.hours, @config.desk(:default).reply_within
  end

  test "a desk inherits every setting it does not state" do
    @config.reply_within = 8.hours
    @config.name = "Soporte"
    @config.desk(:billing) { |desk| desk.name = "Facturación" }

    assert_equal "Facturación", @config.desk(:billing).name
    assert_equal 8.hours, @config.desk(:billing).reply_within
  end

  test "defaults are the documented ones" do
    desk = @config.desk(:default)

    assert_equal :anyone, desk.reply_policy
    assert_equal :first_only, desk.announce_assignments
    assert_equal :reopen_on_reply, desk.closed_tickets
    assert_equal 24.hours, desk.reply_within
    assert_equal 4.hours, desk.at_risk_after
    assert_equal({ to: 5, within: 1.hour.to_i }, desk.open_rate_limit)
    assert_equal 5, desk.max_open_tickets
    assert_equal :always, desk.inbox_entry
    assert_equal :manual, desk.routing
  end

  test "enum setters name the allowed values when they refuse" do
    error = assert_raises(SupportDesk::ConfigurationError) { @config.reply_policy = :whoever }

    assert_match(/reply_policy must be one of :anyone, :take_over, :assignee_only/, error.message)
  end

  test "routing refuses the strategies that need the 0.3 duty table" do
    error = assert_raises(SupportDesk::ConfigurationError) { @config.routing = :round_robin }

    assert_match(/0\.3/, error.message)
    assert_nothing_raised { @config.routing = ->(_ticket) { nil } }
  end

  test "durations must be durations" do
    error = assert_raises(SupportDesk::ConfigurationError) { @config.reply_within = "soon" }

    assert_match(/must be a duration/, error.message)
  end

  test "open_rate_limit must have a shape" do
    assert_raises(SupportDesk::ConfigurationError) { @config.open_rate_limit = { to: 0, within: 1.hour } }
    assert_nothing_raised { @config.open_rate_limit = nil }
  end

  test "max_open_tickets must be a positive integer or nil" do
    assert_raises(SupportDesk::ConfigurationError) { @config.max_open_tickets = -1 }
    assert_nothing_raised { @config.max_open_tickets = nil }
  end

  test "email must look like an address" do
    assert_raises(SupportDesk::ConfigurationError) { @config.email = "soporte" }
    @config.email = "soporte@example.com"

    assert_equal "soporte@example.com", @config.email
  end

  test "avatar takes a string or a callable" do
    @config.avatar = ->(desk) { "#{desk.key}.png" }

    assert_respond_to @config.avatar, :call
    assert_raises(SupportDesk::ConfigurationError) { @config.avatar = 42 }
  end

  # --- Agents ------------------------------------------------------------------

  test "agents takes a block and resolves it when asked" do
    admin = create_user(admin: true)
    create_user(admin: false)
    @config.agents { User.where(admin: true) }

    assert_equal [ admin ], @config.default_desk.agent_pool.to_a
  end

  test "agents also takes a lambda" do
    @config.agents = -> { User.none }

    assert_empty @config.default_desk.agent_pool
  end

  test "agents refuses something that cannot be called" do
    assert_raises(SupportDesk::ConfigurationError) { @config.agents = "User.admin" }
  end

  test "an agents block that returns something uncountable fails with the fix in the message" do
    @config.agents { 42 }

    error = assert_raises(SupportDesk::ConfigurationError) { @config.default_desk.agent_pool }

    assert_match(/must return a relation or an array/, error.message)
  end

  # --- Validation --------------------------------------------------------------

  test "validate! refuses an at_risk threshold after the promise" do
    @config.reply_within = 1.hour
    @config.at_risk_after = 4.hours

    error = assert_raises(SupportDesk::ConfigurationError) { @config.validate! }

    assert_match(/can't breach before it's at risk/, error.message)
  end

  test "an agents block that returns something uncountable fails at BOOT" do
    @config.requester_class = "User"
    @config.agents { 42 }

    error = assert_raises(SupportDesk::ConfigurationError) { @config.validate_classes! }

    assert_match(/must return a relation or an array/, error.message)
  end

  test "an agents block that raises fails at boot, naming what it raised" do
    @config.requester_class = "User"
    @config.agents { raise ArgumentError, "no pool here" }

    error = assert_raises(SupportDesk::ConfigurationError) { @config.validate_classes! }

    assert_match(/ArgumentError: no pool here/, error.message)
  end

  test "a lazy relation costs nothing to validate" do
    @config.requester_class = "User"
    @config.agents { User.where(admin: true) }

    assert_nothing_raised { @config.validate_classes! }
  end

  test "validate_classes! refuses a requester_class that is not one" do
    @config.requester_class = "Order"

    error = assert_raises(SupportDesk::ConfigurationError) { @config.validate_classes! }

    assert_match(/has_support_tickets/, error.message)
  end

  test "validate_classes! refuses an about: class that is not supportable" do
    @config.requester_class = "User"
    @config.topics { topic :nope, about: "User" }

    error = assert_raises(SupportDesk::ConfigurationError) { @config.validate_classes! }

    assert_match(/is not supportable/, error.message)
    assert_match(/supportable topic: :nope/, error.message)
  end

  test "validate_classes! warns about a tree with no way out" do
    @config.requester_class = "User"
    @config.topics { topic :order, about: "Order" }
    @config.validate_classes!

    assert_match(/no free-form topic/, @config.warnings.join)
  end

  test "config.on registers on the same dispatcher as SupportDesk.on" do
    SupportDesk.configure { |config| config.on(:ticket_closed) { |_ticket, **| } }

    assert_equal 1, SupportDesk.subscribers[:ticket_closed].size
  end

  test "parent controllers resolve" do
    assert_equal ApplicationController, SupportDesk.config.parent_controller_class
    assert_equal ApplicationController, SupportDesk.config.console_parent_controller_class
  end
end
