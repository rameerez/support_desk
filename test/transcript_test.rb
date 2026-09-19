# frozen_string_literal: true

require "test_helper"

# The transcript is the one thing a harness reads before it spends money, so
# every line of it is a promise: four roles rather than the clocks' three,
# names that survive a rename, deleted messages that still say something
# happened, and a text rendering two runs agree on to the character.
class TranscriptTest < ActiveSupport::TestCase
  setup do
    @alice = create_user(name: "Alice")
    @lucia = create_agent(name: "Lucía")
    @order = create_order(user: @alice, number: "SO1")
  end

  # --- Roles ---------------------------------------------------------------------

  test "the four roles, and none of them is role_of's" do
    rose = configure_assistant!(:rose, autonomy: :reply)
    ticket = ticket_for(@alice, about: @order)
    ticket.respond!("Lo estoy mirando", by: rose, turn: ticket.assistant_turn)
    ask_again(ticket, "gracias")
    reply_as @lucia, ticket, "Resuelto"

    assert_equal %i[requester assistant requester human], ticket.transcript.map(&:role)
    assert_equal [ "Alice", "Rose", "Alice", "Lucía" ], ticket.transcript.map(&:name)

    # The clocks still speak their own three-word language, untouched.
    messages = ticket.conversation.messages.oldest_first.to_a
    assert_equal %i[requester agent requester agent], messages.map { |m| ticket.send(:role_of, m) }
  end

  test "a system line is a system turn, whoever caused it" do
    rose = configure_assistant!(:rose, autonomy: :reply, disclosure: :notice)
    ticket = ticket_for(@alice, about: @order)
    ticket.respond!("Lo miro", by: rose, turn: ticket.assistant_turn)

    # The disclosure notice rides one tick above her first message.
    assert_equal %i[requester system assistant], ticket.transcript.map(&:role)
    # A :notice message has no author for chats to sign, so there is no name
    # on the row at all — the transcript reads her key out of the provenance
    # stamp and resolves it through the configuration.
    assert_nil ticket.conversation.messages.oldest_first.last.author
    assert_equal "Rose", ticket.transcript.to_a.last.name
  end

  test "a nameless assistant is still the assistant, by her provenance stamp" do
    rose = configure_assistant!(:rose, autonomy: :reply, disclosure: :none)
    ticket = ticket_for(@alice, about: @order)
    ticket.respond!("Lo miro", by: rose, turn: ticket.assistant_turn)

    spoken = ticket.transcript.to_a.last

    assert_predicate spoken, :assistant?
    assert_nil ticket.conversation.messages.oldest_first.last.author
  end

  test "a draft a human sent is the human's turn, marked assisted" do
    rose = configure_assistant!(:rose)
    ticket = ticket_for(@alice, about: @order)
    ticket.draft!("Te devolvemos el importe", by: rose, turn: ticket.assistant_turn)
    ticket.pending_draft.send!(by: @lucia, seen_turn: ticket.assistant_turn)

    sent = ticket.reload.transcript.to_a.last

    assert_equal :human, sent.role
    assert_equal "Lucía", sent.name
    assert_predicate sent, :assisted?
  end

  # --- Names ---------------------------------------------------------------------

  test "her name follows the configuration, and falls back to what was shown" do
    rose = configure_assistant!(:rose, autonomy: :reply, name: "Rose")
    ticket = ticket_for(@alice, about: @order)
    ticket.respond!("Hola", by: rose, turn: ticket.assistant_turn)

    with_assistant_config(:rose, name: "Rosa") do
      assert_equal "Rosa", ticket.transcript.to_a.last.name
    end

    # Nobody declares her any more, so there is no configured name left to
    # read: the transcript falls back to the name the message was WRITTEN
    # with, disclosure suffix and all. What the customer saw is the only
    # thing still true about a message nobody's initializer explains.
    SupportDesk.reset!
    configure_support_desk!
    assert_equal I18n.t("support_desk.assistant.disclosed_name", name: "Rose"),
                 ticket.reload.transcript.to_a.last.name
  end

  test "a human with no support_agent_name falls back to the desk" do
    ticket = ticket_for(@alice, about: @order)
    reply_as @lucia, ticket, "Vamos a ello"
    ticket.conversation.messages.oldest_first.last.update_columns(author_type: nil, author_id: nil)

    assert_equal "Soporte", ticket.reload.transcript.to_a.last.name
  end

  # --- Tombstones and attachments -------------------------------------------------

  test "a deleted message is still a turn, and says so" do
    ticket = ticket_for(@alice, about: @order)
    ask_again(ticket, "perdón, me equivoqué")
    ticket.conversation.messages.oldest_first.last.soft_delete!

    last = ticket.transcript.to_a.last

    assert_equal I18n.t("support_desk.transcript.deleted"), last.body
    assert_empty last.attachments
    assert_equal 2, ticket.transcript.size
  end

  # --- to_text -------------------------------------------------------------------

  test "to_text is deterministic, UTC and to the minute" do
    ticket = ticket_for(@alice, about: @order)
    at = Time.utc(2026, 9, 18, 10, 2, 47)
    ticket.conversation.messages.oldest_first.first.update_columns(created_at: at)

    assert_equal "[2026-09-18 10:02] Alice: Necesito ayuda", ticket.transcript.to_text
    # Two reads of the same conversation say the same bytes.
    assert_equal ticket.transcript.to_text, ticket.reload.transcript.to_text
  end

  test "attachments render as filenames" do
    ticket = ticket_for(@alice, about: @order)
    file = { io: StringIO.new("x"), filename: "justificante.png", content_type: "image/png" }
    reply_as @lucia, ticket, "Aquí lo tienes", files: [ file ]

    turn = ticket.transcript.to_a.last

    assert_equal [ "justificante.png" ], turn.attachments
    assert_includes turn.to_line, "[justificante.png]"
  end

  # --- Windows -------------------------------------------------------------------

  test "limit keeps the end of the conversation and says it truncated" do
    ticket = ticket_for(@alice, about: @order)
    3.times { |i| ask_again(ticket, "otra vez #{i}") }

    transcript = ticket.transcript(limit: 2)

    assert_equal 2, transcript.size
    assert_equal [ "otra vez 1", "otra vez 2" ], transcript.map(&:body)
    assert_equal({ size: 4, truncated: true }, transcript.to_h.slice(:size, :truncated))
    assert_equal 4, ticket.transcript.to_h[:size]
    assert_not ticket.transcript.to_h[:truncated]
  end

  test "last and since read the same window" do
    ticket = ticket_for(@alice, about: @order)
    reply_as @lucia, ticket, "uno"
    anchor = ticket.conversation.messages.oldest_first.last
    ask_again(ticket, "dos")
    reply_as @lucia, ticket, "tres"

    assert_equal %w[dos tres], ticket.transcript.since(anchor).map(&:body)
    assert_equal %w[dos tres], ticket.transcript.last(2).map(&:body)
    assert_empty ticket.transcript.since(ticket.conversation.messages.oldest_first.last)
  end

  test "a message this window never held yields the whole window" do
    ticket = ticket_for(@alice, about: @order)
    reply_as @lucia, ticket, "uno"
    stranger = create_user
    other = ticket_for(stranger, about: create_order(user: stranger))

    whole = ticket.transcript.size

    assert_operator whole, :>, 1
    assert_equal whole, ticket.transcript.since(other.conversation.messages.oldest_first.first).size
    assert_equal whole, ticket.transcript.since(nil).size
  end

  test "it is Enumerable, and a case with no conversation is empty rather than broken" do
    ticket = ticket_for(@alice, about: @order)

    assert_kind_of Enumerable, ticket.transcript
    assert_equal 1, ticket.transcript.count
    assert_equal 1, ticket.transcript.to_a.size

    ticket.update_columns(conversation_id: nil)

    assert_equal 0, ticket.reload.transcript.size
    assert_equal "", ticket.transcript.to_text
  end

  test "the tombstone copy exists in both languages" do
    %i[es en].each do |locale|
      assert I18n.exists?("support_desk.transcript.deleted", locale), "no #{locale} tombstone copy"
    end
  end
end
