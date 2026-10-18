# frozen_string_literal: true

module SupportDesk
  # The ticket page (`config.thread_page = :support`) renders chats' own
  # thread template, and that template names chats' routes bare:
  # `conversation_path`, `read_conversation_path`,
  # `conversation_messages_path`… Inside chats' engine those are its own;
  # rendered from this engine they would be looked up here and not exist.
  #
  # So on that page any route helper this engine does not have is chats',
  # through its mounted proxy (`chats_routes`), and the one name both
  # engines draw stays ours: `root_path` is the support list, which is
  # exactly where the thread's way back should lead.
  module ThreadHelper
    def method_missing(name, ...)
      chats_route?(name) ? chats_routes.public_send(name, ...) : super
    end

    def respond_to_missing?(name, include_private = false)
      chats_route?(name) || super
    end

    private

    def chats_route?(name)
      name.end_with?("_path", "_url") && chats_routes.respond_to?(name)
    end
  end
end
