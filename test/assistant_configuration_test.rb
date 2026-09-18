# frozen_string_literal: true

require "test_helper"

# §12.2 — every setter, every refusal, and the four rules that can only be
# checked once the whole block has run.
class AssistantConfigurationTest < ActiveSupport::TestCase
  def declare(key = :rose, &block)
    SupportDesk.configure do |config|
      config.assistant(key) do |assistant|
        assistant.disclosure = :signature
        block&.call(assistant)
      end
      config.default_assistant = key
    end
    SupportDesk.config.assistant(key)
  end

  # --- Identity ----------------------------------------------------------------

  test "a name defaults to the humanized key and can't be set blank" do
    assistant = declare

    assert_equal "Rose", assistant.name

    assistant.name = "Rosa"

    assert_equal "Rosa", assistant.name

    assistant.name = nil

    assert_equal "Rose", assistant.name, "nil goes back to the humanized key"
    assert_raises(SupportDesk::ConfigurationError) { assistant.name = "  " }
  end

  test "an avatar is a string, a callable or nothing" do
    assistant = declare
    assistant.avatar = "rose.png"

    assert_equal "rose.png", assistant.avatar

    assistant.avatar = ->(record) { "#{record.key}.png" }

    assert_respond_to assistant.avatar, :call
    assert_raises(SupportDesk::ConfigurationError) { assistant.avatar = 42 }
  end

  # --- What she may do ---------------------------------------------------------

  test "autonomy is one of the five levels" do
    assistant = declare

    assert_equal :draft, assistant.autonomy, "the default is the one that asks a person first"

    SupportDesk::AssistantPolicy::LEVELS.each do |level|
      assistant.autonomy = level

      assert_equal level, assistant.autonomy
    end

    error = assert_raises(SupportDesk::ConfigurationError) { assistant.autonomy = :maybe }

    assert_match(/must be one of/, error.message)
    assert_match(/:resolve/, error.message)
  end

  test "max_turns is a positive integer or nothing" do
    assistant = declare

    assert_equal 6, assistant.max_turns

    assistant.max_turns = nil

    assert_nil assistant.max_turns
    assert_raises(SupportDesk::ConfigurationError) { assistant.max_turns = 0 }
    assert_raises(SupportDesk::ConfigurationError) { assistant.max_turns = -1 }
    assert_raises(SupportDesk::ConfigurationError) { assistant.max_turns = 2.5 }
  end

  test "responds_within is a duration or nothing" do
    assistant = declare

    assert_equal 3.minutes, assistant.responds_within

    assistant.responds_within = 30

    assert_equal 30.seconds, assistant.responds_within

    assistant.responds_within = nil

    assert_nil assistant.responds_within
    assert_raises(SupportDesk::ConfigurationError) { assistant.responds_within = "soon" }
  end

  test "may_open_conversations is strictly boolean" do
    assistant = declare

    refute_predicate assistant, :may_open_conversations?

    assistant.may_open_conversations = true

    assert_predicate assistant, :may_open_conversations?
    # "yes" would be somebody meaning `false` and never finding out.
    assert_raises(SupportDesk::ConfigurationError) { assistant.may_open_conversations = "yes" }
    assert_raises(SupportDesk::ConfigurationError) { assistant.may_open_conversations = nil }
  end

  # --- Disclosure --------------------------------------------------------------

  test "disclosure is required and has no default" do
    error = assert_raises(SupportDesk::ConfigurationError) do
      SupportDesk.configure { |config| config.assistant(:mute) { |assistant| assistant.name = "Mute" } }
    end

    assert_match(/disclosure is required/, error.message)
    SupportDesk::Configuration::AssistantConfiguration::DISCLOSURE_MODES.each do |mode|
      assert_match(/#{mode}/, error.message, "the refusal has to name #{mode}")
    end
  end

  test "an explicit nil disclosure is refused — :none is how you say nothing" do
    assistant = declare
    error = assert_raises(SupportDesk::ConfigurationError) { assistant.disclosure = nil }

    assert_match(/`:none` is the explicit way/, error.message)

    assistant.disclosure = :none

    refute_predicate assistant, :disclosed?
    refute_predicate assistant, :signs?
    refute_predicate assistant, :notice?
  end

  test "the four modes answer signs? and notice?" do
    assistant = declare

    {
      signature_and_notice: [ true, true ],
      signature: [ true, false ],
      notice: [ false, true ],
      none: [ false, false ]
    }.each do |mode, (signs, notice)|
      assistant.disclosure = mode

      assert_equal signs, assistant.signs?, "#{mode} signs?"
      assert_equal notice, assistant.notice?, "#{mode} notice?"
      assert_equal(mode != :none, assistant.disclosed?, "#{mode} disclosed?")
    end
  end

  # --- Lines -------------------------------------------------------------------

  test "a line is a string, an i18n key, a block or nothing — and a typo fails at boot" do
    assistant = declare

    assert_equal :"support_desk.system.handed_off_to_humans", assistant.hand_off_line

    assistant.hand_off_line = "Te paso con %{name}"

    assert_equal "Te paso con %{name}", assistant.hand_off_line

    error = assert_raises(SupportDesk::ConfigurationError) { assistant.hand_off_line = "Te paso con %{nmae}" }

    assert_match(/can't be interpolated/, error.message)
    assert_raises(SupportDesk::ConfigurationError) { assistant.human_requested_line = 42 }

    assistant.disclosure_line { |ticket| "Hola #{ticket.reference}" }

    assert_respond_to assistant.disclosure_line, :call
  end

  test "line_problems names a key that has no translation" do
    assistant = declare
    assistant.hand_off_line = :"support_desk.system.nope"

    assert_match(/no .* translation/, assistant.line_problems.first)

    assistant.hand_off_line = :"support_desk.system.handed_off_to_humans"

    assert_empty assistant.line_problems
  end

  test "a line promises a duration only where the desk promises one" do
    alice = create_user
    assistant = declare
    ticket = ticket_for(alice, message: "Hola")

    with_support_config(reply_within: 2.hours) do
      assert_match(/2 hours/, assistant.line_for(:hand_off_line, ticket))
    end

    with_support_config(reply_within: nil) do
      line = assistant.line_for(:hand_off_line, ticket)

      assert_equal I18n.t("support_desk.system.handed_off_to_humans"), line
      assert_no_match(/nil/, line)
    end
  end

  # --- Hooks -------------------------------------------------------------------

  test "hand_off_when and cap take a block or a callable, and nothing else" do
    assistant = declare
    assistant.hand_off_when { |_ticket, _message| true }

    assert_respond_to assistant.hand_off_when, :call

    assistant.cap = ->(_ticket) { :draft }

    assert_respond_to assistant.cap, :call
    assert_raises(SupportDesk::ConfigurationError) { assistant.cap = :draft }

    assistant.hand_off_when = nil

    assert_nil assistant.hand_off_when
  end

  # --- Reading them back -------------------------------------------------------

  test "config.assistant reads, declares and refuses an unknown key" do
    declare

    assert SupportDesk.config.assistant?(:rose)
    refute SupportDesk.config.assistant?(:nope)
    assert_equal %i[rose], SupportDesk.config.assistants.keys

    error = assert_raises(SupportDesk::ConfigurationError) { SupportDesk.config.assistant(:nope) }

    assert_match(/no assistant :nope/, error.message)
    assert_match(/known: :rose/, error.message)
  end

  test "the module reads the record, memoises it, and refuses an unknown key" do
    declare

    rose = SupportDesk.assistant(:rose)

    assert_equal "rose", rose.key
    assert_same rose, SupportDesk.assistant(:rose), "memoised per process"
    assert_same rose, SupportDesk.assistant, "and the default is hers"
    assert_raises(SupportDesk::ConfigurationError) { SupportDesk.assistant(:nope) }

    SupportDesk.reset_assistants!

    assert_equal rose.id, SupportDesk.assistant(:rose).id, "the row is found, not created twice"
    assert_equal 1, SupportDesk::Assistant.count
  end

  test "with no assistant at all, everything answers nil" do
    assert_nil SupportDesk.assistant
    assert_empty SupportDesk.config.assistants
    assert_nil SupportDesk.config.default_assistant_key
  end

  # --- The four cross-field rules ----------------------------------------------

  test "a desk pointing at an assistant nobody declared fails at boot" do
    error = assert_raises(SupportDesk::ConfigurationError) do
      SupportDesk.configure { |config| config.desk(:billing) { |desk| desk.assistant = :nope } }
    end

    assert_match(/assistant :nope isn't configured/, error.message)
  end

  test "a default pointing nowhere fails at boot" do
    error = assert_raises(SupportDesk::ConfigurationError) do
      SupportDesk.configure { |config| config.default_assistant = :nope }
    end

    assert_match(/default_assistant is :nope/, error.message)
  end

  test "two assistants with no default is a refusal, not a coin flip" do
    error = assert_raises(SupportDesk::ConfigurationError) do
      SupportDesk.configure do |config|
        config.assistant(:rose) { |assistant| assistant.disclosure = :none }
        config.assistant(:max) { |assistant| assistant.disclosure = :none }
      end
    end

    assert_match(/2 assistants are configured/, error.message)
    assert_match(/default_assistant/, error.message)
  end

  test "one assistant is the default without saying so" do
    SupportDesk.configure do |config|
      config.assistant(:rose) { |assistant| assistant.disclosure = :none }
    end

    assert_equal :rose, SupportDesk.config.default_assistant_key
    assert_nil SupportDesk.config.default_assistant, "implicit, not stated"
    assert_equal :rose, SupportDesk.config.desk(:default).assistant_key
  end

  test "an explicit nil disables a desk while the default desk keeps hers" do
    SupportDesk.configure do |config|
      config.assistant(:rose) { |assistant| assistant.disclosure = :none }
      config.desk(:billing) { |desk| desk.assistant = nil }
      config.desk(:support) { |desk| desk.name = "Support" }
    end

    assert_equal :rose, SupportDesk.config.desk(:default).assistant_key
    assert_nil SupportDesk.config.desk(:billing).assistant_key, "explicitly nobody"
    assert_equal :rose, SupportDesk.config.desk(:support).assistant_key, "inherits the default"
  end

  # --- Topic caps --------------------------------------------------------------

  test "a topic cap is one of the levels" do
    # The tree is built lazily, at the first read — which is still boot.
    error = assert_raises(SupportDesk::ConfigurationError) do
      SupportDesk.configure { |config| config.topics { topic :payments, assistant: :maybe } }
      SupportDesk.config.default_desk.topics
    end

    assert_match(/assistant must be one of/, error.message)
  end

  test "a topic cap is the minimum over the branch, so a child can only tighten" do
    SupportDesk.configure do |config|
      config.topics do
        topic :payments, assistant: :draft do
          topic :withdrawal
          topic :refund, assistant: :observe
          # A child asking for MORE than its parent allows gets its
          # parent's answer: caps only tighten.
          topic :invoice, assistant: :resolve
        end
        topic :app
        other
      end
    end
    tree = SupportDesk.config.default_desk.topics

    assert_equal :draft, tree.find("payments").assistant_cap
    assert_equal :draft, tree.find("payments/withdrawal").assistant_cap, "inherited as a minimum"
    assert_equal :observe, tree.find("payments/refund").assistant_cap, "a child may tighten"
    assert_equal :draft, tree.find("payments/invoice").assistant_cap, "a child may not widen"
    assert_nil tree.find("app").assistant_cap, "an uncapped topic has no opinion"
  end

  test "a topic nobody declared caps her at :observe" do
    assert_equal :observe, SupportDesk::Topic::Unknown.new("gone/away").assistant_cap
  end

  # --- The agent macro ---------------------------------------------------------

  test "acts_as_support_agent kind: is :human or :ai" do
    error = assert_raises(SupportDesk::ConfigurationError) do
      Class.new(ActiveRecord::Base) do
        self.table_name = "users"
        acts_as_support_agent kind: :bot
      end
    end

    assert_match(/kind: must be :human or :ai/, error.message)
  end
end
