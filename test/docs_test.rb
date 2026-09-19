# frozen_string_literal: true

require "test_helper"
require "generators/support_desk/assistant_generator"

# The README's assistant snippets are a promise, and a promise nobody runs is
# a promise that rots. This file pulls them OUT OF THE FILE and executes
# them: the configuration stanza, the harness job, the `respond!` outcomes,
# `Draft#send!` and the brief. A rename the README misses fails here rather
# than in somebody's app.
#
# It also runs the GENERATED harness end to end, because the template and the
# README teach the same nine lines and nothing else tests the template.
class DocsTest < ActiveSupport::TestCase
  README = File.expand_path("../README.md", __dir__)

  setup do
    @alice = create_user(name: "Alice")
    @lucia = create_agent(name: "Lucía")
    @order = create_order(user: @alice, number: "SO1")
  end

  teardown do
    Object.send(:remove_const, :Support) if Object.const_defined?(:Support, false)
    FileUtils.rm_rf(generator_root)
  end

  # --- The configuration stanza ----------------------------------------------------

  test "the README's assistant stanza configures exactly what it says it does" do
    stanza = snippet("config.assistant :rose do |rose|")

    SupportDesk.configure { |config| eval(stanza, binding, README) } # rubocop:disable Security/Eval

    rose = SupportDesk.assistant

    assert_equal "rose", rose.key
    assert_equal "Rose", rose.name
    assert_equal :draft, rose.autonomy
    assert_equal :signature, rose.disclosure
    assert_equal 6, rose.max_turns
    assert_equal 3.minutes, rose.responds_within
  end

  test "the README's subscription names an event the gem actually emits, with its own arity" do
    subscription = snippet("SupportDesk.on(:assistant_turn")

    assert_equal "ticket, assistant, message, turn:", SupportDesk::Events::CATALOGUE[:assistant_turn]
    assert_match(/\|ticket, assistant, _message, turn:\|/, subscription)
    assert_match(/perform_later\(ticket\.id, assistant\.key, turn\)/, subscription)
  end

  # --- The harness job --------------------------------------------------------------

  test "the README's job body proposes an answer, and spends nothing on a stale turn" do
    configure_assistant!(:rose)
    ticket = ticket_for(@alice, about: @order)
    calls = define_support_rose("Lo estoy mirando")
    body = snippet("def perform(ticket_id, assistant_key, turn)")
    job = Class.new { class_eval(body, README) }

    job.new.perform(ticket.id, "rose", ticket.assistant_turn)

    assert_pending_draft ticket, body: "mirando"
    assert_equal 1, calls.size

    # The turn moved: the job returns before it costs anything.
    stale = ticket.assistant_turn
    ask_again(ticket, "¿hola?")
    job.new.perform(ticket.id, "rose", stale)

    assert_equal 1, calls.size, "the job called the model on a turn that was no longer the case's"
    assert_equal 1, ticket.reload.drafts.count
  end

  # --- Levels, ceilings and floors ----------------------------------------------------

  test "the README's policy readers print what the README says they print" do
    configure_assistant!(:rose, autonomy: :reply)
    ticket = ticket_for(@alice, about: @order)
    readers = snippet("ticket.assistant_policy.level")

    with_topic_assistant_cap("order", :draft) do
      values = readers.lines.grep(/\Aticket\./).map { |line| eval(line, binding, README) } # rubocop:disable Security/Eval

      assert_equal [ :draft, "topic order caps rose at draft", false,
                     %i[note escalate release draft] ], values
    end
  end

  test "the ceilings the README prints are the ones that apply, and to_h spells all five" do
    rose = configure_assistant!(:rose, autonomy: :reply)
    ticket = ticket_for(@alice, about: @order)
    ticket.assign!(to: @lucia, by: @lucia)
    policy = ticket.reload.assistant_policy

    # A ceiling that does not apply is absent, not nil — `to_h` is the one
    # that spells every slot, because that is what a log line needs.
    assert_equal({ assistant: :reply }, policy.ceilings)
    assert_equal [ :held_by_human ], policy.floors
    assert_equal :draft, policy.level
    assert_equal %i[assistant topic cap case pause], policy.to_h[:ceilings].keys
    assert_equal rose.key, policy.to_h[:assistant]
  end

  # --- respond! ----------------------------------------------------------------------

  test "the README's respond! line answers every reader it advertises" do
    rose = configure_assistant!(:rose, autonomy: :reply)
    ticket = ticket_for(@alice, about: @order)
    text = "Lo estamos revisando"
    turn = ticket.assistant_turn
    line = snippet("outcome = ticket.respond!").lines.grep(/\Aoutcome = /).first

    refute_nil line, "the README's respond! block changed shape"
    outcome = eval(line, binding, README) # rubocop:disable Security/Eval

    assert_predicate outcome, :sent?
    assert_not outcome.drafted?
    assert_not outcome.withheld?
    assert_not outcome.escalated?
    assert_equal ticket.reload.assistant_turn, outcome.turn
    assert_equal 0.82, outcome.message.metadata.dig("support_desk", "confidence")
    assert_equal %i[action message draft reason turn policy], outcome.to_h.keys
  end

  test "the three outcomes the README names are the three respond! can return" do
    rose = configure_assistant!(:rose, autonomy: :draft)
    ticket = ticket_for(@alice, about: @order)

    assert_predicate ticket.respond!("Una propuesta", by: rose, turn: ticket.assistant_turn), :drafted?

    reply_as @lucia, ticket, "ya está"     # the desk answered: it is not her turn
    withheld = ticket.reload.respond!("otra vez", by: rose, turn: ticket.assistant_turn)

    assert_predicate withheld, :withheld?
    assert_equal :not_your_turn, withheld.reason

    # Answering seated Lucía on the case, and a case a person holds floors
    # her at :draft whatever her autonomy says — so the seat comes off first.
    ticket.release!(by: @lucia)
    ask_again(ticket, "una cosa más")
    with_assistant_config(:rose, autonomy: :reply) do
      assert_predicate ticket.reload.respond!("claro", by: rose, turn: ticket.assistant_turn), :sent?
    end
  end

  # --- Draft#send! ---------------------------------------------------------------------

  test "every Draft line the README prints works on a fresh proposal" do
    rose = configure_assistant!(:rose)
    lines = snippet("draft = ticket.pending_draft").lines.grep(/\Adraft\.(send|reject)!/)

    assert_equal 3, lines.size, "the README's Draft block changed shape"

    lines.each do |line|
      ticket = ticket_for(create_user, topic: :account)
      ticket.draft!("Te devolvemos el importe", by: rose, turn: ticket.assistant_turn)
      draft = ticket.reload.pending_draft
      lucia = @lucia

      eval(line, binding, README) # rubocop:disable Security/Eval

      assert_not draft.reload.pending?, "#{line.strip} left the proposal pending"
    end
  end

  test "a stale seen_turn is refused, and there is no bypass" do
    rose = configure_assistant!(:rose)
    ticket = ticket_for(@alice, about: @order)
    ticket.draft!("Te devolvemos el importe", by: rose, turn: ticket.assistant_turn)
    draft = ticket.reload.pending_draft
    stale = ticket.assistant_turn
    ask_again(ticket, "una cosa más")

    assert_raises(SupportDesk::StaleTurn) { draft.send!(by: @lucia, seen_turn: stale) }
    assert_predicate draft.reload, :pending?

    draft.send!(by: @lucia, seen_turn: ticket.reload.assistant_turn)

    assert_predicate draft.reload, :sent?
  end

  # --- The two exits -----------------------------------------------------------------------

  test "both of the README's exits reach a person, from either side" do
    rose = configure_assistant!(:rose)
    exits = snippet("ticket.escalate!(by: rose, turn: turn").lines.grep(/\Aticket\./)

    assert_equal 2, exits.size, "the README's exits block changed shape"

    exits.each do |line|
      alice = create_user
      ticket = ticket_for(alice, about: create_order(user: alice))
      turn = ticket.assistant_turn

      eval(line, binding, README) # rubocop:disable Security/Eval

      assert_needs_human ticket
      refute_assistant_spoke ticket
    end
  end

  # --- What the model sees ---------------------------------------------------------------

  test "the README's brief snippet answers" do
    configure_assistant!(:rose)
    ticket = ticket_for(@alice, about: @order)
    brief = nil

    eval(snippet("brief = ticket.brief(include_internal: false"), binding, README) # rubocop:disable Security/Eval

    assert_kind_of Hash, brief.to_h
    assert_kind_of String, brief.to_text
    assert_kind_of SupportDesk::AssistantPolicy, brief.policy
  end

  # --- The generated harness ---------------------------------------------------------------

  test "the generated job and service run against a real case" do
    configure_assistant!(:rose)
    ticket = ticket_for(@alice, about: @order)
    generate_rose!

    # Out of the box it refuses to guess, and says where the contract is.
    error = assert_raises(NotImplementedError) { Support::Rose.answer(ticket.brief, ticket.transcript) }
    assert_match(/README/, error.message)

    answer = Support::Rose::Answer.new(kind: :answer, text: "Lo estamos revisando", confidence: 0.8)

    assert_equal [], answer.sources    # the Struct's defaults
    assert_equal({}, answer.metadata)

    Support::Rose.stub(:answer, ->(*) { answer }) do
      Support::RoseTurnJob.perform_now(ticket.id, "rose", ticket.assistant_turn)
    end

    assert_pending_draft ticket, body: "revisando"

    stale = ticket.assistant_turn
    ask_again(ticket, "¿hola?")
    called = false
    Support::Rose.stub(:answer, ->(*) { called = true }) do
      Support::RoseTurnJob.perform_now(ticket.id, "rose", stale)
    end

    assert_not called, "the generated job called the model on a stale turn"
  end

  test "the README signature override preserves assistant snapshots and human signatures" do
    rose = configure_assistant!(:rose, autonomy: :reply)
    ticket = ticket_for(@alice)
    assistant_message = ticket.respond!("Answer", by: rose, turn: ticket.assistant_turn).message
    assistant_signature = Chats.message_signature_for(assistant_message)
    human_message = ticket.reply!("Human answer", by: @lucia)
    human_signature = Chats.message_signature_for(human_message)
    ask_again(ticket, "Another question")
    draft = ticket.draft!("Proposal", by: rose, turn: ticket.reload.assistant_turn)
    approved = draft.send!(by: @lucia, seen_turn: ticket.reload.assistant_turn)

    eval(snippet("config.message_signature = lambda"), binding, README) # rubocop:disable Security/Eval
    SupportDesk.config.assistant(:rose).name = "Renamed"
    SupportDesk.config.assistant(:rose).disclosure = :none

    assert_equal assistant_signature, Chats.message_signature_for(assistant_message.reload)
    assert_equal human_signature, Chats.message_signature_for(human_message)
    assert_equal human_signature, Chats.message_signature_for(approved)
  end

  private

  def generator_root = Rails.root.join("tmp/docs_generator").to_s

  # The first fenced ruby block in the README that contains +marker+.
  def snippet(marker)
    blocks = File.read(README).scan(/```ruby\n(.*?)```/m).flatten
    found = blocks.find { |block| block.include?(marker) }

    refute_nil found, "the README has no ruby block containing #{marker.inspect} any more"
    found
  end

  # A stand-in for the host's own service, recording what it was asked. The
  # constant is real (the snippets name `Support::Rose`) and is removed in
  # teardown.
  def define_support_rose(text)
    calls = []
    answer = Struct.new(:kind, :text, :confidence, :sources, :metadata, keyword_init: true)
                   .new(kind: :answer, text: text, confidence: 0.9, sources: [], metadata: {})
    service = Class.new do
      define_singleton_method(:answer) do |brief, transcript|
        calls << [ brief, transcript ]
        answer
      end
    end

    Object.const_set(:Support, Module.new)
    Support.const_set(:Rose, service)
    calls
  end

  def generate_rose!
    FileUtils.rm_rf(generator_root)
    capture_io do
      SupportDesk::Generators::AssistantGenerator.start(%w[Rose --disclosure signature],
                                                        destination_root: generator_root)
    end

    Object.const_set(:ApplicationJob, Class.new(ActiveJob::Base)) unless Object.const_defined?(:ApplicationJob)
    load File.join(generator_root, "app/services/support/rose.rb")
    load File.join(generator_root, "app/jobs/support/rose_turn_job.rb")
  end
end
