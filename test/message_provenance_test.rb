# frozen_string_literal: true

require "test_helper"

# Where a requester's message came in through, and what the channel called
# it — so an import can be re-run and a transcript can say "by email".
class MessageProvenanceTest < ActiveSupport::TestCase
  setup do
    @alice = create_user(name: "Alice")
    @ticket = ticket_for(@alice, message: "Hola")
  end

  test "via and external_id ride on the message" do
    message = @ticket.post_requester_message!("Sigue sin llegar", via: :email, external_id: "<abc@mail>")

    assert_equal({ "via" => "email", "external_id" => "<abc@mail>" }, message.metadata["support_desk"])
    assert_equal @alice, message.sender
    assert_equal message.id, @ticket.reload.last_requester_message_id, "folded in like any other message"
  end

  test "an in-app message carries no stamp" do
    message = @ticket.post_requester_message!("Hola otra vez")

    assert_nil message.metadata&.dig("support_desk")
    assert_nil @ticket.post_requester_message!("y otra", via: :in_app).metadata&.dig("support_desk")
  end

  test "an external id alone is stamped too" do
    message = @ticket.post_requester_message!("importado", external_id: 42)

    assert_equal({ "external_id" => "42" }, message.metadata["support_desk"])
  end

  test "a case opened through another channel stamps its first message" do
    ticket = SupportDesk::Ticket.open!(requester: create_user, message: "por correo", via: :email)

    first = ticket.conversation.messages.where(kind: "text").first
    assert_equal "email", first.metadata.dig("support_desk", "via")
  end
end
