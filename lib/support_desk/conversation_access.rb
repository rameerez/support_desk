# frozen_string_literal: true

module SupportDesk
  # chats finds every conversation a request names (the thread, the
  # composer, read, typing, refresh, reactions, edits) through the viewer's
  # inbox, `Messager#chats`, which applies the host's `config.inbox_scope`.
  # That is the right rule for a list and the wrong one for a case: a host
  # that keeps support apart from its inbox (`thread_page = :support`, and
  # an inbox_scope leaving SupportDesk::Ticket conversations out) would 404
  # its requesters inside their own cases, and every reply they typed with
  # them.
  #
  # So a conversation chats cannot find is looked for once more among the
  # viewer's OWN cases, through the same participation and block rules
  # (`Chats::Conversation.inbox_for`) minus the host's listing scope. Nobody
  # gains a conversation they are not seated in, a non-support conversation
  # the scope hides stays hidden, and an id that is not theirs is still the
  # same plain 404.
  #
  # Prepended to Chats::ApplicationController by the engine, in `to_prepare`
  # so it survives a code reload.
  #
  # == The contract with other layers
  #
  # It takes over ONE refusal only: chats' own lookup missing, a
  # RecordNotFound for Chats::Conversation with this id, about a conversation
  # the viewer's `chats` really does not hold. Anything else another layer of
  # `find_conversation` raises is final, whatever order the layers were
  # prepended in. To refuse a support conversation of your own, raise your own
  # error or a bare `ActiveRecord::RecordNotFound`, not chats' lookup shape.
  module ConversationAccess
    private

    def find_conversation(id = params[:id])
      super
    rescue ActiveRecord::RecordNotFound => e
      raise unless chats_inbox_miss?(e, id)

      SupportDesk::Ticket.requester_conversation(chats_current_messager, id) || raise
    end

    def chats_inbox_miss?(error, id)
      error.model == Chats::Conversation.name && error.id.to_s == id.to_s &&
        !chats_current_messager.chats.exists?(id: id)
    end
  end
end
