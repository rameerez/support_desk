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
  module ConversationAccess
    private

    def find_conversation(id = params[:id])
      super
    rescue ActiveRecord::RecordNotFound
      SupportDesk::Ticket.requester_conversation(chats_current_messager, id) || raise
    end
  end
end
